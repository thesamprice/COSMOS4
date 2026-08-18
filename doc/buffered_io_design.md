# Buffered C++ I/O backends (design)

## Problem

Every interface reads its device from a **Ruby** thread. Ruby threads
share the GVL, so while any other thread holds it (decom, logging, GUI
painting, script execution), the reader thread is not scheduled and the
device is not drained:

- **UDP**: the kernel socket buffer (`SO_RCVBUF`) overflows and
  datagrams are **silently dropped**.
- **Serial**: the tty input buffer overruns at high baud rates —
  silently dropped bytes.
- **TCP**: no loss (flow control), but latency spikes and sender-side
  back-pressure.

The current read path makes it worse: `TcpipSocketStream#read` loops
`read_nonblock`/`IO.select` *in Ruby*, so even the syscall scheduling
depends on winning the GVL.

## Approach

Move the device I/O into a small C++ extension whose threads **never
touch Ruby**: they drain the OS buffers the moment data arrives and park
it in large user-space buffers. Ruby-side classes **inherit from the
existing streams/interfaces** and swap only the transport underneath, so
protocols, interfaces, config files, logging, and the tools see exactly
the API they see today.

**Event-driven end to end — no polling anywhere:**

```
kernel ──(blocking read(2)/recvfrom(2) wakes)──▶ C++ reader thread
        ──(ring buffer + pthread_cond_signal)──▶ Ruby interface thread
                                                  (condvar wait with the
                                                   GVL released)
```

Three wakeup hops, zero sleep loops, zero timers. Latency is wakeup
latency, not a poll interval.

## C++ core (`ext/cosmos/ext/buffered_io/`, C++17)

```
BufferedChannel                (abstract: fd, reader/writer threads,
│                               stats, lifecycle, error latch)
├── StreamChannel              (byte-stream semantics: byte ring buffer)
│   ├── TcpChannel             (adopts a connected socket fd)
│   └── SerialChannel          (adopts a termios-configured tty fd)
└── DatagramChannel            (message semantics: datagram ring)
    └── UdpChannel             (recvfrom/sendto; boundaries preserved)
```

### Threads

- **Reader thread** (one per channel, `std::thread`): blocks in
  `read(2)`/`recvfrom(2)` — kernel-event-driven — and appends to the
  ring. Never calls a Ruby API; the GVL is irrelevant to it. Default
  ring: 16 MiB (streams) / 65536 datagrams (UDP), configurable per
  interface.
- **Writer thread** (one per channel): drains an outgoing queue in
  order. Ruby `write` enqueues and returns — a slow peer can no longer
  stall a GVL-holding thread. Past a high-water mark the caller either
  blocks with the GVL released or raises (configurable).
- **Ruby `read`**: `rb_thread_call_without_gvl` around a condvar wait,
  signalled by the reader when data lands. The unblock function
  `pthread_cond_broadcast`s and marks the wait aborted, so
  `Thread#kill` / `disconnect` interrupt it exactly like today's reads
  (Cosmos.kill_thread semantics preserved).

### Overflow, errors, lifecycle

- If Ruby is *persistently* slower than the source, the ring overflows
  by policy: **drop-oldest** (default — freshest telemetry wins) or
  drop-newest. Every drop is **counted and queryable**
  (`drop_count`, `buffered_bytes`, `high_water`) — unlike today's
  silent kernel drops. Interfaces surface these in their existing
  counters so the CmdTlmServer GUI shows them.
- Reader/writer latch `errno`/EOF; the next Ruby call raises the mapped
  exception (`EOFError`, `Errno::*`) matching current Stream behavior.
- Channels are TypedData objects. `disconnect` (and GC dealloc, and a
  VM-teardown end proc) signal stop, `shutdown(2)` the fd to unblock
  syscalls, and join with a timeout — the teardown ordering lessons
  from the Qt 6 bindings apply directly.

## Ruby layer (inheritance; user-facing behavior unchanged)

```
BufferedTcpipSocketStream    < TcpipSocketStream    # read/write/disconnect via TcpChannel
BufferedTcpipClientStream    < TcpipClientStream    # Ruby resolves/connects, channel adopts the fd
BufferedSerialStream         < SerialStream         # PosixSerialDriver still does termios; channel adopts the fd
BufferedSerialInterface      < SerialInterface      # overrides only the stream class
BufferedTcpipClientInterface < TcpipClientInterface # ditto
BufferedTcpipServerInterface < TcpipServerInterface # Ruby accept loop unchanged; each accepted fd gets a channel
BufferedUdpInterface         < UdpInterface         # UdpChannel under read_interface/write_interface
```

- Existing connect/option parsing stays in Ruby (hostnames, ports,
  baud/parity via the existing drivers); the channel *adopts* the
  configured fd. C++ owns only the hot loop.
- Protocols (Burst/Fixed/Length/Terminated/Preidentified) are
  untouched — they call `stream.read` exactly as today and receive the
  same chunked Strings (binary, ASCII-8BIT).
- Datagram semantics for UDP are preserved: one `read` returns one
  datagram, as `UdpReadSocket#read` does now.

### Rollout

1. **Opt-in**: the buffered classes are selectable from
   `cmd_tlm_server.txt` today (`INTERFACE ... buffered_serial_interface.rb ...`)
   with identical parameters.
2. **Default flip**: interface declarations grow a `BUFFERED false`
   opt-out keyword; the stock interfaces become aliases for the
   buffered ones once parity is proven.

## Verification

- The existing stream/interface specs run against the buffered
  subclasses unchanged (same contract).
- **The drop-proof benchmark** (committed): a Ruby thread that hogs the
  GVL (tight loop) while a blaster sends N sequenced UDP datagrams /
  serial bytes at line rate. Current backend: kernel drop counters
  climb and sequence gaps appear. Buffered backend: zero gaps, drops
  only ever appear in the *visible* counters, and only past the
  configured ring size.
- Loopback integration with the demo INST target (TCP) and pty-based
  serial tests; CmdTlmServer GUI shows live counts from a buffered
  interface.

## Milestones

1. **Core + TCP client**: BufferedChannel/StreamChannel/TcpChannel,
   BufferedTcpipClientStream/Interface, specs, the GVL-hog benchmark.
2. **UDP** (the main drop victim): DatagramChannel/UdpChannel,
   BufferedUdpInterface, sequence-gap proof.
3. **Serial**: SerialChannel + BufferedSerialInterface, pty tests.
4. **TCP server** interface + write-path polish (high-water policies,
   flush-on-disconnect semantics).
5. **Default flip**: `BUFFERED` keyword, stock aliases, docs, CI.

## Non-goals / notes

- No external dependencies (no libuv/boost); `std::thread` +
  pthread condvars + blocking syscalls. A single kqueue/epoll
  multiplexer thread is a *later* optimization if interface counts grow
  — the Ruby-facing API doesn't change.
- Thread-per-channel blocking syscalls are already fully event-driven
  (the kernel parks the thread); the no-polling requirement is about
  sleep loops and timers, of which there are none.
- Windows (overlapped I/O) is out of scope for the first pass; the
  Ruby classes fall back to the stock streams where the extension is
  unavailable.
