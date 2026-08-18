# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'socket'
require 'thread' # For Mutex
require 'timeout' # For Timeout::Error
require 'cosmos/io/buffered_io'
require 'cosmos/streams/tcpip_socket_stream'

module Cosmos

  # Buffered read/write path shared by {BufferedTcpipSocketStream} and
  # {BufferedTcpipClientStream}. Included into a {TcpipSocketStream} subclass it
  # replaces only the transport: Ruby still creates, connects and closes the
  # sockets, while a C++ {Cosmos::BufferedIO::StreamChannel} adopts the
  # connected descriptor and does the reading and writing from threads that
  # never take the GVL.
  #
  # Everything else (return values, exceptions, timeouts) matches
  # {TcpipSocketStream} so protocols and interfaces see no difference. If a
  # channel cannot be created the stock Ruby implementation is used.
  module BufferedSocketStream
    # Bytes of user space ring buffer per read channel
    DEFAULT_RING_BYTES = 16 * 1024 * 1024
    # Ring for a channel that only ever writes
    WRITE_ONLY_RING_BYTES = 65536
    # Seconds to let queued writes drain during disconnect
    DEFAULT_FLUSH_TIMEOUT = 1.0

    # @return [Cosmos::BufferedIO::StreamChannel|nil] Channel draining the read socket
    attr_reader :read_channel
    # @return [Cosmos::BufferedIO::StreamChannel|nil] Channel filling the write socket
    attr_reader :write_channel

    # Configure the buffered layer. Called from the including class's
    # constructor.
    #
    # @param options [Hash] :ring_bytes, :write_high_water, :write_policy
    #   (:block or :raise), :overflow_policy (:backpressure, :drop_oldest or
    #   :drop_newest), :flush_timeout
    def setup_buffered_options(options = {})
      options ||= {}
      @ring_bytes = (options[:ring_bytes] || DEFAULT_RING_BYTES).to_i
      # Bytes returned by one read. A read only ever returns what is actually
      # buffered, so a large cap costs nothing when the stream is keeping up
      # and lets a starved interface thread drain the whole backlog in a single
      # GVL acquisition instead of one 64 KiB slice per scheduler round trip.
      @read_chunk_bytes = (options[:read_chunk_bytes] || @ring_bytes).to_i
      @write_high_water = options[:write_high_water]
      @write_policy = options[:write_policy] || :block
      # Streams default to back pressure: TCP is lossless today and must stay
      # lossless. Drop policies are for the transports the kernel already drops
      # (UDP, serial).
      @overflow_policy = options[:overflow_policy] || :backpressure
      @flush_timeout = options[:flush_timeout] || DEFAULT_FLUSH_TIMEOUT
      @read_channel = nil
      @write_channel = nil
      @last_read_time_f = nil
    end

    # @return [Time|nil] Time the first byte of the last chunk returned by
    #   {#read} was received by the C++ reader thread. This is a kernel handoff
    #   time taken without the GVL, so it is not skewed by Ruby scheduling.
    def last_read_time
      @last_read_time_f ? Time.at(@last_read_time_f).sys : nil
    end

    # @return [Float|nil] {#last_read_time} as seconds since the epoch
    def last_read_time_f
      @last_read_time_f
    end

    # @return [Hash] Buffered channel statistics for the CmdTlmServer counters
    def buffered_stats
      stats = {
        :buffered => false,
        :bytes_read => 0,
        :bytes_written => 0,
        :drop_count => 0,
        :buffered_bytes => 0,
        :high_water => 0,
        :pending_write_bytes => 0
      }
      return stats unless @read_channel or @write_channel
      stats[:buffered] = true
      if @read_channel
        stats[:bytes_read] = @read_channel.bytes_read
        stats[:drop_count] = @read_channel.drop_count
        stats[:buffered_bytes] = @read_channel.buffered_bytes
        stats[:high_water] = @read_channel.high_water
      end
      if @write_channel
        stats[:bytes_written] = @write_channel.bytes_written
        stats[:pending_write_bytes] = @write_channel.pending_write_bytes
      end
      stats
    end

    # Connect the sockets (super) and then adopt their descriptors
    def connect
      super()
      adopt_buffered_channels
      @connected
    end

    # (see TcpipSocketStream#read)
    def read
      raise "Attempt to read from write only stream" unless @read_socket
      return super() unless @read_channel

      begin
        result = @read_channel.read_with_time(@read_timeout, @read_chunk_bytes)
        raise Timeout::Error, "Read Timeout" if result.nil?
        data, @last_read_time_f = result
        data
      rescue EOFError
        # The peer closed cleanly. TcpipSocketStream raises this too.
        raise
      rescue IOError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::ENOTSOCK,
             Errno::EBADF, Errno::ENOTCONN, Errno::EPIPE
        # The socket went away underneath us. TcpipSocketStream returns an
        # empty string here and lets the interface handle the disconnect.
        ''
      end
    end

    # (see TcpipSocketStream#read_nonblock)
    def read_nonblock
      return super() unless @read_channel

      begin
        result = @read_channel.read_with_time(0)
        return '' if result.nil?
        data, @last_read_time_f = result
        data
      rescue EOFError
        # The peer closed cleanly. TcpipSocketStream raises this too.
        raise
      rescue IOError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::ENOTSOCK,
             Errno::EBADF, Errno::ENOTCONN, Errno::EPIPE
        ''
      end
    end

    # (see TcpipSocketStream#write)
    def write(data)
      raise "Attempt to write to read only stream" unless @write_socket
      return super(data) unless @write_channel

      # The C++ writer thread owns the syscall - this only queues, in order.
      result = @write_channel.write(data, @write_timeout)
      raise Timeout::Error, "Write Timeout" if result == false
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

    # Stop the channels then let the stock implementation close the sockets
    def disconnect
      channels.each do |channel|
        begin
          channel.disconnect(@flush_timeout)
        rescue Exception
          # Nothing useful to do if the channel is already gone
        end
      end
      @read_channel = nil
      @write_channel = nil
      super()
    end

    protected

    # @return [Array<Cosmos::BufferedIO::StreamChannel>] Unique live channels
    def channels
      [@read_channel, @write_channel].compact.uniq { |channel| channel.object_id }
    end

    # Hand the connected descriptors to the C++ channels. Any failure falls
    # back to the stock Ruby implementation.
    def adopt_buffered_channels
      return unless BufferedIO.available?
      return if @read_channel or @write_channel

      begin
        if @read_socket and adoptable?(@read_socket)
          @read_channel = BufferedIO::StreamChannel.adopt(@read_socket.fileno, @ring_bytes)
        end
        if @write_socket and adoptable?(@write_socket)
          if @read_socket and @write_socket.equal?(@read_socket) and @read_channel
            @write_channel = @read_channel
          else
            # A write only socket never delivers telemetry, so it does not need
            # a telemetry sized ring.
            @write_channel = BufferedIO::StreamChannel.adopt(@write_socket.fileno,
                                                             WRITE_ONLY_RING_BYTES)
          end
        end
        channels.each do |channel|
          channel.write_policy = @write_policy if @write_policy
          channel.write_high_water = @write_high_water if @write_high_water
          channel.overflow_policy = @overflow_policy if @overflow_policy
        end
      rescue Exception => error
        # Never let the buffered path break a connection that Ruby can serve
        BufferedIO.log_fallback(self.class.name)
        Logger.warn("#{self.class.name}: #{error.class}: #{error.message}") if defined?(Logger)
        release_channels
      end
    end

    def release_channels
      channels.each do |channel|
        begin
          channel.disconnect(0)
        rescue Exception
        end
      end
      @read_channel = nil
      @write_channel = nil
    end

    # Only a real, connected socket is adopted. Anything else (a test double,
    # a socket whose connect never completed) keeps the stock Ruby path.
    def adoptable?(socket)
      return false unless socket.respond_to?(:fileno) and socket.respond_to?(:closed?)
      return false if socket.closed?
      return false unless socket.respond_to?(:remote_address)
      begin
        socket.remote_address
      rescue Exception
        return false
      end
      true
    rescue Exception
      false
    end
  end

  # Data {Stream} which reads and writes Tcpip sockets through the buffered
  # C++ backend. Drop in replacement for {TcpipSocketStream}.
  class BufferedTcpipSocketStream < TcpipSocketStream
    include BufferedSocketStream

    # @param write_socket (see TcpipSocketStream#initialize)
    # @param read_socket (see TcpipSocketStream#initialize)
    # @param write_timeout (see TcpipSocketStream#initialize)
    # @param read_timeout (see TcpipSocketStream#initialize)
    # @param options [Hash] Buffered channel options (see
    #   BufferedSocketStream#setup_buffered_options)
    def initialize(write_socket, read_socket, write_timeout, read_timeout, options = {})
      super(write_socket, read_socket, write_timeout, read_timeout)
      setup_buffered_options(options)
    end
  end

end # module Cosmos
