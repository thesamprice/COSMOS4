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
 * StreamChannel - byte stream semantics on top of BufferedChannel.
 *
 * The reader thread appends into a fixed size byte ring. When the ring fills
 * the oldest bytes are dropped (freshest telemetry wins) and drop_count is
 * incremented so the loss is visible instead of silent.
 */

#ifndef COSMOS_STREAM_CHANNEL_H
#define COSMOS_STREAM_CHANNEL_H

#include <deque>
#include <vector>

#include "buffered_channel.h"

namespace cosmos {

// Receive time of the first byte of one read(2) result. Offsets are absolute
// stream positions so a mark stays valid across ring wraps and drops.
struct TimeMark {
  uint64_t offset;
  double time; // seconds since the epoch (CLOCK_REALTIME)
  TimeMark() : offset(0), time(0.0) {}
  TimeMark(uint64_t o, double t) : offset(o), time(t) {}
};

class StreamChannel : public BufferedChannel {
public:
  static const size_t DEFAULT_RING_BYTES = 16 * 1024 * 1024;
  static const size_t READ_CHUNK_BYTES = 65536;
  static const size_t MAX_TIME_MARKS = 65536;

  StreamChannel(int fd, size_t ring_bytes);
  virtual ~StreamChannel();

  // Blocking read, always called with the GVL released. Returns at most
  // max_bytes bytes. Buffered data is always returned before an EOF / error /
  // disconnect status so nothing already received is lost. When timestamp is
  // not NULL it receives the kernel receive time of the first returned byte.
  ChannelStatus read(std::string& out, size_t max_bytes, Waiter& waiter,
                     bool has_deadline, Clock::time_point deadline, int& err,
                     double* timestamp);

  // Non blocking pop, safe to call with the GVL still held. Returns false when
  // nothing is buffered. Releasing the GVL costs a scheduling round trip (the
  // reader lands at the back of the run queue behind whatever holds the GVL),
  // so the common case - data is already in the ring - must not pay it.
  bool try_read(std::string& out, size_t max_bytes, double* timestamp);

  virtual uint64_t buffered_bytes() const;

  // Configured ring size. Mirrored into an atomic rather than read off
  // ring_.size(): this is called from Ruby (buffered_stats, and the GC's
  // memsize callback) on another thread entirely, and reading a vector's size
  // while another thread is inside it is a data race with no upper bound on
  // how wrong the answer is. The mirror keeps reporting the size the channel
  // was built with, which is what "configured ring size" means and what a
  // status display wants.
  size_t ring_bytes() const { return ring_bytes_.load(); }

  // (see BufferedChannel#footprint)
  virtual size_t footprint() const { return sizeof(*this) + ring_bytes(); }

  OverflowPolicy overflow_policy() const { return overflow_policy_.load(); }
  void set_overflow_policy(OverflowPolicy policy);

  // Receive time of the most recent read(2) that returned data.
  double last_receive_time() const { return last_receive_time_.load(); }

  // Receive time of the first byte of the chunk returned by the most recent
  // read(). This is the time that belongs with the data Ruby is holding.
  double last_chunk_time() const { return last_chunk_time_.load(); }

protected:
  virtual void reader_loop();
  // Byte stream write with an EAGAIN park. The adopted descriptor is a dup(2)
  // of Ruby's, so its O_NONBLOCK flag belongs to Ruby and is never changed:
  // whichever mode Ruby chose, a full send buffer has to be waited on rather
  // than latched as a fatal error.
  virtual bool transport_send_item(const std::string& item);
  virtual void notify_all();

  // Parks in poll(2) on fd_ until it reports one of the requested events, or
  // until stop() fires. Returns false when the channel should stop. No self
  // pipe is needed on a socket: shutdown(2) makes poll(2) return immediately,
  // which is exactly how stop() reaches a parked thread here. No timeout, no
  // timer, no spin.
  bool park_ready(short events);

  // Must be called with mutex_ held.
  void ring_push(const unsigned char* data, size_t length, double timestamp);
  size_t ring_pop(std::string& out, size_t max_bytes, double* timestamp);
  void prune_marks();

  std::vector<unsigned char> ring_;
  // Capacity mirror, see ring_bytes(). Written once in the constructor.
  std::atomic<size_t> ring_bytes_;
  size_t ring_head_;  // index of the oldest byte
  size_t ring_count_; // bytes currently buffered

  std::atomic<OverflowPolicy> overflow_policy_;
  // Signalled when Ruby frees ring space (only used by BACKPRESSURE)
  std::condition_variable ring_space_cv_;

  // Receive timestamps travelling with the buffered bytes.
  std::deque<TimeMark> marks_;
  uint64_t total_received_; // absolute count of every byte ever pushed
  std::atomic<double> last_receive_time_;
  std::atomic<double> last_chunk_time_;
};

// TcpChannel adopts a connected socket fd and uses the socket calls so that
// SIGPIPE can be suppressed portably.
class TcpChannel : public StreamChannel {
public:
  TcpChannel(int fd, size_t ring_bytes);

protected:
  virtual ssize_t transport_read(void* buffer, size_t length);
  virtual ssize_t transport_write(const void* buffer, size_t length);
};

} // namespace cosmos

#endif /* COSMOS_STREAM_CHANNEL_H */
