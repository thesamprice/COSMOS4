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
 * Ruby glue for the buffered C++ I/O backends.
 *
 * Cosmos::BufferedIO::StreamChannel wraps a cosmos::StreamChannel as a
 * TypedData object. Every call that can block does so inside
 * rb_thread_call_without_gvl with an unblock function, so Thread#kill,
 * signals and disconnect interrupt a waiting read exactly like the pure Ruby
 * IO.select based reads they replace (Cosmos.kill_thread semantics).
 *
 * The C++ threads never call a Ruby API.
 */

#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <exception>
#include <set>
#include <stdio.h>

#include "ruby.h"
#include "ruby/thread.h"

#include "stream_channel.h"

using cosmos::BufferedChannel;
using cosmos::ChannelStatus;
using cosmos::Clock;
using cosmos::EnqueueResult;
using cosmos::StreamChannel;
using cosmos::TcpChannel;
using cosmos::Waiter;
using cosmos::WritePolicy;

static VALUE mCosmos = Qnil;
static VALUE mBufferedIO = Qnil;
static VALUE cStreamChannel = Qnil;
static VALUE cOverflowError = Qnil;
static ID id_block = 0;
static ID id_raise = 0;
static ID id_backpressure = 0;
static ID id_drop_oldest = 0;
static ID id_drop_newest = 0;

/* Ring sizing bounds enforced at adopt. The Ruby layer validates first (see
 * BufferedIO::InterfaceOptions#set_option) so a bad OPTION line fails at config
 * load; these are the defense in depth for anything that reaches the extension
 * another way. Below the floor a ring cannot hold one read chunk; above the
 * ceiling a typo (an extra three zeros) would reserve address space no COSMOS
 * deployment wants and fail in a much less obvious place. */
static const size_t MIN_RING_BYTES = 4096;
static const size_t MAX_RING_BYTES = (size_t)1024 * 1024 * 1024; /* 1 GiB */

/* Every live channel so the VM teardown end proc can stop the threads before
 * the process tears down under them. */
static std::set<StreamChannel*>* g_channels = NULL;

static void register_channel(StreamChannel* channel) {
  if (!g_channels) g_channels = new std::set<StreamChannel*>();
  g_channels->insert(channel);
}

static void unregister_channel(StreamChannel* channel) {
  if (g_channels) g_channels->erase(channel);
}

/* ---------------------------------------------------------------- TypedData */

static void channel_free(void* pointer) {
  StreamChannel* channel = (StreamChannel*)pointer;
  if (!channel) return;
  unregister_channel(channel);
  channel->stop(0.0); /* joins the reader and writer threads */
  delete channel;
}

/* Virtual dispatch, not sizeof(StreamChannel): a subclass that is larger than
 * the base, or holds more than the ring, reports its own size rather than
 * having the base size quietly attributed to it in ObjectSpace. */
static size_t channel_memsize(const void* pointer) {
  const StreamChannel* channel = (const StreamChannel*)pointer;
  if (!channel) return 0;
  return channel->footprint();
}

static const rb_data_type_t channel_data_type = {
    "Cosmos::BufferedIO::StreamChannel",
    {NULL, channel_free, channel_memsize, },
    NULL,
    NULL,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

static StreamChannel* get_channel(VALUE self) {
  StreamChannel* channel = NULL;
  TypedData_Get_Struct(self, StreamChannel, &channel_data_type, channel);
  if (!channel) rb_raise(rb_eIOError, "buffered channel is not open");
  return channel;
}

/* --------------------------------------------------------- blocking helpers */

struct ReadCall {
  StreamChannel* channel;
  std::string* out;
  size_t max_bytes;
  bool has_deadline;
  Clock::time_point deadline;
  Waiter waiter;
  ChannelStatus status;
  int err;
  double timestamp;
};

static void* read_without_gvl(void* pointer) {
  ReadCall* call = (ReadCall*)pointer;
  call->status = call->channel->read(*call->out, call->max_bytes, call->waiter,
                                     call->has_deadline, call->deadline, call->err,
                                     &call->timestamp);
  return NULL;
}

/* Called by the Ruby VM on another thread to interrupt the wait. */
static void read_unblock(void* pointer) {
  ReadCall* call = (ReadCall*)pointer;
  call->channel->abort_wait(call->waiter);
}

struct WaitCall {
  StreamChannel* channel;
  bool flush;
  bool has_deadline;
  Clock::time_point deadline;
  Waiter waiter;
  ChannelStatus status;
};

static void* wait_without_gvl(void* pointer) {
  WaitCall* call = (WaitCall*)pointer;
  if (call->flush) {
    call->status = call->channel->wait_for_flush(call->waiter, call->has_deadline,
                                                 call->deadline);
  } else {
    call->status = call->channel->wait_for_write_space(call->waiter, call->has_deadline,
                                                       call->deadline);
  }
  return NULL;
}

static void wait_unblock(void* pointer) {
  WaitCall* call = (WaitCall*)pointer;
  call->channel->abort_wait(call->waiter);
}

static void* stop_without_gvl(void* pointer) {
  StreamChannel* channel = (StreamChannel*)pointer;
  channel->stop(0.0);
  return NULL;
}

/* Unblock function for stop(). Without one, a Ruby thread inside disconnect is
 * unreachable by Thread#kill for as long as the teardown takes - and a teardown
 * waits on a flush and then joins two threads that may themselves be parked in
 * a syscall. abort_stop() breaks the flush wait and re-signals the descriptor,
 * which is what lets the joins complete. */
static void stop_unblock(void* pointer) {
  BufferedChannel* channel = (BufferedChannel*)pointer;
  channel->abort_stop();
}

/* Size checks shared by both adopt entry points. Raise before anything is
 * duplicated or constructed, so there is nothing to clean up. */
static size_t checked_ring_bytes(VALUE value, size_t fallback) {
  if (NIL_P(value)) return fallback;
  long requested = NUM2LONG(value);
  if (requested < (long)MIN_RING_BYTES || requested > (long)MAX_RING_BYTES) {
    rb_raise(rb_eArgError, "buffered ring bytes must be between %lu and %lu (got %ld)",
             (unsigned long)MIN_RING_BYTES, (unsigned long)MAX_RING_BYTES, requested);
  }
  return (size_t)requested;
}

/* Seconds a timeout is allowed to ask for. Anything past this is treated as
 * the maximum rather than passed through: a caller that writes 1e18 (or an
 * accidental Time.now as a timeout) overflows the microsecond conversion into
 * a negative offset, and a deadline in the past makes the very next
 * wait_until report TIMEOUT instantly - the exact opposite of what was asked
 * for, and it looks like a broken link rather than a bad argument. A century
 * is indistinguishable from "forever" for anything this extension serves and
 * leaves the int64 microsecond count three orders of magnitude clear of
 * overflow. */
static const double MAX_TIMEOUT_SECONDS = 100.0 * 365.0 * 24.0 * 60.0 * 60.0;

static bool deadline_from_timeout(VALUE timeout, Clock::time_point* deadline) {
  if (NIL_P(timeout)) return false;
  double seconds = NUM2DBL(timeout);
  /* NaN compares false against everything, so it is caught by the ! form. */
  if (!(seconds > 0.0)) seconds = 0.0;
  if (seconds > MAX_TIMEOUT_SECONDS) seconds = MAX_TIMEOUT_SECONDS;
  *deadline = Clock::now() + std::chrono::microseconds((long long)(seconds * 1000000.0));
  return true;
}

/* Raise the Ruby exception matching a latched channel status. */
static void raise_status(ChannelStatus status, int err) {
  switch (status) {
    case ChannelStatus::DISCONNECTED:
      rb_raise(rb_eIOError, "buffered channel disconnected");
      break;
    case ChannelStatus::END_OF_FILE:
      rb_raise(rb_eEOFError, "end of file reached");
      break;
    case ChannelStatus::CHANNEL_ERROR:
      rb_syserr_fail(err, "buffered channel");
      break;
    default:
      break;
  }
}

/* ------------------------------------------------------------------ methods */

/*
 * Cosmos::BufferedIO::StreamChannel.adopt(fileno, ring_bytes = nil)
 *
 * Duplicates the given descriptor (so Ruby stays free to close its own copy
 * whenever it likes), starts the reader and writer threads and returns the
 * channel.
 */
static VALUE channel_adopt(int argc, VALUE* argv, VALUE klass) {
  VALUE fileno_value = Qnil;
  VALUE ring_value = Qnil;
  rb_scan_args(argc, argv, "11", &fileno_value, &ring_value);

  int fileno = NUM2INT(fileno_value);
  size_t ring_bytes = checked_ring_bytes(ring_value, StreamChannel::DEFAULT_RING_BYTES);

  /* M1 adopts sockets only: shutdown(2) is what guarantees the reader thread
   * can always be unblocked for a clean join. */
  int socket_type = 0;
  socklen_t socket_type_length = sizeof(socket_type);
  if (::getsockopt(fileno, SOL_SOCKET, SO_TYPE, &socket_type, &socket_type_length) != 0) {
    rb_raise(rb_eArgError, "buffered channel requires a socket descriptor");
  }
  /* A StreamChannel is byte stream semantics all the way down: its ring has no
   * message boundaries and its reader would silently splice datagrams
   * together. Only SOCK_STREAM belongs here - a SOCK_DGRAM socket must go to
   * DatagramChannel, and anything else falls back to the stock Ruby path. */
  if (socket_type != SOCK_STREAM) {
    rb_raise(rb_eArgError,
             "buffered stream channel requires a SOCK_STREAM socket "
             "(datagram sockets must use DatagramChannel)");
  }

  int duplicate = ::dup(fileno);
  if (duplicate < 0) rb_syserr_fail(errno, "dup");
#ifdef FD_CLOEXEC
  ::fcntl(duplicate, F_SETFD, FD_CLOEXEC);
#endif

  StreamChannel* channel = NULL;
  /* POD only past this point: everything that can raise happens after the C++
   * scope has closed, because rb_raise longjmps and a destructor that has not
   * run yet never will. */
  char failure[256];
  failure[0] = '\0';
  try {
    /* The socket's O_NONBLOCK flag is Ruby's, shared through the dup, and is
     * deliberately left alone: forcing it blocking would change how Ruby's
     * own read_nonblock/write_nonblock behave on the same socket. Both loops
     * park in poll(2) on EAGAIN instead, which works in either mode. */
    channel = new TcpChannel(duplicate, ring_bytes);
    channel->start();
  } catch (const std::exception& error) {
    snprintf(failure, sizeof(failure), "%s", error.what());
  } catch (...) {
    snprintf(failure, sizeof(failure), "unknown error");
  }
  if (failure[0] != '\0') {
    if (channel) {
      /* Fully constructed: the channel owns the descriptor and its destructor
       * joins whatever started and closes it. */
      delete channel;
    } else {
      /* Construction failed, so the descriptor came back to us (every channel
       * constructor clears fd_ before throwing). */
      ::close(duplicate);
    }
    rb_raise(rb_eRuntimeError, "buffered adopt failed: %s", failure);
  }

  VALUE self = TypedData_Wrap_Struct(klass, &channel_data_type, channel);
  register_channel(channel);
  return self;
}

/*
 * read(timeout = nil, max_bytes = nil) -> String or nil
 * read_with_time(timeout = nil, max_bytes = nil) -> [String, Float] or nil
 *
 * Returns the next chunk of buffered data (binary String), or nil if the
 * timeout expires. read_with_time also returns the time the first byte of the
 * chunk was received by the C++ reader thread (seconds since the epoch), so
 * receive time can travel with the data instead of being sampled later by a
 * GVL starved Ruby thread. Raises EOFError when the peer closed, Errno::* for
 * a latched socket error and IOError once the channel is disconnected.
 */
static VALUE channel_read_common(int argc, VALUE* argv, VALUE self, bool with_time) {
  VALUE timeout = Qnil;
  VALUE max_bytes = Qnil;
  rb_scan_args(argc, argv, "02", &timeout, &max_bytes);

  StreamChannel* channel = get_channel(self);
  size_t limit = StreamChannel::READ_CHUNK_BYTES;
  if (!NIL_P(max_bytes)) {
    long requested = NUM2LONG(max_bytes);
    /* A zero or negative cap can only ever return an empty string, which the
     * caller cannot tell apart from a closed device. */
    if (requested <= 0) rb_raise(rb_eArgError, "max_bytes must be positive");
    limit = (size_t)requested;
  }
  Clock::time_point deadline;
  bool has_deadline = deadline_from_timeout(timeout, &deadline);

  /* Every iteration keeps the std::string that receives the bytes inside an
   * inner scope, and every raise happens in the tail below once that scope has
   * closed. rb_raise / rb_syserr_fail / rb_thread_check_ints all longjmp, and a
   * C++ destructor that has not run by then never runs at all. */
  while (true) {
    VALUE string = Qnil;
    double timestamp = 0.0;
    ChannelStatus status = ChannelStatus::OK;
    int err = 0;
    {
      std::string data;
      ReadCall call;
      call.channel = channel;
      call.out = &data;
      call.max_bytes = limit;
      call.has_deadline = has_deadline;
      call.deadline = deadline;
      call.err = 0;
      call.timestamp = 0.0;
      call.status = ChannelStatus::OK;

      /* Fast path: the ring already has data, so return it without ever
       * releasing the GVL. Releasing it costs a full scheduler round trip - up
       * to a thread quantum when another Ruby thread is spinning - and that
       * latency, not the I/O, is what limits a starved interface thread. */
      if (!channel->try_read(data, limit, &call.timestamp)) {
        call.waiter.aborted = false;
        /* data is empty across this call, so the longjmp an interrupt can do
         * here cannot strand a heap buffer. */
        rb_thread_call_without_gvl(read_without_gvl, &call, read_unblock, &call);
      }
      status = call.status;
      err = call.err;
      timestamp = call.timestamp;
      if (status == ChannelStatus::OK) {
        string = rb_str_new(data.data(), (long)data.size());
      }
    }

    switch (status) {
      case ChannelStatus::OK:
        if (!with_time) return string;
        return rb_ary_new3(2, string, DBL2NUM(timestamp));
      case ChannelStatus::TIMEOUT:
        return Qnil;
      case ChannelStatus::INTERRUPTED:
        /* rb_thread_call_without_gvl already processed any pending interrupt
         * (Thread#kill, signals). Nothing was raised, so wait again. */
        rb_thread_check_ints();
        continue;
      default:
        raise_status(status, err);
        return Qnil; /* not reached */
    }
  }
}

static VALUE channel_read(int argc, VALUE* argv, VALUE self) {
  return channel_read_common(argc, argv, self, false);
}

static VALUE channel_read_with_time(int argc, VALUE* argv, VALUE self) {
  return channel_read_common(argc, argv, self, true);
}

/*
 * write(data, timeout = nil) -> Integer or false
 *
 * Queues data for the writer thread and returns immediately. Past the high
 * water mark the caller either blocks with the GVL released (:block, the
 * default) or raises (:raise). Returns false if timeout seconds elapse while
 * waiting for queue space (the caller maps that to Timeout::Error).
 */
static VALUE channel_write(int argc, VALUE* argv, VALUE self) {
  VALUE data = Qnil;
  VALUE timeout = Qnil;
  rb_scan_args(argc, argv, "11", &data, &timeout);

  StreamChannel* channel = get_channel(self);
  StringValue(data);

  if (channel->stopped()) rb_raise(rb_eIOError, "buffered channel disconnected");
  if (channel->latched_errno() != 0) {
    rb_syserr_fail(channel->latched_errno(), "buffered channel");
  }

  /* No C++ object of our own is alive anywhere in this function. try_enqueue_write
   * copies the bytes into the queue under its own lock while we still hold the
   * GVL - so the String cannot move underneath it - and everything else here is
   * POD, which is what makes the rb_raise calls below safe. */
  WaitCall call;
  call.channel = channel;
  call.flush = false;
  call.has_deadline = deadline_from_timeout(timeout, &call.deadline);
  call.status = ChannelStatus::OK;

  while (true) {
    long length = RSTRING_LEN(data);
    EnqueueResult result = channel->try_enqueue_write(RSTRING_PTR(data), (size_t)length);
    if (result == EnqueueResult::ENQUEUED) return LONG2NUM(length);
    if (result == EnqueueResult::STOPPED) {
      /* Disconnected between the check above and here. The bytes were not
       * queued and never will be, so they must not be counted as written. */
      rb_raise(rb_eIOError, "buffered channel is stopped");
    }
    if (channel->write_policy() == WritePolicy::RAISE) {
      rb_raise(cOverflowError, "buffered channel write queue full (%llu bytes)",
               (unsigned long long)channel->pending_write_bytes());
    }
    call.waiter.aborted = false;
    rb_thread_call_without_gvl(wait_without_gvl, &call, wait_unblock, &call);
    if (call.status == ChannelStatus::INTERRUPTED) {
      rb_thread_check_ints();
      continue;
    }
    if (call.status == ChannelStatus::TIMEOUT) return Qfalse;
    if (call.status != ChannelStatus::OK) {
      raise_status(call.status, channel->latched_errno());
    }
  }
}

/*
 * flush(timeout = nil) -> true or false
 *
 * Waits for the outgoing queue to drain. Returns false on timeout.
 */
static VALUE channel_flush(int argc, VALUE* argv, VALUE self) {
  VALUE timeout = Qnil;
  rb_scan_args(argc, argv, "01", &timeout);

  WaitCall call;
  call.channel = get_channel(self);
  call.flush = true;
  call.has_deadline = deadline_from_timeout(timeout, &call.deadline);
  call.status = ChannelStatus::OK;

  while (true) {
    call.waiter.aborted = false;
    rb_thread_call_without_gvl(wait_without_gvl, &call, wait_unblock, &call);
    switch (call.status) {
      case ChannelStatus::OK:
        return Qtrue;
      case ChannelStatus::TIMEOUT:
        return Qfalse;
      case ChannelStatus::INTERRUPTED:
        rb_thread_check_ints();
        continue;
      default:
        return Qfalse;
    }
  }
}

/*
 * disconnect(flush_timeout = 1.0) -> nil
 *
 * Gives the outgoing queue flush_timeout seconds to drain, then signals stop,
 * shutdown(2)s the descriptor to unblock the syscalls and joins both threads.
 */
static VALUE channel_disconnect(int argc, VALUE* argv, VALUE self) {
  VALUE flush_timeout = Qnil;
  rb_scan_args(argc, argv, "01", &flush_timeout);
  double seconds = NIL_P(flush_timeout) ? 1.0 : NUM2DBL(flush_timeout);

  StreamChannel* channel = get_channel(self);
  /* !stopped(), not connected(): a channel that has latched EOF or an errno is
   * no longer "connected" but its outgoing queue can still be drained. Writing
   * to a half closed TCP socket is legal and is exactly what a graceful
   * disconnect needs - the peer stopped sending, we still owe it the last
   * command. If the write does fail the writer thread latches the error and
   * exits, which is the same outcome as not trying. */
  if (seconds > 0.0 && !channel->stopped() && channel->pending_write_bytes() > 0) {
    WaitCall call;
    call.channel = channel;
    call.flush = true;
    call.has_deadline = true;
    call.deadline = Clock::now() + std::chrono::microseconds((long long)(seconds * 1000000.0));
    call.status = ChannelStatus::OK;
    call.waiter.aborted = false;
    rb_thread_call_without_gvl(wait_without_gvl, &call, wait_unblock, &call);
  }
  rb_thread_call_without_gvl(stop_without_gvl, channel, stop_unblock, channel);
  return Qnil;
}

static VALUE channel_connected(VALUE self) {
  return get_channel(self)->connected() ? Qtrue : Qfalse;
}

static VALUE channel_bytes_read(VALUE self) {
  return ULL2NUM(get_channel(self)->bytes_read());
}

static VALUE channel_bytes_written(VALUE self) {
  return ULL2NUM(get_channel(self)->bytes_written());
}

static VALUE channel_drop_count(VALUE self) {
  return ULL2NUM(get_channel(self)->drop_count());
}

static VALUE channel_buffered_bytes(VALUE self) {
  return ULL2NUM(get_channel(self)->buffered_bytes());
}

static VALUE channel_high_water(VALUE self) {
  return ULL2NUM(get_channel(self)->high_water());
}

static VALUE channel_pending_write_bytes(VALUE self) {
  return ULL2NUM(get_channel(self)->pending_write_bytes());
}

static VALUE channel_ring_bytes(VALUE self) {
  return ULL2NUM((unsigned long long)get_channel(self)->ring_bytes());
}

static VALUE channel_fileno(VALUE self) {
  return INT2NUM(get_channel(self)->fd());
}

/* True once disconnect() has been called on this channel. */
static VALUE channel_stopped(VALUE self) {
  return get_channel(self)->stopped() ? Qtrue : Qfalse;
}

static VALUE channel_eof(VALUE self) {
  return get_channel(self)->eof() ? Qtrue : Qfalse;
}

/* Receive time (epoch seconds) of the chunk returned by the last read. */
static VALUE channel_last_read_time(VALUE self) {
  double time = get_channel(self)->last_chunk_time();
  return time > 0.0 ? DBL2NUM(time) : Qnil;
}

/* Receive time (epoch seconds) of the most recent data off the wire. */
static VALUE channel_last_receive_time(VALUE self) {
  double time = get_channel(self)->last_receive_time();
  return time > 0.0 ? DBL2NUM(time) : Qnil;
}

static VALUE channel_write_policy(VALUE self) {
  return ID2SYM(get_channel(self)->write_policy() == WritePolicy::RAISE ? id_raise : id_block);
}

static VALUE channel_set_write_policy(VALUE self, VALUE policy) {
  StreamChannel* channel = get_channel(self);
  ID policy_id = SYM2ID(rb_to_symbol(policy));
  if (policy_id == id_block) {
    channel->set_write_policy(WritePolicy::BLOCK);
  } else if (policy_id == id_raise) {
    channel->set_write_policy(WritePolicy::RAISE);
  } else {
    rb_raise(rb_eArgError, "write policy must be :block or :raise");
  }
  return policy;
}

static VALUE channel_overflow_policy(VALUE self) {
  switch (get_channel(self)->overflow_policy()) {
    case cosmos::OverflowPolicy::DROP_OLDEST:
      return ID2SYM(id_drop_oldest);
    case cosmos::OverflowPolicy::DROP_NEWEST:
      return ID2SYM(id_drop_newest);
    default:
      return ID2SYM(id_backpressure);
  }
}

static VALUE channel_set_overflow_policy(VALUE self, VALUE policy) {
  StreamChannel* channel = get_channel(self);
  ID policy_id = SYM2ID(rb_to_symbol(policy));
  if (policy_id == id_backpressure) {
    channel->set_overflow_policy(cosmos::OverflowPolicy::BACKPRESSURE);
  } else if (policy_id == id_drop_oldest) {
    channel->set_overflow_policy(cosmos::OverflowPolicy::DROP_OLDEST);
  } else if (policy_id == id_drop_newest) {
    channel->set_overflow_policy(cosmos::OverflowPolicy::DROP_NEWEST);
  } else {
    rb_raise(rb_eArgError,
             "overflow policy must be :backpressure, :drop_oldest or :drop_newest");
  }
  return policy;
}

static VALUE channel_write_high_water(VALUE self) {
  return ULL2NUM(get_channel(self)->write_high_water());
}

static VALUE channel_set_write_high_water(VALUE self, VALUE bytes) {
  long value = NUM2LONG(bytes);
  if (value <= 0) rb_raise(rb_eArgError, "write high water must be positive");
  get_channel(self)->set_write_high_water((uint64_t)value);
  return bytes;
}

/* Stop every live channel before the VM tears down under the C++ threads. */
static void buffered_io_end_proc(VALUE ignored) {
  (void)ignored;
  if (!g_channels) return;
  for (std::set<StreamChannel*>::iterator it = g_channels->begin();
       it != g_channels->end(); ++it) {
    (*it)->stop(0.0);
  }
}

extern "C" void Init_buffered_io(void) {
  mCosmos = rb_define_module("Cosmos");
  mBufferedIO = rb_define_module_under(mCosmos, "BufferedIO");
  cStreamChannel = rb_define_class_under(mBufferedIO, "StreamChannel", rb_cObject);
  cOverflowError = rb_define_class_under(mBufferedIO, "OverflowError", rb_eRuntimeError);

  id_block = rb_intern("block");
  id_raise = rb_intern("raise");
  id_backpressure = rb_intern("backpressure");
  id_drop_oldest = rb_intern("drop_oldest");
  id_drop_newest = rb_intern("drop_newest");

  rb_undef_alloc_func(cStreamChannel);
  rb_define_singleton_method(cStreamChannel, "adopt", RUBY_METHOD_FUNC(channel_adopt), -1);
  rb_define_method(cStreamChannel, "read", RUBY_METHOD_FUNC(channel_read), -1);
  rb_define_method(cStreamChannel, "read_with_time", RUBY_METHOD_FUNC(channel_read_with_time), -1);
  rb_define_method(cStreamChannel, "last_read_time", RUBY_METHOD_FUNC(channel_last_read_time), 0);
  rb_define_method(cStreamChannel, "last_receive_time",
                   RUBY_METHOD_FUNC(channel_last_receive_time), 0);
  rb_define_method(cStreamChannel, "write", RUBY_METHOD_FUNC(channel_write), -1);
  rb_define_method(cStreamChannel, "flush", RUBY_METHOD_FUNC(channel_flush), -1);
  rb_define_method(cStreamChannel, "disconnect", RUBY_METHOD_FUNC(channel_disconnect), -1);
  rb_define_method(cStreamChannel, "connected?", RUBY_METHOD_FUNC(channel_connected), 0);
  rb_define_method(cStreamChannel, "eof?", RUBY_METHOD_FUNC(channel_eof), 0);
  rb_define_method(cStreamChannel, "stopped?", RUBY_METHOD_FUNC(channel_stopped), 0);
  rb_define_method(cStreamChannel, "bytes_read", RUBY_METHOD_FUNC(channel_bytes_read), 0);
  rb_define_method(cStreamChannel, "bytes_written", RUBY_METHOD_FUNC(channel_bytes_written), 0);
  rb_define_method(cStreamChannel, "drop_count", RUBY_METHOD_FUNC(channel_drop_count), 0);
  rb_define_method(cStreamChannel, "buffered_bytes", RUBY_METHOD_FUNC(channel_buffered_bytes), 0);
  rb_define_method(cStreamChannel, "high_water", RUBY_METHOD_FUNC(channel_high_water), 0);
  rb_define_method(cStreamChannel, "pending_write_bytes",
                   RUBY_METHOD_FUNC(channel_pending_write_bytes), 0);
  rb_define_method(cStreamChannel, "ring_bytes", RUBY_METHOD_FUNC(channel_ring_bytes), 0);
  rb_define_method(cStreamChannel, "fileno", RUBY_METHOD_FUNC(channel_fileno), 0);
  rb_define_method(cStreamChannel, "write_policy", RUBY_METHOD_FUNC(channel_write_policy), 0);
  rb_define_method(cStreamChannel, "write_policy=", RUBY_METHOD_FUNC(channel_set_write_policy), 1);
  rb_define_method(cStreamChannel, "overflow_policy",
                   RUBY_METHOD_FUNC(channel_overflow_policy), 0);
  rb_define_method(cStreamChannel, "overflow_policy=",
                   RUBY_METHOD_FUNC(channel_set_overflow_policy), 1);
  rb_define_method(cStreamChannel, "write_high_water",
                   RUBY_METHOD_FUNC(channel_write_high_water), 0);
  rb_define_method(cStreamChannel, "write_high_water=",
                   RUBY_METHOD_FUNC(channel_set_write_high_water), 1);

  rb_define_const(mBufferedIO, "EXTENSION_LOADED", Qtrue);
  /* The ring bounds are NOT exported: Cosmos::BufferedIO defines them in Ruby
   * so a configuration file is validated identically on a machine where this
   * extension was never built. The values here must match those; the spec
   * proves it by feeding the Ruby bounds to adopt. */
  rb_define_const(mBufferedIO, "DEFAULT_WRITE_HIGH_WATER",
                  ULL2NUM((unsigned long long)BufferedChannel::DEFAULT_WRITE_HIGH_WATER));
  rb_define_const(cStreamChannel, "DEFAULT_RING_BYTES",
                  ULL2NUM((unsigned long long)StreamChannel::DEFAULT_RING_BYTES));

  rb_set_end_proc(buffered_io_end_proc, Qnil);
}
