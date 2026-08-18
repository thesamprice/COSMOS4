/*
# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
*/

#include "buffered_channel.h"

#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace cosmos {

BufferedChannel::BufferedChannel(int fd)
    : fd_(fd),
      stop_(false),
      started_(false),
      eof_(false),
      error_(0),
      bytes_read_(0),
      bytes_written_(0),
      drop_count_(0),
      high_water_(0),
      write_policy_(WritePolicy::BLOCK),
      write_high_water_(16 * 1024 * 1024),
      write_queue_bytes_(0),
      writing_bytes_(0) {}

BufferedChannel::~BufferedChannel() {
  stop(0.0); // joins the threads and closes the descriptor
}

void BufferedChannel::start() {
  if (started_.exchange(true)) return;
  reader_thread_ = std::thread([this]() { this->reader_loop(); });
  writer_thread_ = std::thread([this]() { this->writer_loop(); });
}

bool BufferedChannel::connected() const {
  return started_.load() && !stop_.load() && !eof_.load() && error_.load() == 0;
}

uint64_t BufferedChannel::pending_write_bytes() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return write_queue_bytes_ + writing_bytes_;
}

void BufferedChannel::notify_all() {
  read_cv_.notify_all();
  write_cv_.notify_all();
  space_cv_.notify_all();
}

void BufferedChannel::abort_wait(Waiter& waiter) {
  std::lock_guard<std::mutex> lock(mutex_);
  waiter.aborted = true;
  notify_all();
}

void BufferedChannel::latch_eof() {
  std::lock_guard<std::mutex> lock(mutex_);
  eof_.store(true);
  notify_all();
}

void BufferedChannel::latch_errno(int error) {
  std::lock_guard<std::mutex> lock(mutex_);
  int expected = 0;
  error_.compare_exchange_strong(expected, error);
  notify_all();
}

ssize_t BufferedChannel::transport_read(void* buffer, size_t length) {
  return ::read(fd_, buffer, length);
}

ssize_t BufferedChannel::transport_write(const void* buffer, size_t length) {
  return ::write(fd_, buffer, length);
}

// Byte stream default: keep writing until the whole item has been handed to
// the kernel. Behavior is identical to the loop this replaced.
bool BufferedChannel::transport_send_item(const std::string& item) {
  size_t offset = 0;
  while (offset < item.size()) {
    ssize_t sent = transport_write(item.data() + offset, item.size() - offset);
    if (sent > 0) {
      offset += (size_t)sent;
      bytes_written_.fetch_add((uint64_t)sent);
    } else if (sent < 0) {
      if (errno == EINTR) continue;
      latch_errno(errno);
      return false;
    } else {
      break;
    }
  }
  return true;
}

void BufferedChannel::shutdown_fd() {
  // Best effort: shutdown() unblocks sockets, close() below handles the rest.
  ::shutdown(fd_, SHUT_RDWR);
}

bool BufferedChannel::try_enqueue_write(const char* data, size_t length) {
  std::lock_guard<std::mutex> lock(mutex_);
  uint64_t pending = write_queue_bytes_ + writing_bytes_;
  // Always allow a single write through so a chunk larger than the high water
  // mark can never deadlock.
  if (pending != 0 && pending >= write_high_water_.load()) return false;
  write_queue_.push_back(std::string(data, length));
  write_queue_bytes_ += length;
  write_cv_.notify_all();
  return true;
}

ChannelStatus BufferedChannel::wait_for_write_space(Waiter& waiter,
                                                    bool has_deadline,
                                                    Clock::time_point deadline) {
  std::unique_lock<std::mutex> lock(mutex_);
  while (true) {
    if (waiter.aborted) return ChannelStatus::INTERRUPTED;
    if (error_.load() != 0) return ChannelStatus::CHANNEL_ERROR;
    if (stop_.load()) return ChannelStatus::DISCONNECTED;
    uint64_t pending = write_queue_bytes_ + writing_bytes_;
    if (pending == 0 || pending < write_high_water_.load()) return ChannelStatus::OK;
    if (has_deadline) {
      if (space_cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
        return ChannelStatus::TIMEOUT;
      }
    } else {
      space_cv_.wait(lock);
    }
  }
}

ChannelStatus BufferedChannel::wait_for_flush(Waiter& waiter, bool has_deadline,
                                              Clock::time_point deadline) {
  std::unique_lock<std::mutex> lock(mutex_);
  while (true) {
    if (waiter.aborted) return ChannelStatus::INTERRUPTED;
    if ((write_queue_bytes_ + writing_bytes_) == 0) return ChannelStatus::OK;
    if (error_.load() != 0) return ChannelStatus::CHANNEL_ERROR;
    if (stop_.load()) return ChannelStatus::DISCONNECTED;
    if (has_deadline) {
      if (space_cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
        return ChannelStatus::TIMEOUT;
      }
    } else {
      space_cv_.wait(lock);
    }
  }
}

// Drains the outgoing queue in order. Parks on write_cv_ when idle - no
// polling, no timers.
void BufferedChannel::writer_loop() {
  while (true) {
    std::string item;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      while (write_queue_.empty() && !stop_.load()) {
        write_cv_.wait(lock);
      }
      if (write_queue_.empty()) return; // stopped and drained
      item.swap(write_queue_.front());
      write_queue_.pop_front();
      write_queue_bytes_ -= item.size();
      writing_bytes_ = item.size();
    }

    bool failed = !transport_send_item(item);

    {
      std::lock_guard<std::mutex> lock(mutex_);
      writing_bytes_ = 0;
      space_cv_.notify_all();
    }
    if (failed) return;
  }
}

void BufferedChannel::join_threads() {
  try {
    if (reader_thread_.joinable()) reader_thread_.join();
  } catch (...) {
    // Already reaped by someone else. Nothing may throw out of stop().
  }
  try {
    if (writer_thread_.joinable()) writer_thread_.join();
  } catch (...) {
  }
}

void BufferedChannel::stop(double flush_timeout_s) {
  // Serialized: two Ruby threads disconnecting the same interface at the same
  // time is normal (see the header). Whoever arrives second waits here and
  // then finds the threads already joined.
  std::lock_guard<std::mutex> stop_lock(stop_mutex_);

  if (!started_.load()) {
    stop_.store(true);
    close_fd();
    return;
  }
  if (stop_.load()) {
    // Already stopping/stopped - just make sure the threads are reaped.
    join_threads();
    close_fd();
    release_buffers();
    return;
  }

  if (flush_timeout_s > 0.0 && error_.load() == 0) {
    Waiter waiter;
    Clock::time_point deadline =
        Clock::now() + std::chrono::milliseconds((long long)(flush_timeout_s * 1000.0));
    wait_for_flush(waiter, true, deadline);
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_.store(true);
    notify_all();
  }
  // Unblock any thread parked in a syscall on the fd.
  shutdown_fd();

  join_threads();
  close_fd();
  release_buffers();
}

// Both threads are joined by every caller, so nothing can reference the
// descriptor any more. Released here rather than in the destructor: file
// descriptors are not memory pressure, so waiting for GC to run would let a
// long lived server exhaust them across reconnect cycles.
void BufferedChannel::close_fd() {
  int descriptor = fd_;
  fd_ = -1;
  if (descriptor >= 0) ::close(descriptor);
}

} // namespace cosmos
