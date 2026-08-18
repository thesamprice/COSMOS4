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

#include <set>

#include "ruby.h"
#include "ruby/thread.h"

#include "stream_channel.h"

using cosmos::ChannelStatus;
using cosmos::Clock;
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

static size_t channel_memsize(const void* pointer) {
  const StreamChannel* channel = (const StreamChannel*)pointer;
  if (!channel) return 0;
  return sizeof(StreamChannel) + channel->ring_bytes();
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

static bool deadline_from_timeout(VALUE timeout, Clock::time_point* deadline) {
  if (NIL_P(timeout)) return false;
  double seconds = NUM2DBL(timeout);
  if (seconds < 0.0) seconds = 0.0;
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
  size_t ring_bytes = StreamChannel::DEFAULT_RING_BYTES;
  if (!NIL_P(ring_value)) {
    long requested = NUM2LONG(ring_value);
    if (requested > 0) ring_bytes = (size_t)requested;
  }

  /* M1 adopts sockets only: shutdown(2) is what guarantees the reader thread
   * can always be unblocked for a clean join. */
  int socket_type = 0;
  socklen_t socket_type_length = sizeof(socket_type);
  if (::getsockopt(fileno, SOL_SOCKET, SO_TYPE, &socket_type, &socket_type_length) != 0) {
    rb_raise(rb_eArgError, "buffered channel requires a socket descriptor");
  }

  int duplicate = ::dup(fileno);
  if (duplicate < 0) rb_syserr_fail(errno, "dup");
#ifdef FD_CLOEXEC
  ::fcntl(duplicate, F_SETFD, FD_CLOEXEC);
#endif
  /* The Ruby socket may be non blocking; our threads want to park in the
   * kernel instead. */
  int flags = ::fcntl(duplicate, F_GETFL, 0);
  if (flags >= 0) ::fcntl(duplicate, F_SETFL, flags & ~O_NONBLOCK);

  StreamChannel* channel = new TcpChannel(duplicate, ring_bytes);
  VALUE self = TypedData_Wrap_Struct(klass, &channel_data_type, channel);
  register_channel(channel);
  channel->start();
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

  std::string data;
  ReadCall call;
  call.channel = get_channel(self);
  call.out = &data;
  call.max_bytes = NIL_P(max_bytes) ? StreamChannel::READ_CHUNK_BYTES
                                    : (size_t)NUM2LONG(max_bytes);
  call.has_deadline = deadline_from_timeout(timeout, &call.deadline);
  call.err = 0;
  call.timestamp = 0.0;
  call.status = ChannelStatus::OK;

  /* Fast path: the ring already has data, so return it without ever releasing
   * the GVL. Releasing it costs a full scheduler round trip - up to a thread
   * quantum when another Ruby thread is spinning - and that latency, not the
   * I/O, is what limits a starved interface thread. */
  if (call.channel->try_read(data, call.max_bytes, &call.timestamp)) {
    VALUE string = rb_str_new(data.data(), (long)data.size());
    if (!with_time) return string;
    return rb_ary_new3(2, string, DBL2NUM(call.timestamp));
  }

  while (true) {
    call.waiter.aborted = false;
    rb_thread_call_without_gvl(read_without_gvl, &call, read_unblock, &call);
    switch (call.status) {
      case ChannelStatus::OK: {
        VALUE string = rb_str_new(data.data(), (long)data.size());
        if (!with_time) return string;
        return rb_ary_new3(2, string, DBL2NUM(call.timestamp));
      }
      case ChannelStatus::TIMEOUT:
        return Qnil;
      case ChannelStatus::INTERRUPTED:
        /* rb_thread_call_without_gvl already processed any pending interrupt
         * (Thread#kill, signals). Nothing was raised, so wait again. */
        rb_thread_check_ints();
        continue;
      default:
        raise_status(call.status, call.err);
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
  /* Copy under the GVL: the String may move once we release it. */
  std::string payload(RSTRING_PTR(data), (size_t)RSTRING_LEN(data));

  if (channel->stopped()) rb_raise(rb_eIOError, "buffered channel disconnected");
  if (channel->latched_errno() != 0) {
    rb_syserr_fail(channel->latched_errno(), "buffered channel");
  }

  WaitCall call;
  call.channel = channel;
  call.flush = false;
  call.has_deadline = deadline_from_timeout(timeout, &call.deadline);
  call.status = ChannelStatus::OK;

  while (!channel->try_enqueue_write(payload.data(), payload.size())) {
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
  return LONG2NUM((long)payload.size());
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
  if (seconds > 0.0 && channel->connected() && channel->pending_write_bytes() > 0) {
    WaitCall call;
    call.channel = channel;
    call.flush = true;
    call.has_deadline = true;
    call.deadline = Clock::now() + std::chrono::microseconds((long long)(seconds * 1000000.0));
    call.status = ChannelStatus::OK;
    call.waiter.aborted = false;
    rb_thread_call_without_gvl(wait_without_gvl, &call, wait_unblock, &call);
  }
  rb_thread_call_without_gvl(stop_without_gvl, channel, NULL, NULL);
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
  rb_define_const(cStreamChannel, "DEFAULT_RING_BYTES",
                  ULL2NUM((unsigned long long)StreamChannel::DEFAULT_RING_BYTES));

  rb_set_end_proc(buffered_io_end_proc, Qnil);
}
