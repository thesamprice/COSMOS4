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
  # Everything else (return values, exceptions, timeouts) matches
  # {SerialStream}, so protocols and interfaces see no difference. If the
  # descriptor cannot be adopted - a mocked driver, Win32SerialDriver, JRuby,
  # an unbuilt extension - the stock pure Ruby implementation is used unchanged.
  module BufferedSerialTransport
    # Bytes of user space ring buffer for the read port
    DEFAULT_RING_BYTES = 16 * 1024 * 1024
    # Ring for a port that is only ever written. Nothing reads this ring, so it
    # only exists to keep the descriptor drained.
    WRITE_ONLY_RING_BYTES = 65536
    # Seconds to let queued writes drain during disconnect
    DEFAULT_FLUSH_TIMEOUT = 1.0

    # @return [Cosmos::BufferedIO::StreamChannel|nil] Channel draining the read port
    attr_reader :read_channel
    # @return [Cosmos::BufferedIO::StreamChannel|nil] Channel filling the write port
    attr_reader :write_channel

    # Configure the buffered layer and adopt the descriptors. Called from the
    # including class's constructor, because a {SerialStream} is connected the
    # moment it is created.
    #
    # @param options [Hash] :ring_bytes, :read_chunk_bytes, :write_high_water,
    #   :write_policy (:block or :raise), :overflow_policy (:backpressure,
    #   :drop_oldest or :drop_newest), :flush_timeout
    def setup_buffered_options(options = {})
      options ||= {}
      @ring_bytes = (options[:ring_bytes] || DEFAULT_RING_BYTES).to_i
      # Bytes returned by one read. A read only ever returns what is actually
      # buffered, so a large cap costs nothing when the port is keeping up and
      # lets a starved interface thread drain the whole backlog in a single GVL
      # acquisition instead of one 64 KiB slice per scheduler round trip.
      @read_chunk_bytes = (options[:read_chunk_bytes] || @ring_bytes).to_i
      @write_high_water = options[:write_high_water]
      @write_policy = options[:write_policy] || :block
      # See doc/buffered_io_design.md: serial defaults to back pressure, not to
      # a drop policy. Dropping bytes out of the middle of a byte stream
      # desynchronizes framing, and back pressure is what keeps RTS/CTS flow
      # control working. Drops remain available per interface.
      @overflow_policy = options[:overflow_policy] || :backpressure
      @flush_timeout = options[:flush_timeout] || DEFAULT_FLUSH_TIMEOUT
      @read_channel = nil
      @write_channel = nil
      @last_read_time_f = nil
      adopt_buffered_channels()
    end

    # @return [Boolean] Whether this stream is actually running through the
    #   buffered C++ backend
    def buffered?
      !!(@read_channel or @write_channel)
    end

    # @return [Time|nil] Time the first byte of the last chunk returned by
    #   {#read} arrived from the tty. Stamped by the C++ reader thread without
    #   the GVL, so it is not skewed by Ruby scheduling.
    def last_read_time
      @last_read_time_f ? Time.at(@last_read_time_f).sys : nil
    end

    # @return [Float|nil] {#last_read_time} as seconds since the epoch
    def last_read_time_f
      @last_read_time_f
    end

    # @return [Hash] Buffered channel statistics for the CmdTlmServer counters.
    #   :stall_count is the serial specific one: under :backpressure nothing is
    #   ever dropped by us, so a rising stall count is the early warning that
    #   Ruby is not draining and the tty input buffer is next in line.
    def buffered_stats
      stats = BufferedIO.empty_stats
      return stats unless @read_channel or @write_channel
      stats[:buffered] = true
      if @read_channel
        stats[:bytes_read] = @read_channel.bytes_read
        stats[:drop_count] = @read_channel.drop_count
        stats[:buffered_bytes] = @read_channel.buffered_bytes
        stats[:high_water] = @read_channel.high_water
        stats[:stall_count] = @read_channel.stall_count
        stats[:ring_bytes] = @read_channel.ring_bytes
      end
      if @write_channel
        stats[:bytes_written] = @write_channel.bytes_written
        stats[:pending_write_bytes] = @write_channel.pending_write_bytes
      end
      stats
    end

    # (see SerialStream#read)
    def read
      raise "Attempt to read from write only stream" unless @read_serial_port
      return super() unless @read_channel

      begin
        result = @read_channel.read_with_time(@read_timeout, @read_chunk_bytes)
        # PosixSerialDriver#read raises Timeout::Error when the read times out
        raise Timeout::Error, "Read Timeout" if result.nil?
        data, @last_read_time_f = result
        data
      rescue EOFError
        # The other end of the port went away. read_nonblock raises this too.
        raise
      rescue IOError
        # The channel was disconnected underneath us (another thread called
        # disconnect). An empty read is how {StreamInterface#read_interface}
        # is told to shut the interface down, which is what the stock stream
        # ends up doing when its port is closed mid read.
        ''
      end
    end

    # (see SerialStream#read_nonblock)
    def read_nonblock
      raise "Attempt to read from write only stream" unless @read_serial_port
      return super() unless @read_channel

      begin
        result = @read_channel.read_with_time(0, @read_chunk_bytes)
        # PosixSerialDriver#read_nonblock returns '' when nothing is waiting
        return '' if result.nil?
        data, @last_read_time_f = result
        data
      rescue EOFError
        raise
      rescue IOError
        ''
      end
    end

    # (see SerialStream#write)
    def write(data)
      raise "Attempt to write to read only stream" unless @write_serial_port
      return super(data) unless @write_channel

      # The C++ writer thread owns the syscall - this only queues, in order.
      # The mutex is kept so commands from more than one tool interleave
      # exactly as they do today.
      @write_mutex.synchronize do
        result = @write_channel.write(data, @write_timeout)
        # PosixSerialDriver#write raises Timeout::Error the same way
        raise Timeout::Error, "Write Timeout" if result == false
      end
      nil
    end

    # Wait for all queued writes to reach the kernel
    #
    # @param timeout [Float|nil] Seconds to wait, nil to wait forever
    # @return [Boolean] Whether everything was written
    def flush(timeout = nil)
      return true unless @write_channel
      @write_channel.flush(timeout)
    end

    # @return [Boolean] Whether the stream is connected
    def connected?
      return false unless super()
      return true unless @read_channel or @write_channel
      channels.each { |channel| return false if channel.stopped? }
      true
    end

    # Stop the channels then let the stock implementation close the ports
    def disconnect
      release_channels(@flush_timeout)
      super()
    end

    protected

    # @return [Array<Cosmos::BufferedIO::StreamChannel>] Unique live channels
    def channels
      [@read_channel, @write_channel].compact.uniq { |channel| channel.object_id }
    end

    # Hand the configured descriptors to the C++ channels. Any failure at all
    # falls back to the stock Ruby driver - a buffering problem must never be
    # able to break a port that plain Ruby can serve.
    def adopt_buffered_channels
      return unless BufferedIO.available?
      return if @read_channel or @write_channel

      begin
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
        channels.each do |channel|
          channel.write_policy = @write_policy if @write_policy
          channel.write_high_water = @write_high_water if @write_high_water
        end
      rescue Exception => error
        # Never let the buffered path break a port Ruby can serve
        BufferedIO.log_fallback(self.class.name)
        Logger.warn("#{self.class.name}: #{error.class}: #{error.message}") if defined?(Logger)
        release_channels(0)
      end
    end

    # @param flush_timeout [Float] Seconds to let queued writes drain
    def release_channels(flush_timeout)
      channels.each do |channel|
        begin
          channel.disconnect(flush_timeout)
        rescue Exception
          # Nothing useful to do if the channel is already gone
        end
      end
      @read_channel = nil
      @write_channel = nil
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
