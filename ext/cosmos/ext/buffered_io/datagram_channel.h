/*
# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
*/

/*
 * DatagramChannel - message semantics on top of BufferedChannel.
 *
 * Where StreamChannel keeps a byte ring and lets a read return any amount of
 * it, a DatagramChannel keeps a ring of whole messages: one recvfrom(2) in,
 * one read() out, boundaries preserved exactly like UdpReadSocket#read does
 * today. Each entry carries the receive time stamped by the C++ reader thread
 * and the peer address the datagram came from.
 *
 * UDP is the transport the kernel already drops silently, so back pressure is
 * not an option here: refusing to read the socket just moves the loss into
 * SO_RCVBUF where nothing can count it. The ring therefore drops by policy -
 * drop-oldest by default, freshest telemetry wins - and every dropped datagram
 * is counted in drop_count.
 *
 * Teardown does NOT rely on shutdown(2). On macOS shutdown(2) against an
 * unconnected UDP socket fails with ENOTCONN and leaves a thread parked in
 * recvfrom(2) forever (verified). The reader therefore parks in poll(2) on the
 * socket *and* a self-pipe; stop() writes one byte to the pipe. That is still
 * fully event driven - poll(2) blocks in the kernel with an infinite timeout,
 * there is no sleep loop and no timer.
 */

#ifndef COSMOS_DATAGRAM_CHANNEL_H
#define COSMOS_DATAGRAM_CHANNEL_H

#include <sys/socket.h>
#include <sys/types.h>

#include <deque>
#include <string>

#include "buffered_channel.h"

namespace cosmos {

// One received message: the bytes, when the kernel handed them over, and who
// sent them.
struct Datagram {
  std::string data;
  double time;
  struct sockaddr_storage peer;
  socklen_t peer_length;

  Datagram() : time(0.0), peer_length(0) { peer.ss_family = AF_UNSPEC; }
};

class DatagramChannel : public BufferedChannel {
public:
  // Design default: 65536 datagrams. A second, independent cap on total bytes
  // keeps 65536 maximum sized datagrams from reserving 4 GiB - whichever limit
  // is reached first starts dropping.
  static const size_t DEFAULT_RING_DATAGRAMS = 65536;
  static const size_t DEFAULT_RING_BYTES = 64 * 1024 * 1024;
  // Largest UDP payload (65535 - 8 byte UDP header - 20 byte IPv4 header). The
  // receive buffer is rounded up so a truncating recvfrom is impossible.
  static const size_t MAX_DATAGRAM_BYTES = 65507;
  static const size_t RECV_BUFFER_BYTES = 65536;

  DatagramChannel(int fd, size_t ring_datagrams, size_t ring_bytes);
  virtual ~DatagramChannel();

  // Blocking read of exactly one datagram, always called with the GVL
  // released. Buffered datagrams are always returned before an error or
  // disconnect status so nothing already received is lost.
  ChannelStatus read(Datagram& out, Waiter& waiter, bool has_deadline,
                     Clock::time_point deadline, int& err);

  // Non blocking pop, safe to call with the GVL still held. Returns false when
  // the ring is empty. Releasing the GVL costs a scheduling round trip, so the
  // common case - a datagram is already buffered - must not pay it.
  bool try_read(Datagram& out);

  virtual uint64_t buffered_bytes() const;
  uint64_t buffered_datagrams() const;
  // Most datagrams ever buffered at once is high_water() (base class); this is
  // the matching byte figure.
  uint64_t high_water_bytes() const { return high_water_bytes_.load(); }

  size_t ring_datagrams() const { return max_datagrams_; }
  size_t ring_bytes() const { return max_bytes_; }

  OverflowPolicy overflow_policy() const { return overflow_policy_.load(); }
  // Only DROP_OLDEST and DROP_NEWEST are meaningful. Returns false for
  // BACKPRESSURE, which cannot make a datagram transport lossless.
  bool set_overflow_policy(OverflowPolicy policy);

  // Receive time of the most recent datagram off the wire.
  double last_receive_time() const { return last_receive_time_.load(); }
  // Receive time of the datagram returned by the most recent read().
  double last_read_time() const { return last_read_time_.load(); }

  // True when the socket has a peer, so writes can use send(2).
  bool socket_connected() const { return socket_connected_; }
  // Destination for send(2) on an unconnected socket. Copied, not referenced.
  void set_destination(const struct sockaddr* address, socklen_t length);
  bool has_destination() const { return destination_length_ > 0; }
  // True when write() can actually put a datagram on the wire.
  bool writable() const { return socket_connected_ || destination_length_ > 0; }

protected:
  virtual void reader_loop();
  virtual bool transport_send_item(const std::string& item);
  virtual void shutdown_fd();
  // Hand the ring's memory back at disconnect instead of waiting for GC: a
  // full ring is up to ring_bytes, and a server that reconnects in a loop
  // would otherwise carry one dead ring per cycle. Both threads are joined by
  // the time stop() calls this, and a stopped channel reports DISCONNECTED, so
  // nothing can observe the emptied ring.
  virtual void release_buffers();

  // Transport primitives. UdpChannel implements them with recvfrom/sendto.
  // transport_recv must not block: it is only ever called after the socket has
  // been reported readable, and the loop drains until it reports EAGAIN.
  virtual ssize_t transport_recv(void* buffer, size_t length,
                                 struct sockaddr_storage* from,
                                 socklen_t* from_length) = 0;
  virtual ssize_t transport_send(const void* buffer, size_t length) = 0;

  // Parks in the kernel until the socket is readable or stop() fires. No
  // timeout, no timer, no polling loop.
  bool wait_readable();

  // mutex_ must be held.
  void ring_push(Datagram& datagram);
  void ring_pop(Datagram& out);

  std::deque<Datagram> ring_;
  size_t max_datagrams_;
  size_t max_bytes_;
  uint64_t buffered_bytes_;

  std::atomic<uint64_t> high_water_bytes_;
  std::atomic<OverflowPolicy> overflow_policy_;
  std::atomic<double> last_receive_time_;
  std::atomic<double> last_read_time_;

  // Self-pipe used to break the reader out of poll(2). See the file comment:
  // shutdown(2) is not usable for unconnected UDP sockets.
  int wake_pipe_[2];

  bool socket_connected_;
  struct sockaddr_storage destination_;
  socklen_t destination_length_;
};

// UdpChannel adopts a bound (and optionally connected) UDP socket.
class UdpChannel : public DatagramChannel {
public:
  UdpChannel(int fd, size_t ring_datagrams, size_t ring_bytes);

protected:
  virtual ssize_t transport_recv(void* buffer, size_t length,
                                 struct sockaddr_storage* from,
                                 socklen_t* from_length);
  virtual ssize_t transport_send(const void* buffer, size_t length);
};

} // namespace cosmos

#endif /* COSMOS_DATAGRAM_CHANNEL_H */
