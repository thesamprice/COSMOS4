/*
# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
*/

#include "stream_channel.h"

#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include <stdexcept>

namespace cosmos {

const size_t StreamChannel::DEFAULT_RING_BYTES;
const size_t StreamChannel::READ_CHUNK_BYTES;
const size_t StreamChannel::MAX_TIME_MARKS;

static double now_seconds() {
  struct timeval tv;
  ::gettimeofday(&tv, NULL);
  return (double)tv.tv_sec + ((double)tv.tv_usec / 1000000.0);
}

StreamChannel::StreamChannel(int fd, size_t ring_bytes)
    : BufferedChannel(fd),
      ring_bytes_(0),
      ring_head_(0),
      ring_count_(0),
      overflow_policy_(OverflowPolicy::BACKPRESSURE),
      total_received_(0),
      last_receive_time_(0.0),
      last_chunk_time_(0.0) {
  if (ring_bytes < READ_CHUNK_BYTES) ring_bytes = READ_CHUNK_BYTES;
  // Construction contract for every channel: if it fails, fd_ is cleared and
  // the descriptor is NOT closed, so the adopter still owns it and closes it
  // exactly once. Without this the base destructor - which runs on a failed
  // construction - would close a descriptor the caller then closes again, and
  // a recycled fd number makes that a use after free on someone else's file.
  try {
    ring_.resize(ring_bytes);
  } catch (...) {
    fd_ = -1;
    throw;
  }
  ring_bytes_.store(ring_bytes);
}

StreamChannel::~StreamChannel() {
  // Threads must be joined before the ring is destroyed.
  stop(0.0);
}

uint64_t StreamChannel::buffered_bytes() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return (uint64_t)ring_count_;
}

// mutex_ must be held. Discards marks that no longer cover buffered bytes,
// always keeping the one that covers the oldest buffered byte.
void StreamChannel::prune_marks() {
  uint64_t oldest = total_received_ - (uint64_t)ring_count_;
  while (marks_.size() > 1 && marks_[1].offset <= oldest) {
    marks_.pop_front();
  }
}

// mutex_ must be held. Drop oldest on overflow.
void StreamChannel::ring_push(const unsigned char* data, size_t length,
                              double timestamp) {
  size_t capacity = ring_.size();
  uint64_t chunk_offset = total_received_;

  size_t dropped_tail = 0;
  if (overflow_policy_.load() == OverflowPolicy::DROP_NEWEST) {
    size_t free_bytes = capacity - ring_count_;
    if (length > free_bytes) {
      dropped_tail = length - free_bytes;
      drop_count_.fetch_add((uint64_t)dropped_tail);
      length = free_bytes;
      if (length == 0) {
        total_received_ += (uint64_t)dropped_tail;
        last_receive_time_.store(timestamp);
        return;
      }
    }
  }

  if (length >= capacity) {
    // The incoming block alone overruns the ring - keep only the newest tail.
    size_t dropped = ring_count_ + (length - capacity);
    drop_count_.fetch_add((uint64_t)dropped);
    memcpy(&ring_[0], data + (length - capacity), capacity);
    ring_head_ = 0;
    ring_count_ = capacity;
    chunk_offset += (length - capacity);
    marks_.clear();
  } else {
    size_t free_bytes = capacity - ring_count_;
    if (length > free_bytes) {
      size_t dropped = length - free_bytes;
      ring_head_ = (ring_head_ + dropped) % capacity;
      ring_count_ -= dropped;
      drop_count_.fetch_add((uint64_t)dropped);
    }
    size_t tail = (ring_head_ + ring_count_) % capacity;
    size_t first = capacity - tail;
    if (first > length) first = length;
    memcpy(&ring_[tail], data, first);
    if (length > first) memcpy(&ring_[0], data + first, length - first);
    ring_count_ += length;
  }

  total_received_ += (uint64_t)length + (uint64_t)dropped_tail;
  last_receive_time_.store(timestamp);
  if ((uint64_t)ring_count_ > high_water_.load()) {
    high_water_.store((uint64_t)ring_count_);
  }

  // Keep the receive time of this chunk with the data. The mark cap bounds
  // memory when a peer dribbles single bytes; past the cap the previous mark
  // covers the new bytes (bounded staleness, never a wrong ordering).
  if (marks_.empty() || marks_.size() < MAX_TIME_MARKS) {
    marks_.push_back(TimeMark(chunk_offset, timestamp));
  }
  prune_marks();
}

// mutex_ must be held.
size_t StreamChannel::ring_pop(std::string& out, size_t max_bytes,
                               double* timestamp) {
  size_t length = ring_count_ < max_bytes ? ring_count_ : max_bytes;
  if (length == 0) return 0;
  double chunk_time = marks_.empty() ? last_receive_time_.load() : marks_.front().time;
  last_chunk_time_.store(chunk_time);
  if (timestamp) *timestamp = chunk_time;
  size_t capacity = ring_.size();
  size_t first = capacity - ring_head_;
  if (first > length) first = length;
  out.assign((const char*)&ring_[ring_head_], first);
  if (length > first) out.append((const char*)&ring_[0], length - first);
  ring_head_ = (ring_head_ + length) % capacity;
  ring_count_ -= length;
  prune_marks();
  // Ruby freed ring space - let a back-pressured reader thread resume.
  ring_space_cv_.notify_all();
  return length;
}

bool StreamChannel::try_read(std::string& out, size_t max_bytes,
                             double* timestamp) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (ring_count_ == 0) return false;
  // Keyed off what was actually popped, not off the ring being non empty: a
  // zero length pop (max_bytes of 0) must not be reported as a successful read
  // of nothing, which the caller cannot distinguish from a real empty chunk.
  return ring_pop(out, max_bytes, timestamp) > 0;
}

ChannelStatus StreamChannel::read(std::string& out, size_t max_bytes,
                                  Waiter& waiter, bool has_deadline,
                                  Clock::time_point deadline, int& err,
                                  double* timestamp) {
  std::unique_lock<std::mutex> lock(mutex_);
  while (true) {
    if (ring_count_ > 0) {
      ring_pop(out, max_bytes, timestamp);
      return ChannelStatus::OK;
    }
    // Nothing buffered - report why, newest reason first. disconnect() wins
    // over EOF because shutdown(2) makes our own read(2) return 0.
    if (waiter.aborted) return ChannelStatus::INTERRUPTED;
    if (stop_.load()) return ChannelStatus::DISCONNECTED;
    if (error_.load() != 0) {
      err = error_.load();
      return ChannelStatus::CHANNEL_ERROR;
    }
    if (eof_.load()) return ChannelStatus::END_OF_FILE;

    if (has_deadline) {
      if (Clock::now() >= deadline) return ChannelStatus::TIMEOUT;
      if (read_cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
        // Re-check the predicates once before reporting a timeout.
        if (ring_count_ > 0) continue;
        return ChannelStatus::TIMEOUT;
      }
    } else {
      read_cv_.wait(lock);
    }
  }
}

void StreamChannel::notify_all() {
  BufferedChannel::notify_all();
  ring_space_cv_.notify_all();
}

void StreamChannel::set_overflow_policy(OverflowPolicy policy) {
  std::lock_guard<std::mutex> lock(mutex_);
  overflow_policy_.store(policy);
  ring_space_cv_.notify_all();
}

// Parks in the kernel until fd_ is ready. stop() calls shutdown_fd(), which for
// a socket is shutdown(2) and makes poll(2) return at once, so this is always
// reachable by a join.
bool StreamChannel::park_ready(short events) {
  struct pollfd fds[1];
  while (!stop_.load()) {
    int descriptor = fd_.load();
    if (descriptor < 0) return false;
    fds[0].fd = descriptor;
    fds[0].events = events;
    fds[0].revents = 0;
    // -1: block indefinitely. The kernel parks the thread; this is not a poll
    // loop in the spin/timer sense the design rules out.
    int ready = ::poll(fds, 1, -1);
    if (ready < 0) {
      if (errno == EINTR || errno == EAGAIN) continue;
      latch_errno(errno);
      return false;
    }
    // Any revents at all (including HUP/ERR/NVAL) means go back to the syscall
    // and let it decide between data, EOF and errno in one place.
    if (fds[0].revents != 0) return true;
  }
  return false;
}

// Blocks in the kernel until bytes arrive. Never touches a Ruby API, so the
// GVL is irrelevant to it.
void StreamChannel::reader_loop() {
  std::vector<unsigned char> buffer(READ_CHUNK_BYTES);
  while (!stop_.load()) {
    size_t request = buffer.size();
    {
      // Under BACKPRESSURE we simply stop reading the descriptor when the ring
      // is full. The kernel then applies the same flow control the pure Ruby
      // stream relies on - no data is ever dropped on a stream transport.
      std::unique_lock<std::mutex> lock(mutex_);
      while (!stop_.load() && overflow_policy_.load() == OverflowPolicy::BACKPRESSURE &&
             ring_count_ >= ring_.size()) {
        ring_space_cv_.wait(lock);
      }
      if (stop_.load()) return;
      if (overflow_policy_.load() == OverflowPolicy::BACKPRESSURE) {
        size_t free_bytes = ring_.size() - ring_count_;
        if (request > free_bytes) request = free_bytes;
      }
    }

    ssize_t count = transport_read(&buffer[0], request);
    if (count > 0) {
      // Timestamp as close to the kernel handoff as possible.
      double timestamp = now_seconds();
      std::lock_guard<std::mutex> lock(mutex_);
      ring_push(&buffer[0], (size_t)count, timestamp);
      bytes_read_.fetch_add((uint64_t)count);
      read_cv_.notify_all();
    } else if (count == 0) {
      latch_eof();
      return;
    } else {
      int error = errno;
      if (error == EINTR) continue;
      if (error == EAGAIN || error == EWOULDBLOCK) {
        // The descriptor is non blocking (Ruby's flag, which we do not touch).
        // Retrying immediately would burn a whole core spinning on an idle
        // link, so park in poll(2) until it has something to say.
        if (!park_ready(POLLIN)) return;
        continue;
      }
      latch_errno(error);
      return;
    }
  }
}

// Byte stream write with the same contract as the base class, plus the EAGAIN
// park: a non blocking descriptor with a full send buffer is a wait for
// POLLOUT, not a transport error.
bool StreamChannel::transport_send_item(const std::string& item) {
  size_t offset = 0;
  while (offset < item.size()) {
    ssize_t sent = transport_write(item.data() + offset, item.size() - offset);
    if (sent > 0) {
      offset += (size_t)sent;
      bytes_written_.fetch_add((uint64_t)sent);
      continue;
    }
    if (sent == 0) {
      // Nothing written, no error, bytes still to go: see the base class.
      latch_errno(EIO);
      return false;
    }
    int error = errno;
    if (error == EINTR) continue;
    if (error == EAGAIN || error == EWOULDBLOCK) {
      if (!park_ready(POLLOUT)) return false; // stopping
      continue;
    }
    latch_errno(error);
    return false;
  }
  return true;
}

TcpChannel::TcpChannel(int fd, size_t ring_bytes) : StreamChannel(fd, ring_bytes) {
#ifdef SO_NOSIGPIPE
  int on = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
}

ssize_t TcpChannel::transport_read(void* buffer, size_t length) {
  int descriptor = fd_.load();
  if (descriptor < 0) {
    errno = EBADF;
    return -1;
  }
  return ::recv(descriptor, buffer, length, 0);
}

ssize_t TcpChannel::transport_write(const void* buffer, size_t length) {
  int descriptor = fd_.load();
  if (descriptor < 0) {
    errno = EBADF;
    return -1;
  }
  int flags = 0;
#ifdef MSG_NOSIGNAL
  flags |= MSG_NOSIGNAL;
#endif
  return ::send(descriptor, buffer, length, flags);
}

} // namespace cosmos
