# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'thread' # For Mutex
require 'timeout' # For Timeout::Error
require 'cosmos/io/buffered_io'
require 'cosmos/streams/serial_stream'

module Cosmos

  # Buffered read/write path for serial ports. Included into a {SerialStream}
  # subclass it replaces only the transport: Ruby still opens the port and does
  # every bit of the termios configuration through {PosixSerialDriver}, while a
  # C++ {Cosmos::BufferedIO::StreamChannel} adopts the *configured* descriptor
  # and drains it from a thread that never takes the GVL.
  #
  # Why this matters more here than for TCP: a tty input buffer is tiny
  # (typically 16 KiB, and only 4 KiB of it usable on some drivers). While any
  # other Ruby thread holds the GVL the interface thread is not scheduled, the
  # UART keeps shifting bytes in, and the driver throws away whatever no longer
  # fits - silently, uncounted, mid frame. A 16 MiB user space ring filled by a
  # C++ thread moves that cliff from milliseconds of starvation to minutes of
  # it.
  #
  # Everything the two byte stream transports do the same way - options,
  # statistics, read, write, flush, disconnect - lives in
  # {Cosmos::BufferedIO::Transport}. What is left here is what is specific to a
  # tty: finding the descriptor behind a {SerialDriver}, adopting it as soon as
  # the port is open (a {SerialStream} is connected the moment it is created),
  # the write mutex, and the drop policy for a port nothing reads.
  #
  # Everything else (return values, exceptions, timeouts) matches
  # {SerialStream}, so protocols and interfaces see no difference. If the
  # descriptor cannot be adopted - a mocked driver, Win32SerialDriver, JRuby,
  # an unbuilt extension - the stock pure Ruby implementation is used unchanged.
  module BufferedSerialTransport
    include BufferedIO::Transport

    # (see BufferedIO::Transport#setup_buffered_options)
    #
    # Also adopts the descriptors, because a {SerialStream} is connected the
    # moment it is created - there is no later connect to adopt from.
    def setup_buffered_options(options = {})
      super(options)
      adopt_buffered_channels()
    end

    # (see BufferedIO::Transport#read)
    #
    # Serial and TCP genuinely disagree about what a disconnect under a parked
    # read looks like, and this is where the serial answer is restored.
    #
    # {TcpipSocketStream} rescues a dead socket and answers '', which is how
    # {StreamInterface#read_interface} is told to shut the interface down.
    # Stock {SerialStream} does nothing of the kind. It calls straight through
    # to {PosixSerialDriver#read}, which parks in IO.fast_select; closing the
    # port under it makes select(2) fail with EBADF, fast_select maps every
    # SystemCallError to nil, and PosixSerialDriver turns that nil into
    # Timeout::Error. Measured, not assumed - the specs run this same scenario
    # through the stock SerialStream and assert both answer alike.
    #
    # Timeout::Error is therefore what a caller has always seen here and what
    # it keeps seeing. read_interface already rescues it and answers nil, so
    # the interface still shuts down exactly as it did before.
    def read
      super()
    rescue IOError
      # The only IOError the buffered path raises is "channel disconnected",
      # which is precisely the case above. A descriptor that failed for a real
      # reason latches its errno and arrives as the matching Errno::*, which
      # stock propagates too and this must not swallow.
      raise Timeout::Error, "Read Timeout"
    end

    protected

    # (see BufferedIO::Transport#buffered_readable?)
    def buffered_readable?
      !!@read_serial_port
    end

    # (see BufferedIO::Transport#buffered_writable?)
    def buffered_writable?
      !!@write_serial_port
    end

    # (see BufferedIO::Transport#buffered_read_errors)
    #
    # Nothing: stock {SerialStream#read_nonblock} calls
    # {PosixSerialDriver#read_nonblock}, which rescues only EAGAIN/EWOULDBLOCK
    # and lets everything else - IOError included - straight out. Stated
    # explicitly rather than left to the base default so a later change to that
    # default cannot quietly alter the serial contract. #read above handles the
    # one error serial reports differently.
    def buffered_read_errors
      []
    end

    # Same cap as a blocking read, which is the 64 KiB default (or whatever
    # BUFFERED_READ_CHUNK set) - the identical figure the socket transport uses
    # and close enough to PosixSerialDriver#read_nonblock's own 65535 that
    # framing is unchanged either way.
    def buffered_nonblock_read_bytes
      @read_chunk_bytes
    end

    # The write mutex is kept so commands from more than one tool interleave
    # exactly as they do today.
    def buffered_write_lock(&block)
      @write_mutex.synchronize(&block)
    end

    # Adopt the configured descriptors. Called inside the
    # fallback-on-any-failure wrapper in
    # {BufferedIO::Transport#adopt_buffered_channels}.
    def adopt_channels
      read_handle = serial_handle(@read_serial_port)
      write_handle = serial_handle(@write_serial_port)
      if read_handle
        @read_channel = BufferedIO::StreamChannel.adopt(read_handle.fileno, @ring_bytes)
        @read_channel.overflow_policy = @overflow_policy if @overflow_policy
      end
      if write_handle
        if read_handle and @write_serial_port.equal?(@read_serial_port) and @read_channel
          # One port opened once: one channel, one reader, one writer.
          @write_channel = @read_channel
        else
          @write_channel = BufferedIO::StreamChannel.adopt(write_handle.fileno,
                                                           WRITE_ONLY_RING_BYTES)
          # Nothing ever reads this ring, so back pressure would eventually
          # wedge the reader against a full ring and leave bytes piling up in
          # the tty. Drop them instead - they were never going anywhere.
          @write_channel.overflow_policy = :drop_oldest
        end
      end
    end

    # @return [IO|nil] The open tty behind a {SerialDriver}, or nil when there
    #   is not one to adopt.
    #
    # Deliberately uses is_a? and instance_variable_get rather than duck
    # typing. The serial specs hand {SerialStream} plain RSpec doubles, and
    # probing a double with an unexpected message fails the caller's test
    # instead of quietly falling back. Only a real PosixSerialDriver holding a
    # real open tty is adopted - Win32SerialDriver, JRuby's nil driver, and
    # every test double keep the stock path.
    def serial_handle(port)
      return nil unless port.is_a?(SerialDriver)
      return nil unless defined?(PosixSerialDriver)
      driver = port.instance_variable_get(:@driver)
      return nil unless driver.is_a?(PosixSerialDriver)
      handle = driver.instance_variable_get(:@handle)
      return nil unless handle.is_a?(::IO)
      return nil if handle.closed?
      handle
    rescue Exception
      nil
    end
  end

  # {SerialStream} which reads and writes through the buffered C++ backend.
  # Drop in replacement for {SerialStream}: same constructor, same behavior,
  # and it silently degrades to the stock implementation wherever the C++
  # channel cannot take over.
  class BufferedSerialStream < SerialStream
    include BufferedSerialTransport

    # @param write_port_name (see SerialStream#initialize)
    # @param read_port_name (see SerialStream#initialize)
    # @param baud_rate (see SerialStream#initialize)
    # @param parity (see SerialStream#initialize)
    # @param stop_bits (see SerialStream#initialize)
    # @param write_timeout (see SerialStream#initialize)
    # @param read_timeout (see SerialStream#initialize)
    # @param flow_control (see SerialStream#initialize)
    # @param data_bits (see SerialStream#initialize)
    # @param struct (see SerialStream#initialize)
    # @param options [Hash] Buffered channel options (see
    #   BufferedSerialTransport#setup_buffered_options)
    def initialize(write_port_name,
                   read_port_name,
                   baud_rate,
                   parity,
                   stop_bits,
                   write_timeout,
                   read_timeout,
                   flow_control = :NONE,
                   data_bits = 8,
                   struct = [],
                   options = {})
      super(write_port_name, read_port_name, baud_rate, parity, stop_bits,
            write_timeout, read_timeout, flow_control, data_bits, struct)
      setup_buffered_options(options)
    end
  end

end # module Cosmos
