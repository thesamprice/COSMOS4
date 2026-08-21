# Buffered I/O interface options (operator reference)

Every COSMOS interface reads its device from a **Ruby** thread, and Ruby
threads share one global lock (the GVL). While any other thread holds it —
decom, logging, GUI painting, a running script — the interface thread is not
scheduled and the device is not drained. UDP datagrams then fall out of
`SO_RCVBUF` and serial bytes out of the tty input buffer, **silently and
uncounted**; TCP does not lose data but back-pressures the sender and its
timestamps drift.

COSMOS ships a small C++ extension that moves the device reads and writes onto
threads which never touch a Ruby API, so the OS buffers are emptied the instant
data arrives regardless of what Ruby is doing. **It is on by default** on every
TCP, UDP and serial interface. Existing configuration files get the fix with no
changes, and nothing about the data, the protocols, the counters or the
exceptions changes.

This page is the configuration reference. The rationale, the trade-offs and the
measurements are in [buffered_io_design.md](buffered_io_design.md).

## Which interfaces buffer

| Interface | Buffered by default | Overflow default |
| --- | --- | --- |
| `tcpip_client_interface.rb` | yes | `backpressure` |
| `tcpip_server_interface.rb` | yes, per accepted client | `backpressure` |
| `udp_interface.rb` | yes | `drop_oldest` |
| `serial_interface.rb` | yes | `backpressure` |

Routers built on these interface classes buffer the same way; they are the same
classes.

## Options

All of these are `OPTION` lines under an `INTERFACE` (or `ROUTER`) in
`cmd_tlm_server.txt`, and they take effect the next time the interface
connects.

### `OPTION BUFFERED FALSE`

Turns the buffered backend off for this one interface, which reverts it to the
original pure-Ruby stream. Nothing else about the interface changes. `TRUE` is
the default and never needs to be written.

```
INTERFACE INST_INT tcpip_client_interface.rb localhost 8080 8081 10.0 nil BURST
  OPTION BUFFERED FALSE
```

Only `TRUE` / `FALSE` (in any case) are accepted. Anything else — `no`, `0`,
`off` — raises at config load rather than being read as "on", which is what a
lenient parse would have done with it.

### `OPTION BUFFERED_RING_BYTES <bytes>`

Size of the user-space buffer the C++ reader fills, per interface — and for a
TCP server, per connected client. Default **16 MiB** for the byte streams (TCP,
serial), **64 MiB** for UDP.

This is the backlog the interface can absorb while Ruby is not draining. At
115200 baud, 16 MiB is about 24 minutes of starvation; at 921600 baud about
3 minutes. Raise it if you have a burst source and plenty of RAM; lower it on a
memory-constrained machine or when you would rather find out early (via
`stall_count`) that Ruby is falling behind.

```
  OPTION BUFFERED_RING_BYTES 67108864
```

Must be between **4096** and **1 GiB**; anything outside that raises at config
load.

### `OPTION BUFFERED_READ_CHUNK <bytes>`

Most bytes one `read` returns. Default **65536** — deliberately the same amount
the original pure-Ruby streams read, because a `BURST` protocol turns whatever
one read returns into one packet, so changing this changes the packet sizes an
existing configuration has always produced.

Raise it when you would rather drain a large backlog in fewer, bigger reads (a
`LENGTH` or `TERMINATED` protocol reassembles regardless of chunk size, so
nothing about the packets changes there). A read never returns more than is
actually buffered, so a large value costs nothing while the device is keeping
up.

```
  OPTION BUFFERED_READ_CHUNK 1048576
```

### `OPTION BUFFERED_WRITE_HIGH_WATER <bytes>`

Bytes allowed to queue for the C++ writer thread before a write blocks (and
then times out with `Timeout::Error` after the interface's write timeout).
Default **2 MiB**.

This is a real trade-off, not a tuning knob to raise blindly:

* **Lower** — the queue fills sooner, so a peer that has stopped reading
  surfaces as a `Timeout::Error` at about the same point the original pure-Ruby
  stream would have raised one. The failure is visible early.
* **Higher** — more of a command burst is absorbed while some other Ruby thread
  holds the GVL, at the price of a dead link looking healthy for longer (and of
  that much memory sitting in the queue).

The default is small on purpose: the queue exists to absorb a burst, not to
hide a dead peer.

```
  OPTION BUFFERED_WRITE_HIGH_WATER 8388608
```

### `OPTION BUFFERED_RING_DATAGRAMS <count>` (UDP only)

Datagrams the UDP ring holds before it starts dropping (must be between **16**
and **1048576**). Default **65536**. The
UDP ring is bounded twice — by this count *and* by `BUFFERED_RING_BYTES` —
because 65536 maximum-sized datagrams would otherwise reserve 4 GiB. Whichever
limit is reached first starts dropping.

```
  OPTION BUFFERED_RING_DATAGRAMS 16384
  OPTION BUFFERED_RING_BYTES 16777216
```

### `OPTION BUFFERED_OVERFLOW <policy>`

What the reader does once the ring is full.

| Policy | Meaning | Available on |
| --- | --- | --- |
| `backpressure` | Stop reading the device until Ruby drains the ring. **Nothing is ever dropped by us.** | TCP client, TCP server, serial (default) |
| `drop_oldest` | Freshest data wins; the oldest is discarded and counted. | all (UDP default) |
| `drop_newest` | Keep the oldest; discard what does not fit, counted. | all |

`backpressure` is **refused on UDP**. Declining to read a UDP socket cannot make
UDP lossless — it only moves the loss back into `SO_RCVBUF`, where it is silent
and uncountable, which is the exact failure this extension exists to fix.

`backpressure` is the default for the *byte* streams for two reasons. A serial
or TCP byte is not a self-contained sample the way a datagram is: every COSMOS
protocol (Length, Terminated, Fixed, Burst, Preidentified) is a framing state
machine, so dropping bytes out of the middle splices two unrelated positions
together and mis-frames until it happens to resync. And on a serial port
configured `FLOW_CONTROL RTSCTS`, a reader that never stops reading never
asserts RTS — a drop policy would silently defeat the one configuration in
which a serial link is genuinely lossless.

```
  OPTION BUFFERED_OVERFLOW drop_oldest
```

A policy this interface does not support — a typo, or `backpressure` on UDP —
raises at config load. It used to be ignored, which meant a misconfigured ring
quietly ran the default policy instead of the one that was asked for.

**A write-only port ignores this and always drops.** When an interface is
configured with a write port and no read port — a separate write-only serial
port, or a TCP interface with only a write socket — that descriptor still gets
a channel, and that channel still has a read ring, but nothing will ever drain
it. Back pressure on a ring nobody reads is a reader thread wedged against it
forever, with bytes piling up in the tty or the kernel receive buffer behind
it. Those channels are therefore always `drop_oldest` regardless of
`BUFFERED_OVERFLOW`. Nothing is lost that was going anywhere: there is no read
side to deliver it to. The ring is also sized down (64 KiB) for the same
reason, so a write-only port does not reserve a telemetry-sized ring.

## Serial port locking

A serial interface takes exclusive ownership of its port when it opens it:
`flock(2)` (which every COSMOS process honors, and which the buffered channel's
duplicated descriptor shares) plus `TIOCEXCL` where the driver supports it
(which makes the kernel refuse `open(2)` from applications that never check
locks). A second interface or a second COSMOS process pointed at the same port
fails immediately instead of silently interleaving reads with the first.

To share a port with another application on purpose, set
`COSMOS_NO_SERIAL_LOCK` in the environment. No lock of any kind is then taken.

```
COSMOS_NO_SERIAL_LOCK=1 ruby tools/CmdTlmServer
```

Nothing else changes, and there is no per-interface option for it: sharing a
tty is a property of the machine, not of one configuration line.

## Turning it off globally

Set `COSMOS_NO_BUFFERED_IO=1` in the environment before starting the tool. Every
interface then uses the original pure-Ruby path, exactly as it did before the
extension existed.

```
COSMOS_NO_BUFFERED_IO=1 ruby tools/CmdTlmServer
```

Values of `0`, `false`, `FALSE`, `no` and `NO` are treated as "not set".

## Automatic fallbacks

The buffered path is never allowed to break an interface that plain Ruby can
serve. It is skipped — silently, with one informational log line — whenever:

* the C++ extension is not built for this platform (Windows is not covered by
  the first pass);
* `COSMOS_NO_BUFFERED_IO` is set;
* the interface is configured `OPTION BUFFERED FALSE`;
* the descriptor is not something the channel can adopt — not a real connected
  socket, not a real POSIX tty, not a real bound UDP socket. A mocked or
  half-connected device keeps the stock path;
* anything at all raises while adopting the descriptor.

In every one of those cases the interface runs the original code unchanged.

## Reading the counters

Buffered counters ride along with the interface status the server already
publishes. `get_interface_info` / `get_all_interface_info` append a Hash to
their previous (unchanged) response with these String keys:

| Key | Meaning |
| --- | --- |
| `buffered` | whether a C++ channel is actually in use for this interface |
| `bytes_read` / `bytes_written` | bytes moved by the C++ threads |
| `drop_count` | data the ring threw away. **Always 0 under `backpressure`.** For UDP this is the loss that used to happen invisibly inside `SO_RCVBUF` |
| `stall_count` | times the reader had to stop reading the device because the ring was full. The *early warning* that Ruby is not draining — it climbs before anything overruns. Always 0 for UDP, which cannot back-pressure |
| `buffered_bytes` | backlog in the ring right now |
| `high_water` | largest backlog ever held |
| `ring_bytes` | configured ring size |
| `pending_write_bytes` | queued for the writer thread |
| `buffered_datagrams` | UDP only: datagrams in the ring right now |
| `clients` | TCP server only: how many connected clients are buffered |

The same hash is on the interface object as `interface.buffered_stats` (Symbol
keys there).

**Routers do not report these.** `get_router_info` /
`get_all_router_info` still return the original eight elements with no
buffered Hash appended, and that includes a router built on a
preidentified `tcpip_server_interface.rb` — which really is buffered, and
whose counters really do exist. Only the *interface* API surfaces them. To
watch a router's buffering, reach the object directly:
`Cosmos::CmdTlmServer.routers.all['ROUTER_NAME'].buffered_stats`. The
router API was left alone deliberately: appending a ninth element there
would be a second, separate compatibility commitment for a display that
does not yet ask for one.

What to watch, in order of severity:

1. **`stall_count` rising** — Ruby is not keeping up with this device. Nothing
   has been lost yet. This is the number to alarm on.
2. **`drop_count` rising** — data has been discarded, and you know exactly how
   much. On UDP some drop under extreme load is expected and is strictly better
   than the silent kernel drop it replaced; on a byte stream it only happens if
   you configured a drop policy.
3. **`high_water` approaching `ring_bytes`** — the ring is being used to its
   limit; raise `BUFFERED_RING_BYTES` or find out why Ruby is starved.

## Tuning: `RUBY_THREAD_TIMESLICE`

Ruby 4 honors the `RUBY_THREAD_TIMESLICE` environment variable (milliseconds,
default 100). It is how long a thread that never yields voluntarily — a tight
Ruby loop, which is what decom and script execution look like to an interface
thread — can hold the GVL before the scheduler takes it away.

Measured on this code base while a thread hogged the GVL, setting
`RUBY_THREAD_TIMESLICE=1` cut the wake latency of a starved reader from about
**116 ms to about 12 ms**, at a cost of roughly **5% throughput** to the extra
context switching.

This is worth *evaluating* for a CmdTlmServer deployment where command latency
or timestamp accuracy matters more than raw decom throughput. COSMOS does not
set it anywhere and will not: it is a whole-VM setting whose right value depends
on the workload, and the buffered backends already remove the data-loss
consequence of a long timeslice. Measure it against your own configuration
before adopting it.
