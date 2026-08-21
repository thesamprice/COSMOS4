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
 * SerialChannel - byte stream semantics on a termios configured tty.
 *
 * Serial is a byte stream, so everything about the buffering is inherited from
 * StreamChannel: the same byte ring, the same overflow policies, the same
 * Ruby facing read(). Only two things differ, and both come from the tty being
 * a character device rather than a socket:
 *
 * 1. Teardown cannot use shutdown(2). shutdown(2) is a socket call - on a tty
 *    it fails with ENOTSOCK and leaves the reader parked in read(2) forever.
 *    Closing the descriptor out from under a parked thread is not a fix
 *    either: it is a use after free race (the fd number is immediately
 *    reusable, so the parked read can start reading somebody else's file).
 *    The reader therefore parks in poll(2) on the tty *and* a self-pipe, and
 *    stop() writes one byte to the pipe. This is exactly the mechanism M2
 *    introduced for unconnected UDP sockets, for exactly the same reason.
 *
 * 2. The descriptor is shared with Ruby (it is a dup(2) of the fd
 *    PosixSerialDriver opened and configured), so both directions are driven
 *    non blocking and every wait happens in poll(2). A blocking read(2) or
 *    write(2) on a tty can only be interrupted by a signal, and neither the
 *    reader nor the writer thread may be allowed to wedge: stop() has to be
 *    able to join them.
 *
 * Ruby still owns all of the termios configuration (PosixSerialDriver);
 * this class only adopts the configured descriptor and runs the hot loop.
 */

#ifndef COSMOS_SERIAL_CHANNEL_H
#define COSMOS_SERIAL_CHANNEL_H

#include "stream_channel.h"

namespace cosmos {

class SerialChannel : public StreamChannel {
public:
  SerialChannel(int fd, size_t ring_bytes);
  virtual ~SerialChannel();

  virtual bool is_tty() const { return true; }

  // (see BufferedChannel#footprint) sizeof(*this), not sizeof(StreamChannel):
  // a SerialChannel carries the wake pipe as well.
  virtual size_t footprint() const { return sizeof(*this) + ring_bytes(); }

protected:
  virtual void reader_loop();
  // Byte loop like the base class, but a tty write can report EAGAIN: the
  // writer waits for POLLOUT instead of latching a fatal error.
  virtual bool transport_send_item(const std::string& item);
  // Writes the wake byte. shutdown(2) is not attempted at all - it cannot
  // succeed on a character device.
  virtual void shutdown_fd();
  // Closes the wake pipe once both threads are joined.
  virtual void release_buffers();

  // Parks in the kernel until the tty is ready for events (POLLIN or POLLOUT)
  // or stop() writes the wake byte. Returns false when the channel should
  // stop. No timeout, no timer, no sleep loop.
  bool wait_ready(short events);

  // Self-pipe used to break the reader (or a blocked writer) out of poll(2).
  int wake_pipe_[2];
};

} // namespace cosmos

#endif /* COSMOS_SERIAL_CHANNEL_H */
