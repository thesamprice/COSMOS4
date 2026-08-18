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
  by policy: **drop-oldest** (freshest telemetry wins) or drop-newest,
  with **back pressure** the default for the byte streams (TCP and —
  see the milestone 3 section — serial). Every drop is **counted and
  queryable**
  (`drop_count`, `buffered_bytes`, `high_water`) — unlike today's
  silent kernel drops. Interfaces surface these in their existing
  counters so the CmdTlmServer GUI shows them.
- Reader/writer latch `errno`/EOF; the next Ruby call raises the mapped
  exception (`EOFError`, `Errno::*`) matching current Stream behavior.
- Channels are TypedData objects. `disconnect` (and GC dealloc, and a
  VM-teardown end proc) signal stop, unblock the parked syscall, and
  join — the teardown ordering lessons from the Qt 6 bindings apply
  directly.
- **Unblocking is per transport.** `shutdown(2)` works for connected
  sockets (TCP, connected UDP) but on macOS it fails with `ENOTCONN`
  against an *unconnected* UDP socket and leaves the reader parked in
  `recvfrom(2)` forever. `DatagramChannel` therefore parks in `poll(2)`
  on the socket plus a self-pipe and writes one byte to the pipe to
  stop. This is still event driven — `poll(2)` blocks in the kernel
  with an infinite timeout — and it costs one `poll` per *burst*, not
  per datagram, because the reader drains with `MSG_DONTWAIT` until the
  socket reports `EAGAIN`.
- **Datagram rings are bounded twice.** 65536 datagrams *or* 64 MiB,
  whichever is reached first, so a stream of maximum sized datagrams
  cannot reserve 4 GiB. `drop_count` counts whole datagrams (the
  meaningful unit for a message transport) where the stream channels
  count bytes.
- **`:backpressure` is refused on a datagram channel.** Declining to
  read the socket cannot make UDP lossless; it only moves the loss into
  `SO_RCVBUF`, where it is silent and uncountable — the exact failure
  this extension exists to fix. Datagram channels offer `:drop_oldest`
  (default) and `:drop_newest` only.

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

**Buffered is the default.** As each transport lands, the stock class
(`SerialInterface`, `TcpipClientInterface`, `UdpInterface`, ...) routes
through the buffered channel automatically — existing config files get
the fix with no changes. Opting out:

- per interface: a `BUFFERED false` interface option in
  `cmd_tlm_server.txt` (ring sizing rides alongside it:
  `BUFFERED_RING_BYTES`, and `BUFFERED_OVERFLOW` — for UDP
  `drop_oldest|drop_newest` plus `BUFFERED_RING_DATAGRAMS`, for serial
  `backpressure|drop_oldest|drop_newest`)
- globally: `COSMOS_NO_BUFFERED_IO=1` (also the automatic fallback when
  the extension is not built, e.g. platforms the first pass does not
  cover), which uses the original pure-Ruby paths unchanged.

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

## Milestone 3 (serial): decisions and deviations

### Overflow policy: serial defaults to **back pressure**, not drop-oldest

This reverses the "drop-oldest for serial" line above, deliberately.

Drop-oldest is right for UDP because a datagram is a *self contained*
telemetry sample: throwing away an old one costs exactly that one
sample and the next one still parses. A serial byte is not
self contained. Every COSMOS serial protocol (Length, Terminated,
Fixed, Preidentified, Burst) is a framing state machine over the byte
stream, so dropping bytes out of the middle splices two unrelated
positions together: a Length protocol then reads a bogus length and
mis-frames until it happens to resync, and a Terminated protocol glues
two packets into one. The damage is not bounded by the number of bytes
dropped.

Weigh the two failure modes at the point they actually differ - a ring
that has filled, which with the default 16 MiB ring means Ruby has been
starved for 24 minutes at 115200 baud or 3 minutes at 921600:

- **Back pressure**: the reader stops reading the port. The bytes back
  up into the tty input buffer and then, if the port is configured
  `FLOW_CONTROL RTSCTS`, into the peer via RTS - and *nothing is lost
  at all*. Without RTS/CTS the tty buffer overruns, which is byte for
  byte the failure that happens today. Buffering can therefore never
  make an existing deployment worse; it only moves the cliff from
  ~16 KiB of tty buffer to 16 MiB plus the tty buffer.
- **Drop-oldest**: loss is counted, but it is *new* loss in a place
  operators have never had to reason about, it splices the stream mid
  frame, and - decisively - it **defeats RTS/CTS**. A reader that never
  stops reading never asserts flow control, so the one configuration in
  which a serial link is genuinely lossless would silently stop being
  lossless the day this shipped.

The visibility argument that justified drop-oldest for UDP is answered
instead with **`stall_count`**: every time the reader has to stop
reading because the ring is full it is counted, so "Ruby is not
draining" is queryable *before* anything overruns, which is more
warning than a drop counter gives. `high_water` and `buffered_bytes`
sit alongside it.

Both drop policies remain available per interface
(`OPTION BUFFERED_OVERFLOW drop_oldest|drop_newest`) for a source that
really does prefer freshness over framing.

### Deviations from the milestone 1/2 mechanics

- **`adopt` takes a socket *or* a tty.** The M1 socket-only check is
  now "`getsockopt(SO_TYPE)` succeeds → `TcpChannel`, else `isatty` →
  `SerialChannel`, else `ArgumentError`". The TCP path is unchanged: a
  socket still has to be a socket. Everything else (a regular file, a
  pipe) is still refused so the caller falls back.
- **Teardown uses the M2 self-pipe, not `shutdown(2)`.** `shutdown(2)`
  is a socket call and fails with `ENOTSOCK` on a character device, and
  closing the descriptor to break a parked reader is a use after free
  race (the fd number is reusable the instant it is closed, so the
  parked `read(2)` can start reading somebody else's file). The reader
  parks in `poll(2)` on the tty plus a self-pipe exactly as
  `DatagramChannel` does.
- **The adopted tty descriptor is made non blocking.** `dup(2)` shares
  the file status flags with Ruby's descriptor, which is safe here
  because `PosixSerialDriver` only ever uses `read_nonblock` and
  `write_nonblock`, both of which already handle `EAGAIN`. It buys the
  invariant that matters: no channel thread can ever park anywhere the
  self-pipe cannot reach it, so `stop()` can always join.
- **The writer waits for `POLLOUT` on `EAGAIN`.** The base class byte
  loop treats anything but `EINTR` as fatal, which is correct for a
  blocking socket and wrong for a non blocking tty, so `SerialChannel`
  overrides `transport_send_item`. The base class - and therefore
  TCP - is untouched.
- **`EIO` from a tty read is latched as EOF, not as an error.** On a
  tty `EIO` is a hangup (Linux reports the pty master closing this way,
  as does a USB serial adapter being unplugged). Both it and a zero
  length read mean the same thing to the interface.
- **`stall_count` was added to `StreamChannel`**, shared with TCP,
  because the back pressure loop it counts is shared. It is a counter
  only - no behavior changed for TCP.
- **A separate write-only port gets `drop_oldest`.** When
  `write_port_name != read_port_name` the write port gets its own small
  channel, and nothing ever reads that channel's ring. Back pressure
  there would wedge its reader against a full ring and pile bytes up in
  a tty nobody is draining, so the ring drops instead.
- **A disconnected read returns `''` rather than raising.** The stock
  stream ends up dereferencing a nil handle if its port is closed mid
  read; `''` is what `StreamInterface#read_interface` already treats as
  "shut this interface down", and it is what the buffered TCP stream
  does.
- **Ruby still owns termios.** `PosixSerialDriver` opens the port and
  applies every flag; the channel only adopts the configured
  descriptor. Nothing in the extension knows what a baud rate is.

## Milestones

1. **Core + TCP client**: BufferedChannel/StreamChannel/TcpChannel,
   BufferedTcpipClientStream/Interface, specs, the GVL-hog benchmark.
2. **UDP** (the main drop victim): DatagramChannel/UdpChannel,
   BufferedUdpInterface, sequence-gap proof.
3. **Serial**: SerialChannel + BufferedSerialInterface, pty tests.
4. **TCP server** interface + write-path polish (high-water policies,
   flush-on-disconnect semantics).
5. **Opt-out plumbing + docs**: `BUFFERED false` option,
   `COSMOS_NO_BUFFERED_IO`, fallback verification, docs, CI.

## Non-goals / notes

- No external dependencies (no libuv/boost); `std::thread` +
  pthread condvars + blocking syscalls. A single kqueue/epoll
  multiplexer thread is a *later* optimization if interface counts grow
  — the Ruby-facing API doesn't change.
- Thread-per-channel blocking syscalls are already fully event-driven
  (the kernel parks the thread); the no-polling requirement is about
  sleep loops and timers, of which there are none.
- Windows (overlapped I/O) is out of scope for the first pass; where
  the extension is unavailable the stock pure-Ruby paths are used
  automatically (same mechanism as the opt-out).
