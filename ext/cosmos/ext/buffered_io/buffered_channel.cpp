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

#include <new>
#include <system_error>

namespace cosmos {

// 2 MiB. See the header for why this is small. The trade-off is documented for
// operators in doc/buffered_io_configuration.md under BUFFERED_WRITE_HIGH_WATER:
// lower means a dead peer surfaces as Timeout::Error about as early as the
// stock Ruby stream surfaced it, higher means more burst absorbed while the GVL
// is held elsewhere.
const uint64_t BufferedChannel::DEFAULT_WRITE_HIGH_WATER = 2 * 1024 * 1024;

BufferedChannel::BufferedChannel(int fd)
    : fd_(fd),
      stop_(false),
      stop_abort_(false),
      started_(false),
      eof_(false),
      error_(0),
      bytes_read_(0),
      bytes_written_(0),
      drop_count_(0),
      high_water_(0),
      write_policy_(WritePolicy::BLOCK),
      write_high_water_(DEFAULT_WRITE_HIGH_WATER),
      write_queue_bytes_(0),
      writing_bytes_(0) {}

BufferedChannel::~BufferedChannel() {
  stop(0.0); // joins the threads and closes the descriptor
}

// Each thread body is wrapped: a C++ exception escaping a std::thread is
// std::terminate, which takes the whole VM down. Nothing in the loops is
// supposed to throw, but an allocation in the ring or the write queue can, so
// the failure is latched as ENOMEM (the channel then reports Errno::ENOMEM to
// Ruby exactly like any other transport error) and the loop exits cleanly.
void BufferedChannel::start() {
  if (started_.exchange(true)) return;
  try {
    reader_thread_ = std::thread([this]() {
      try {
        this->reader_loop();
      } catch (const std::bad_alloc&) {
        this->latch_errno(ENOMEM);
      } catch (...) {
        this->latch_errno(EIO);
      }
    });
  } catch (const std::system_error&) {
    // No reader at all. Leave the channel stopped so nothing waits on it.
    std::lock_guard<std::mutex> lock(mutex_);
    stop_.store(true);
    notify_all();
    throw;
  }
  try {
    writer_thread_ = std::thread([this]() {
      try {
        this->writer_loop();
      } catch (const std::bad_alloc&) {
        this->latch_errno(ENOMEM);
      } catch (...) {
        this->latch_errno(EIO);
      }
    });
  } catch (const std::system_error&) {
    // The reader is already running: stop it and reap it before rethrowing, so
    // the caller is handed a channel it can simply destroy.
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stop_.store(true);
      notify_all();
    }
    shutdown_fd();
    try {
      if (reader_thread_.joinable()) reader_thread_.join();
    } catch (...) {
    }
    throw;
  }
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

void BufferedChannel::abort_stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_abort_.store(true);
    stop_.store(true);
    notify_all();
  }
  // Re-signal the descriptor outside the lock: this is what reaches a reader
  // or writer thread parked in a syscall (shutdown(2) for a socket, the
  // self-pipe for a tty or an unconnected UDP socket).
  shutdown_fd();
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
  int descriptor = fd_.load();
  if (descriptor < 0) {
    errno = EBADF;
    return -1;
  }
  return ::read(descriptor, buffer, length);
}

ssize_t BufferedChannel::transport_write(const void* buffer, size_t length) {
  int descriptor = fd_.load();
  if (descriptor < 0) {
    errno = EBADF;
    return -1;
  }
  return ::write(descriptor, buffer, length);
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
      // write(2) returned 0 with bytes still to send. That is not a short
      // write we can retry - nothing is draining - and silently returning true
      // would report the tail as written. Latch it like any other transport
      // fault so the interface disconnects instead of losing data quietly.
      latch_errno(EIO);
      return false;
    }
  }
  return true;
}

void BufferedChannel::shutdown_fd() {
  // Best effort: shutdown() unblocks sockets, close() below handles the rest.
  int descriptor = fd_.load();
  if (descriptor >= 0) ::shutdown(descriptor, SHUT_RDWR);
}

EnqueueResult BufferedChannel::try_enqueue_write(const char* data, size_t length) {
  std::lock_guard<std::mutex> lock(mutex_);
  // Checked first: a stopped channel has no writer thread left to drain the
  // queue, so queueing would report bytes as written that can never leave.
  if (stop_.load()) return EnqueueResult::STOPPED;
  uint64_t pending = write_queue_bytes_ + writing_bytes_;
  // Always allow a single write through so a chunk larger than the high water
  // mark can never deadlock.
  if (pending != 0 && pending >= write_high_water_.load()) return EnqueueResult::FULL;
  write_queue_.push_back(std::string(data, length));
  write_queue_bytes_ += length;
  write_cv_.notify_all();
  return EnqueueResult::ENQUEUED;
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
    // A stop that is being interrupted (Thread#kill against a disconnect) must
    // not keep waiting for a drain that may never finish. DISCONNECTED rather
    // than INTERRUPTED on purpose: INTERRUPTED means "check for a pending Ruby
    // interrupt and wait again", and this flag is latched, so a later flush()
    // on the same channel would spin on it forever.
    if (stop_abort_.load()) return ChannelStatus::DISCONNECTED;
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

void BufferedChannel::stop(double flush_timeout_s) {
  if (!started_.load()) {
    stop_.store(true);
    close_fd();
    return;
  }
  if (stop_.load()) {
    // Already stopping/stopped - just make sure the threads are reaped.
    if (reader_thread_.joinable()) reader_thread_.join();
    if (writer_thread_.joinable()) writer_thread_.join();
    close_fd();
    discard_write_queue();
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

  if (reader_thread_.joinable()) reader_thread_.join();
  if (writer_thread_.joinable()) writer_thread_.join();
  close_fd();
  discard_write_queue();
  release_buffers();
}

// Both threads are joined by every caller, so nothing will ever send these
// bytes. Dropping them here is what makes pending_write_bytes read 0 on a
// stopped channel instead of reporting a backlog that is going nowhere - and
// it hands the memory back at disconnect rather than at GC.
void BufferedChannel::discard_write_queue() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::deque<std::string>().swap(write_queue_);
  write_queue_bytes_ = 0;
  writing_bytes_ = 0;
  space_cv_.notify_all();
}

// Both threads are joined by every caller, so nothing can reference the
// descriptor any more. Released here rather than in the destructor: file
// descriptors are not memory pressure, so waiting for GC to run would let a
// long lived server exhaust them across reconnect cycles.
void BufferedChannel::close_fd() {
  // exchange, not read-then-write: only one thread may close the descriptor.
  // A double close would land on whatever file the number was recycled for.
  int descriptor = fd_.exchange(-1);
  if (descriptor >= 0) ::close(descriptor);
}

} // namespace cosmos
