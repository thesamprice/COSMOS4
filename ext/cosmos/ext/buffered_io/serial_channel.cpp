/*
# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
*/

#include "serial_channel.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include <vector>

namespace cosmos {

static double now_seconds() {
  struct timeval tv;
  ::gettimeofday(&tv, NULL);
  return (double)tv.tv_sec + ((double)tv.tv_usec / 1000000.0);
}

SerialChannel::SerialChannel(int fd, size_t ring_bytes) : StreamChannel(fd, ring_bytes) {
  wake_pipe_[0] = -1;
  wake_pipe_[1] = -1;
  if (::pipe(wake_pipe_) == 0) {
    for (int index = 0; index < 2; ++index) {
#ifdef FD_CLOEXEC
      ::fcntl(wake_pipe_[index], F_SETFD, FD_CLOEXEC);
#endif
      int flags = ::fcntl(wake_pipe_[index], F_GETFL, 0);
      if (flags >= 0) ::fcntl(wake_pipe_[index], F_SETFL, flags | O_NONBLOCK);
    }
  }
}

SerialChannel::~SerialChannel() {
  // The threads must be joined before the ring (and the wake pipe) go away.
  // Called here rather than left to ~StreamChannel because the virtual
  // dispatch to our shutdown_fd()/release_buffers() has to still be live.
  stop(0.0);
  for (int index = 0; index < 2; ++index) {
    int descriptor = wake_pipe_[index];
    wake_pipe_[index] = -1;
    if (descriptor >= 0) ::close(descriptor);
  }
}

// stop() calls this once both threads are joined, so nothing can still be
// parked in poll(2) on the wake pipe. Releasing the descriptors here rather
// than in the destructor matters: an interface that reconnects in a loop would
// otherwise carry two dead pipe descriptors per cycle until GC happened to run.
void SerialChannel::release_buffers() {
  StreamChannel::release_buffers();
  std::lock_guard<std::mutex> lock(mutex_);
  for (int index = 0; index < 2; ++index) {
    int descriptor = wake_pipe_[index];
    wake_pipe_[index] = -1;
    if (descriptor >= 0) ::close(descriptor);
  }
}

// shutdown(2) is a socket call: on a tty it just fails with ENOTSOCK. And
// closing the descriptor to break a parked read would be a use after free
// race - the fd number is reusable the instant it is closed. The self-pipe is
// the only safe wakeup for a character device.
void SerialChannel::shutdown_fd() {
  if (wake_pipe_[1] >= 0) {
    const char byte = 'x';
    ssize_t ignored = ::write(wake_pipe_[1], &byte, 1);
    (void)ignored;
  }
}

// Parks in the kernel until the tty reports one of the requested events or
// stop() writes the wake byte. Returns false when the channel should stop.
bool SerialChannel::wait_ready(short events) {
  struct pollfd fds[2];
  fds[0].fd = fd_;
  fds[0].events = events;
  fds[0].revents = 0;
  fds[1].fd = wake_pipe_[0];
  fds[1].events = POLLIN;
  fds[1].revents = 0;
  nfds_t count = (wake_pipe_[0] >= 0) ? 2 : 1;

  while (!stop_.load()) {
    // -1: block indefinitely. The kernel parks the thread; this is not a poll
    // loop in the spin/timer sense the design rules out.
    int ready = ::poll(fds, count, -1);
    if (ready < 0) {
      if (errno == EINTR || errno == EAGAIN) continue;
      latch_errno(errno);
      return false;
    }
    if (count == 2 && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) return false;
    // POLLHUP on a tty is the peer (the pty master, or a USB adapter being
    // unplugged) going away. Let read(2) report it so EOF and errno are
    // decided in exactly one place.
    if (fds[0].revents & (events | POLLHUP | POLLERR | POLLNVAL)) return true;
  }
  return false;
}

// Never touches a Ruby API, so the GVL is irrelevant to it. One poll(2) per
// read: the descriptor is non blocking, so read(2) after POLLIN returns
// whatever the tty input buffer holds and never parks where stop() could not
// reach it.
void SerialChannel::reader_loop() {
  std::vector<unsigned char> buffer(READ_CHUNK_BYTES);

  while (!stop_.load()) {
    size_t request = reserve_read_space(buffer.size());
    if (request == 0) return;

    ssize_t count = transport_read(&buffer[0], request);
    if (count > 0) {
      // Timestamp as close to the kernel handoff as possible.
      double timestamp = now_seconds();
      std::lock_guard<std::mutex> lock(mutex_);
      ring_push(&buffer[0], (size_t)count, timestamp);
      bytes_read_.fetch_add((uint64_t)count);
      read_cv_.notify_all();
      continue;
    }

    if (count == 0) {
      // A tty read returns 0 when the other side of a pty closed. Real UARTs
      // do not do this, but the pty based tests and any USB adapter that
      // disappears do.
      latch_eof();
      return;
    }

    int error = errno;
    if (error == EINTR) continue;
    if (error == EAGAIN || error == EWOULDBLOCK) {
      // Nothing buffered - park until the tty is readable or stop() fires.
      if (!wait_ready(POLLIN)) return;
      continue;
    }
    if (error == EIO) {
      // Hangup on a tty (Linux reports the pty master closing this way, and so
      // does a serial adapter being unplugged). It is the end of the stream,
      // not a transport fault, and the stock driver surfaces it as an
      // exception that disconnects the interface just like EOF does.
      latch_eof();
      return;
    }
    latch_errno(error);
    return;
  }
}

// Byte stream write, same contract as the base class: keep going until the
// whole item has been handed to the kernel. The difference is EAGAIN - the
// descriptor is non blocking (see the header), so a full tty output buffer is
// a wait for POLLOUT, not an error.
bool SerialChannel::transport_send_item(const std::string& item) {
  size_t offset = 0;
  while (offset < item.size()) {
    ssize_t sent = transport_write(item.data() + offset, item.size() - offset);
    if (sent > 0) {
      offset += (size_t)sent;
      bytes_written_.fetch_add((uint64_t)sent);
      continue;
    }
    if (sent == 0) break; // nothing written and no error: give up on this item
    int error = errno;
    if (error == EINTR) continue;
    if (error == EAGAIN || error == EWOULDBLOCK) {
      if (!wait_ready(POLLOUT)) return false; // stopping
      continue;
    }
    latch_errno(error);
    return false;
  }
  return true;
}

} // namespace cosmos
