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
 * BufferedChannel - abstract base for the buffered C++ I/O backends.
 *
 * A channel adopts an already configured (connected) file descriptor and runs
 * two std::threads that never touch a Ruby API:
 *
 *   reader thread - blocks in read(2)/recv(2) and parks the bytes in a user
 *                   space buffer owned by the subclass.
 *   writer thread - blocks on the outgoing queue condition variable and drains
 *                   it in order.
 *
 * Everything is event driven: the threads park in the kernel or on a condition
 * variable. There are no sleep loops and no timers anywhere in this extension.
 */

#ifndef COSMOS_BUFFERED_CHANNEL_H
#define COSMOS_BUFFERED_CHANNEL_H

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

namespace cosmos {

typedef std::chrono::steady_clock Clock;

// Why a blocking call returned. Mapped to Ruby exceptions (or data) by the
// extension glue in buffered_io.cpp.
enum class ChannelStatus {
  OK = 0,      // data was returned (or the write was queued)
  TIMEOUT,     // the caller supplied deadline expired
  INTERRUPTED, // the Ruby unblock function fired (Thread#kill, signal, ...)
  DISCONNECTED,// disconnect() was called on this channel
  END_OF_FILE, // the peer closed the connection
  CHANNEL_ERROR// the reader or writer latched an errno
};

// Overflow policy for the outgoing queue once it passes the high water mark.
enum class WritePolicy { BLOCK = 0, RAISE };

// Why try_enqueue_write() did or did not take the data. STOPPED is distinct
// from FULL on purpose: a stopped channel will never drain, so the caller must
// report the write as failed (IOError) rather than counting the bytes as
// written or waiting for space that can never appear.
enum class EnqueueResult { ENQUEUED = 0, FULL, STOPPED };

// What the reader thread does when the read ring is full.
//
//   BACKPRESSURE - stop reading the descriptor until Ruby drains the ring.
//                  For TCP this restores exactly the lossless flow control the
//                  pure Ruby stream has today, so it is the stream default.
//   DROP_OLDEST  - freshest data wins (the right answer for UDP and serial,
//                  where the kernel would otherwise drop silently).
//   DROP_NEWEST  - keep the oldest data and discard what does not fit.
//
// Every dropped byte is counted in drop_count.
enum class OverflowPolicy { BACKPRESSURE = 0, DROP_OLDEST, DROP_NEWEST };

// A Waiter lives on the stack of the calling Ruby thread for exactly the
// duration of one blocking call. rb_thread_call_without_gvl hands the same
// pointer to the unblock function, which flags it aborted and broadcasts.
struct Waiter {
  bool aborted;
  Waiter() : aborted(false) {}
};

class BufferedChannel {
public:
  // Bytes allowed to sit in the outgoing queue before a writer blocks (or
  // raises, under WritePolicy::RAISE). Deliberately small: the queue exists to
  // absorb a burst while the GVL is held, not to hide a dead peer. A large
  // mark delays the Timeout::Error the stock Ruby stream would already have
  // raised, so a link that has gone away looks healthy for far too long.
  static const uint64_t DEFAULT_WRITE_HIGH_WATER;

  explicit BufferedChannel(int fd);
  virtual ~BufferedChannel();

  // Spawn the reader and writer threads. Throws std::system_error when a
  // thread cannot be created; the channel is left stopped and joined, so the
  // caller may destroy it (or must, since it can never deliver anything).
  void start();

  // Signal stop, unblock the syscalls with shutdown(2) and join. If
  // flush_timeout_s is > 0 the outgoing queue is given that long to drain
  // before the fd is shut down. Safe to call more than once.
  void stop(double flush_timeout_s);

  // True until stop() is called and while no error/EOF has been latched.
  bool connected() const;

  bool stopped() const { return stop_.load(); }

  int fd() const { return fd_.load(); }

  // Bytes this channel holds beyond the object itself, for Ruby's ObjectSpace
  // memsize. Virtual because the subclasses differ by more than their rings:
  // a SerialChannel is not the same size as a StreamChannel and reporting one
  // for the other quietly understates every serial interface.
  virtual size_t footprint() const = 0;

  // ---- statistics (lock free) ----
  uint64_t bytes_read() const { return bytes_read_.load(); }
  uint64_t bytes_written() const { return bytes_written_.load(); }
  uint64_t drop_count() const { return drop_count_.load(); }
  uint64_t high_water() const { return high_water_.load(); }
  virtual uint64_t buffered_bytes() const = 0;

  uint64_t pending_write_bytes() const;

  // ---- error latch ----
  bool eof() const { return eof_.load(); }
  int latched_errno() const { return error_.load(); }

  // ---- write path ----
  WritePolicy write_policy() const { return write_policy_.load(); }
  void set_write_policy(WritePolicy policy) { write_policy_.store(policy); }
  uint64_t write_high_water() const { return write_high_water_.load(); }
  void set_write_high_water(uint64_t bytes) { write_high_water_.store(bytes); }

  // Queue data for the writer thread. Queues nothing and reports FULL when the
  // queue is already at or above the high water mark, or STOPPED when the
  // channel has been disconnected (the data would never go anywhere).
  EnqueueResult try_enqueue_write(const char* data, size_t length);

  // Block (with the GVL released) until the outgoing queue drops below the
  // high water mark. Never called with a lock held.
  ChannelStatus wait_for_write_space(Waiter& waiter, bool has_deadline,
                                     Clock::time_point deadline);

  // Block (with the GVL released) until the outgoing queue is empty.
  ChannelStatus wait_for_flush(Waiter& waiter, bool has_deadline,
                               Clock::time_point deadline);

  // Called from the Ruby unblock function on another thread.
  void abort_wait(Waiter& waiter);

  // Unblock function for stop(). stop() runs with the GVL released, so without
  // this a Ruby thread parked in the disconnect flush wait could not be reached
  // by Thread#kill at all. Latches an abort flag that wait_for_flush consumes
  // and re-signals the descriptor (shutdown(2) / the self-pipe) so a reader or
  // writer parked in a syscall comes back and can be joined.
  void abort_stop();

protected:
  // Implemented by the subclass. Both run on their own std::thread and must
  // never call a Ruby API.
  virtual void reader_loop() = 0;
  void writer_loop();

  // Transport primitives. Default to read(2)/write(2); TcpChannel overrides.
  virtual ssize_t transport_read(void* buffer, size_t length);
  virtual ssize_t transport_write(const void* buffer, size_t length);

  // Push one queued item all the way out. The default loops over
  // transport_write until the whole item is gone, which is what a byte stream
  // needs. Returns false once errno has been latched.
  virtual bool transport_send_item(const std::string& item);
  // Unblock a thread parked in a syscall on fd_.
  virtual void shutdown_fd();

  void latch_eof();
  void latch_errno(int error);

  // Wakes every thread waiting on this channel.
  virtual void notify_all();

  // Atomic because the destructor writes -1 to it from the stopping thread
  // while the reader and writer threads, park_ready(), shutdown_fd() and the Ruby
  // facing fileno() are all reading it. Every read takes a local copy and
  // checks it for -1 before handing it to a syscall; that does not close the
  // window between the check and the syscall (only joining the threads first
  // does, which stop() guarantees), but it does keep the read itself from
  // being a data race.
  std::atomic<int> fd_;
  std::atomic<bool> stop_;
  // Set by abort_stop(): breaks the disconnect flush wait so a hung stop can be
  // interrupted. One shot - once a stop has been aborted the channel is going
  // away regardless.
  std::atomic<bool> stop_abort_;
  std::atomic<bool> started_;
  std::atomic<bool> eof_;
  std::atomic<int> error_;

  std::atomic<uint64_t> bytes_read_;
  std::atomic<uint64_t> bytes_written_;
  std::atomic<uint64_t> drop_count_;
  std::atomic<uint64_t> high_water_;

  std::atomic<WritePolicy> write_policy_;
  std::atomic<uint64_t> write_high_water_;

  // Guards the read buffer (subclass) and the write queue below. Every wait
  // predicate is evaluated under this mutex.
  mutable std::mutex mutex_;
  std::condition_variable read_cv_;   // reader thread -> Ruby readers
  std::condition_variable write_cv_;  // Ruby writers -> writer thread
  std::condition_variable space_cv_;  // writer thread -> blocked Ruby writers

  std::deque<std::string> write_queue_;
  uint64_t write_queue_bytes_;
  uint64_t writing_bytes_; // bytes handed to the writer thread but not yet sent

  std::thread reader_thread_;
  std::thread writer_thread_;

  // Drop anything still queued once both threads are joined. Called by stop().
  void discard_write_queue();
};

} // namespace cosmos

#endif /* COSMOS_BUFFERED_CHANNEL_H */
