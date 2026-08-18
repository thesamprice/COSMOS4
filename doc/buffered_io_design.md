# Buffered C++ I/O backends (design)

> **Status: complete.** Milestones 1-5 are implemented and shipped:
> core + TCP client, UDP, serial, TCP server, and the opt-out plumbing,
> counters and documentation.

## Summary for operators

COSMOS interfaces now drain their devices from C++ threads that never take the
Ruby GVL. **This is on by default** for every TCP, UDP and serial interface, and
existing configuration files get it with no changes.

**What it fixes.** While any Ruby thread is busy (decom, logging, GUI painting,
a running script) the interface thread is not scheduled. UDP datagrams then
overflow `SO_RCVBUF` and serial bytes overrun the tty buffer — silently and
uncounted. TCP loses nothing but back-pressures the spacecraft and stamps
telemetry with the time Ruby finally woke up rather than the time the data
arrived.

**What you see.** `test/benchmarks/buffered_io_bench.rb`, with a Ruby thread
deliberately hogging the GVL (macOS arm64, Ruby 4.0.6):

| Scenario | Stock | Buffered |
| --- | --- | --- |
| UDP, 50k datagrams at 25k/s | **46473 lost — 92.9% of the stream, silently** | 10 lost (0.02%) |
| Serial (pty, 20k records at 10k/s) | 9 records/s drained | 9722 records/s drained |
| TCP client, sustained 32 MiB | receive time off by 300 ms mean / 1.25 s max | 4 ms mean / 147 ms max |
| TCP server, 4 clients | 653 KB piled up in the kernel receive queues; 2282 records/s | 3 KB; 14371 records/s |

Nothing that used to work behaves differently: same data, same protocols, same
counters, same exceptions, same config file syntax.

**What is new to look at.** Interfaces publish `drop_count` (data the ring
discarded — always zero for TCP and serial under their defaults) and
`stall_count` (times the reader had to stop because Ruby was not draining — the
*early warning*, before anything is lost). Both ride along with the existing
interface status. Loss that used to be invisible is now counted.

**How to turn it off.** `OPTION BUFFERED FALSE` on one interface, or
`COSMOS_NO_BUFFERED_IO=1` for the whole process. It is also skipped
automatically wherever the extension is not built. In every case the original
pure-Ruby code runs unchanged.

Full configuration reference:
[buffered_io_configuration.md](buffered_io_configuration.md).

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

## Milestone 4 (TCP server): decisions and deviations

The Ruby accept loop is byte for byte the stock one. The only change at the
accept site is which stream class the accepted socket is wrapped in, and even
that is a one line `build_client_stream` hook so the fallback and the option
handling live in one place.

### A write-only client socket is deliberately **not** adopted

This is the one place where buffering a socket would break the server.

`check_for_dead_clients` detects a client that has gone away from the *write*
port by calling `recvfrom_nonblock` on that socket from Ruby: a success (or a
reset) means the client is gone, `EWOULDBLOCK` means it is still there. A C++
reader thread on the same descriptor consumes the EOF first, so Ruby would see
`EWOULDBLOCK` forever and the client would never be reaped — a leak of one
interface, one stream and one channel per departed client, growing without
bound on a server whose clients reconnect.

So `BufferedSocketStream` grew one option, `:adopt_write_only` (default true,
so nothing about milestones 1-3 changes), and the server passes false. The
write-only sockets in a separate-ports configuration therefore keep the stock
Ruby write path.

Nothing is given up by that. The buffered writer exists to stop a slow peer
stalling a GVL-holding thread, and a TCP server **already** solves that
problem: `Interface#write` only pushes onto the server's own `@write_queue`,
and a dedicated write thread does the socket calls. Adding a second queue
underneath the first would be pure double-buffering — more memory, one more
place for data to sit, and a client's death detected later.

When the read and write ports are the *same* (one socket per client, the usual
configuration) the single channel serves both directions, exactly as the TCP
client stream does. That is safe because `check_for_dead_clients` explicitly
skips the recvfrom probe in that case and leaves the detection to the read
thread, which the buffered read path performs identically to the stock one:
buffered bytes first, then `EOFError`.

### The write path composes without surprises

With a shared socket, `write_to_clients` calls `interface.write` → the channel's
queue. Two consequences, both benign:

- A dead client is detected one packet later than stock. `write` returns as
  soon as the data is queued, so the `EPIPE`/`ECONNRESET` is latched by the
  writer thread and raised by the *next* `write`, where `write_to_clients`
  rescues it and drops the client exactly as it does today.
- A slow client is tolerated longer before it is dropped. Stock raises
  `Timeout::Error` after `write_timeout` in the socket call; buffered raises it
  only once the queue is above its high water mark and stays there for
  `write_timeout`. Below the high water mark the enqueue is instant, so a slow
  client can no longer make the server's single write thread wait on it — which
  is the whole point.

### `stop()` had to become thread safe

Found by running `spec/tools` against the buffered backend for the first time.
`InterfaceThread#stop` disconnects the interface from the server's thread while
the interface's own thread can be inside `handle_connection_lost` → `disconnect`,
so two Ruby threads land in `BufferedChannel::stop()` together. `std::thread::join`
is not reentrant: the second joiner gets `ESRCH` and throws `std::system_error`,
which is a C++ exception crossing `rb_thread_call_without_gvl` and therefore
`std::terminate` — not something Ruby's `rescue Exception` can catch. The VM
aborted with SIGABRT.

`stop()` now takes a dedicated `stop_mutex_` for its whole body (the second
caller waits and then finds the threads already reaped) and the joins are
wrapped so nothing can ever throw out of a function that runs with the GVL
released. This is a latent milestone 1 bug that only a multi-threaded
disconnect could reach; TCP/UDP/serial behavior is unchanged.

## Milestone 5 (polish): decisions

- **Counters are appended, never rearranged.** `Interfaces#get_info` (and
  therefore `get_interface_info` / `get_all_interface_info`) gained a **ninth**
  element: a Hash of buffered counters with String keys, so a direct caller and
  a JSON-RPC caller see the same shape. The first eight elements are exactly
  what they always were, so every existing caller keeps working. A Hash rather
  than more positional fields means the next counter needs no API change at
  all, and an interface with no buffered backend answers with `false` and zeros
  rather than nothing, so a display never has to special-case it.
- **One statistics shape for every transport.** `BufferedIO.empty_stats`
  defines the canonical zeroed hash and every buffered stream, interface and
  the server aggregate build from it. `stall_count` and `ring_bytes` were added
  to the TCP and UDP hashes for parity with serial (additive; nothing reads
  fewer keys than before). UDP keeps its extra `buffered_datagrams` and reports
  `stall_count` 0, which is correct: a datagram channel refuses back pressure
  on purpose.
- **The TCP server aggregates its clients.** A server has no stream of its own,
  so `TcpipServerInterface#buffered_stats` sums the per-client counters, with
  `high_water` and `ring_bytes` reported as the *worst* client rather than a
  sum (they are per-client sizes) and a `:clients` count alongside. An operator
  gets "is any client backing up" without enumerating clients.
- **`StreamInterface#buffered_stats` delegates to the stream**, so serial and
  the TCP client needed no code of their own, and a stock stream answers with
  zeros. `Interface` itself was left alone — the CmdTlmServer side uses
  `respond_to?`, so a router or a custom interface class needs no change.
- **`BUFFERED_OVERFLOW` was added to the TCP client interface** for parity with
  serial, the TCP server and UDP. Default unchanged (`backpressure`).

## Milestones

1. **Core + TCP client** — *done*. BufferedChannel/StreamChannel/TcpChannel,
   BufferedTcpipClientStream/Interface, specs, the GVL-hog benchmark.
2. **UDP** (the main drop victim) — *done*. DatagramChannel/UdpChannel,
   BufferedUdpInterface, sequence-gap proof.
3. **Serial** — *done*. SerialChannel + BufferedSerialInterface, pty tests.
4. **TCP server** — *done*. Per-client channels off the stock accept loop,
   write-path composition with the server's own write thread, multi-client and
   per-client-disconnect specs, the 4-client server benchmark.
5. **Opt-out plumbing + docs** — *done*. `BUFFERED false` option,
   `COSMOS_NO_BUFFERED_IO`, fallback verification, counters surfaced through
   `get_interface_info`, and
   [buffered_io_configuration.md](buffered_io_configuration.md).

## Tuning: `RUBY_THREAD_TIMESLICE`

A milestone 1 finding, recorded here because it is the other half of the same
problem and because it is easy to reach for and easy to get wrong.

Ruby 4 honors `RUBY_THREAD_TIMESLICE` (milliseconds, default 100): how long a
thread that never yields voluntarily may hold the GVL before the scheduler
takes it away. Measured against this code base with a thread hogging the GVL,
`RUBY_THREAD_TIMESLICE=1` cut a starved reader's wake latency from about
**116 ms to about 12 ms** for roughly **5% of throughput** lost to the extra
context switching.

That is worth **evaluating** for a CmdTlmServer deployment where command
latency or timestamp accuracy matters more than raw decom throughput. COSMOS
deliberately does **not** set it anywhere: it is a whole-VM knob whose right
value depends entirely on the workload, and the buffered backends already
remove the *data loss* consequence of a long timeslice — what is left is
latency, which is a much cheaper thing to be wrong about. Measure it against
your own configuration before adopting it.

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
