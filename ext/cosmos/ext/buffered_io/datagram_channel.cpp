/*
# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
*/

#include "datagram_channel.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include <vector>

namespace cosmos {

const size_t DatagramChannel::DEFAULT_RING_DATAGRAMS;
const size_t DatagramChannel::DEFAULT_RING_BYTES;
const size_t DatagramChannel::MAX_DATAGRAM_BYTES;
const size_t DatagramChannel::RECV_BUFFER_BYTES;

static double now_seconds() {
  struct timeval tv;
  ::gettimeofday(&tv, NULL);
  return (double)tv.tv_sec + ((double)tv.tv_usec / 1000000.0);
}

DatagramChannel::DatagramChannel(int fd, size_t ring_datagrams, size_t ring_bytes)
    : BufferedChannel(fd),
      max_datagrams_(ring_datagrams > 0 ? ring_datagrams : DEFAULT_RING_DATAGRAMS),
      max_bytes_(ring_bytes > 0 ? ring_bytes : DEFAULT_RING_BYTES),
      buffered_bytes_(0),
      high_water_bytes_(0),
      overflow_policy_(OverflowPolicy::DROP_OLDEST),
      last_receive_time_(0.0),
      last_read_time_(0.0),
      socket_connected_(false),
      destination_length_(0) {
  memset(&destination_, 0, sizeof(destination_));
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

  // A connected socket can use send(2) and, on every platform, shutdown(2).
  struct sockaddr_storage peer;
  socklen_t peer_length = sizeof(peer);
  socket_connected_ = (::getpeername(fd, (struct sockaddr*)&peer, &peer_length) == 0);
}

DatagramChannel::~DatagramChannel() {
  // The threads must be joined before the ring (and the wake pipe) go away.
  stop(0.0);
  if (wake_pipe_[0] >= 0) ::close(wake_pipe_[0]);
  if (wake_pipe_[1] >= 0) ::close(wake_pipe_[1]);
  wake_pipe_[0] = -1;
  wake_pipe_[1] = -1;
}

uint64_t DatagramChannel::buffered_bytes() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return buffered_bytes_;
}

uint64_t DatagramChannel::buffered_datagrams() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return (uint64_t)ring_.size();
}

// stop() calls this once both threads are joined, so nothing can still be
// parked in poll(2) on the wake pipe or holding the ring. Releasing here
// rather than in the destructor matters: a server that reconnects in a loop
// would otherwise carry one dead ring and two dead pipe descriptors per cycle
// until GC happened to run.
void DatagramChannel::release_buffers() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::deque<Datagram>().swap(ring_);
  buffered_bytes_ = 0;
  for (int index = 0; index < 2; ++index) {
    int descriptor = wake_pipe_[index];
    wake_pipe_[index] = -1;
    if (descriptor >= 0) ::close(descriptor);
  }
}

bool DatagramChannel::set_overflow_policy(OverflowPolicy policy) {
  // BACKPRESSURE is refused on purpose. Not reading the socket does not make
  // UDP lossless, it only moves the loss into SO_RCVBUF where it is silent and
  // uncountable - the exact failure this whole extension exists to fix.
  if (policy == OverflowPolicy::BACKPRESSURE) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  overflow_policy_.store(policy);
  return true;
}

void DatagramChannel::set_destination(const struct sockaddr* address, socklen_t length) {
  if (!address || length == 0 || length > (socklen_t)sizeof(destination_)) return;
  memcpy(&destination_, address, (size_t)length);
  destination_length_ = length;
}

// mutex_ must be held. Makes room by policy and appends. drop_count counts
// whole datagrams here (the meaningful unit for a message transport), not
// bytes as it does for StreamChannel.
void DatagramChannel::ring_push(Datagram& datagram) {
  size_t length = datagram.data.size();

  if (overflow_policy_.load() == OverflowPolicy::DROP_NEWEST) {
    bool no_room = (ring_.size() >= max_datagrams_) ||
                   (!ring_.empty() && (buffered_bytes_ + length) > max_bytes_);
    if (no_room) {
      drop_count_.fetch_add(1);
      last_receive_time_.store(datagram.time);
      return;
    }
  } else {
    // DROP_OLDEST: evict until this datagram fits. The ring never refuses the
    // newest data, so telemetry stays fresh.
    while (!ring_.empty() &&
           (ring_.size() >= max_datagrams_ || (buffered_bytes_ + length) > max_bytes_)) {
      buffered_bytes_ -= ring_.front().data.size();
      ring_.pop_front();
      drop_count_.fetch_add(1);
    }
  }

  ring_.push_back(Datagram());
  Datagram& slot = ring_.back();
  slot.data.swap(datagram.data);
  slot.time = datagram.time;
  slot.peer = datagram.peer;
  slot.peer_length = datagram.peer_length;
  buffered_bytes_ += length;

  last_receive_time_.store(slot.time);
  if ((uint64_t)ring_.size() > high_water_.load()) {
    high_water_.store((uint64_t)ring_.size());
  }
  if (buffered_bytes_ > high_water_bytes_.load()) {
    high_water_bytes_.store(buffered_bytes_);
  }
}

// mutex_ must be held and the ring must not be empty.
void DatagramChannel::ring_pop(Datagram& out) {
  Datagram& front = ring_.front();
  out.data.swap(front.data);
  out.time = front.time;
  out.peer = front.peer;
  out.peer_length = front.peer_length;
  buffered_bytes_ -= out.data.size();
  ring_.pop_front();
  last_read_time_.store(out.time);
}

bool DatagramChannel::try_read(Datagram& out) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (ring_.empty()) return false;
  ring_pop(out);
  return true;
}

ChannelStatus DatagramChannel::read(Datagram& out, Waiter& waiter, bool has_deadline,
                                    Clock::time_point deadline, int& err) {
  std::unique_lock<std::mutex> lock(mutex_);
  while (true) {
    if (!ring_.empty()) {
      ring_pop(out);
      return ChannelStatus::OK;
    }
    // Nothing buffered - report why, newest reason first.
    if (waiter.aborted) return ChannelStatus::INTERRUPTED;
    if (stop_.load()) return ChannelStatus::DISCONNECTED;
    if (error_.load() != 0) {
      err = error_.load();
      return ChannelStatus::CHANNEL_ERROR;
    }
    // A datagram socket has no EOF: a peer going away is not observable and
    // must not end the read loop, exactly like UdpReadSocket today.

    if (has_deadline) {
      if (Clock::now() >= deadline) return ChannelStatus::TIMEOUT;
      if (read_cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
        if (!ring_.empty()) continue;
        return ChannelStatus::TIMEOUT;
      }
    } else {
      read_cv_.wait(lock);
    }
  }
}

// Break the reader out of poll(2). shutdown(2) is attempted too because it is
// harmless and helps a connected socket, but the pipe is what is relied on:
// on macOS shutdown(2) on an unconnected UDP socket returns ENOTCONN and the
// reader would stay parked forever.
void DatagramChannel::shutdown_fd() {
  if (wake_pipe_[1] >= 0) {
    const char byte = 'x';
    ssize_t ignored = ::write(wake_pipe_[1], &byte, 1);
    (void)ignored;
  }
  if (socket_connected_) ::shutdown(fd_, SHUT_RDWR);
}

// Parks in the kernel until a datagram arrives or stop() writes the wake byte.
// Returns false when the channel should stop.
bool DatagramChannel::wait_readable() {
  struct pollfd fds[2];
  fds[0].fd = fd_;
  fds[0].events = POLLIN;
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
    if (fds[0].revents & (POLLIN | POLLHUP)) return true;
    if (fds[0].revents & (POLLERR | POLLNVAL)) {
      // Let recvfrom report the real errno.
      return true;
    }
  }
  return false;
}

// Never touches a Ruby API, so the GVL is irrelevant to it. One poll per burst
// then one recvfrom per datagram until the socket runs dry.
void DatagramChannel::reader_loop() {
  std::vector<char> buffer(RECV_BUFFER_BYTES);

  while (!stop_.load()) {
    Datagram datagram;
    datagram.peer_length = sizeof(datagram.peer);
    ssize_t count = transport_recv(&buffer[0], buffer.size(), &datagram.peer,
                                   &datagram.peer_length);
    if (count >= 0) {
      // A zero length UDP datagram is legal and must be delivered as one read.
      // Stamp as close to the kernel handoff as possible.
      datagram.time = now_seconds();
      datagram.data.assign(&buffer[0], (size_t)count);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        ring_push(datagram);
        bytes_read_.fetch_add((uint64_t)count);
        read_cv_.notify_all();
      }
      continue;
    }

    int error = errno;
    if (error == EINTR) continue;
    if (error == EAGAIN || error == EWOULDBLOCK) {
      // Socket is dry - park until it is readable again or stop() fires.
      if (!wait_readable()) return;
      continue;
    }
    // ECONNRESET on a connected UDP socket means an ICMP port unreachable came
    // back for a datagram we sent. It says nothing about our ability to keep
    // receiving, so it must not kill the reader.
    if (error == ECONNRESET || error == ECONNREFUSED || error == EHOSTUNREACH ||
        error == ENETUNREACH || error == EMSGSIZE) {
      continue;
    }
    latch_errno(error);
    return;
  }
}

// One datagram, one sendto. Short writes do not happen for messages, and a
// zero length item is a real (empty) datagram rather than a no-op.
bool DatagramChannel::transport_send_item(const std::string& item) {
  while (true) {
    ssize_t sent = transport_send(item.data(), item.size());
    if (sent >= 0) {
      bytes_written_.fetch_add((uint64_t)sent);
      return true;
    }
    int error = errno;
    if (error == EINTR) continue;
    if (error == ENOBUFS) {
      // The interface queue is momentarily full. The datagram is gone either
      // way; count it and keep the channel alive rather than latching a fatal
      // error on what is a transient condition.
      drop_count_.fetch_add(1);
      return true;
    }
    if (error == ECONNRESET || error == ECONNREFUSED || error == EHOSTUNREACH ||
        error == ENETUNREACH) {
      // ICMP feedback from a previous send. UDP has no delivery guarantee, so
      // this is not a channel error.
      return true;
    }
    latch_errno(error);
    return false;
  }
}

UdpChannel::UdpChannel(int fd, size_t ring_datagrams, size_t ring_bytes)
    : DatagramChannel(fd, ring_datagrams, ring_bytes) {
#ifdef SO_NOSIGPIPE
  int on = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
}

ssize_t UdpChannel::transport_recv(void* buffer, size_t length,
                                   struct sockaddr_storage* from,
                                   socklen_t* from_length) {
  // MSG_DONTWAIT instead of a non blocking fd: the descriptor is a dup of
  // Ruby's, and Ruby is free to make its own copy blocking or not.
  return ::recvfrom(fd_, buffer, length, MSG_DONTWAIT, (struct sockaddr*)from,
                    from_length);
}

ssize_t UdpChannel::transport_send(const void* buffer, size_t length) {
  int flags = 0;
#ifdef MSG_NOSIGNAL
  flags |= MSG_NOSIGNAL;
#endif
  if (destination_length_ > 0) {
    return ::sendto(fd_, buffer, length, flags, (const struct sockaddr*)&destination_,
                    destination_length_);
  }
  return ::send(fd_, buffer, length, flags);
}

} // namespace cosmos
