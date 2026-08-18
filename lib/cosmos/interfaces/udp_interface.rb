# encoding: ascii-8bit

# Copyright 2017 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'timeout' # For Timeout::Error
require 'cosmos/interfaces/interface'
require 'cosmos/io/buffered_io'
require 'cosmos/io/udp_sockets'
require 'cosmos/config/config_parser'

module Cosmos
  # Base class for interfaces that send and receive messages over UDP
  #
  # UDP is the transport the GVL hurts most: while any other Ruby thread holds
  # it this interface's thread is not scheduled, the kernel receive buffer
  # (SO_RCVBUF) overflows and datagrams are dropped **silently**. By default
  # this interface therefore hands its socket descriptors to a
  # {Cosmos::BufferedIO::DatagramChannel}, whose C++ reader thread never touches
  # a Ruby API and drains the socket the moment a datagram lands. Message
  # boundaries, counters, timeouts and exceptions are all unchanged: one read
  # still returns exactly one datagram.
  #
  # If the ring itself ever overflows the loss is *counted* in drop_count
  # instead of being invisible, and the newest telemetry is what survives
  # (drop-oldest). Buffering is skipped - silently, logged once - when the
  # extension is not built, when COSMOS_NO_BUFFERED_IO is set, when the
  # interface is configured with OPTION BUFFERED FALSE, or when the socket is
  # anything other than a real bound UDP socket.
  class UdpInterface < Interface
    # Datagrams held in the C++ ring before it starts dropping
    DEFAULT_RING_DATAGRAMS = 65536
    # Total bytes held in the C++ ring before it starts dropping. 65536
    # maximum sized datagrams would be 4 GiB, so a byte cap runs alongside the
    # datagram cap and whichever is reached first starts dropping.
    DEFAULT_RING_BYTES = 64 * 1024 * 1024
    # Seconds to let queued writes drain during disconnect
    DEFAULT_FLUSH_TIMEOUT = 1.0

    # @return [Cosmos::BufferedIO::DatagramChannel|nil] Channel draining the read socket
    attr_reader :read_channel
    # @return [Cosmos::BufferedIO::DatagramChannel|nil] Channel filling the write socket
    attr_reader :write_channel
    # @param hostname [String] Machine to connect to
    # @param write_dest_port [Integer] Port to write commands to
    # @param read_port [Integer] Port to read telemetry from
    # @param write_src_port [Integer] Port to allow replies if needed
    # @param interface_address [String] If the destination machine represented
    #   by hostname supports multicast, then interface_address is used to
    #   configure the outgoing multicast address.
    # @param ttl [Integer] Time To Live value. The number of intermediate
    #   routers allowed before dropping the packet.
    # @param write_timeout [Integer] Seconds to wait before aborting writes
    # @param read_timeout [Integer] Seconds to wait before aborting reads
    # @param bind_address [String] Address to bind UDP ports to
    def initialize(
      hostname,
      write_dest_port,
      read_port,
      write_src_port = nil,
      interface_address = nil,
      ttl = 128, # default for Windows
      write_timeout = 10.0,
      read_timeout = nil,
      bind_address = '0.0.0.0')

      super()
      @hostname = ConfigParser.handle_nil(hostname)
      if @hostname
        @hostname = @hostname.to_s
        @hostname = '127.0.0.1' if @hostname.casecmp('LOCALHOST').zero?
      end
      @write_dest_port = ConfigParser.handle_nil(write_dest_port)
      @write_dest_port = write_dest_port.to_i if @write_dest_port
      @read_port = ConfigParser.handle_nil(read_port)
      @read_port = read_port.to_i if @read_port
      @write_src_port = ConfigParser.handle_nil(write_src_port)
      @write_src_port = @write_src_port.to_i if @write_src_port
      @interface_address = ConfigParser.handle_nil(interface_address)
      if @interface_address && @interface_address.casecmp('LOCALHOST').zero?
        @interface_address = '127.0.0.1'
      end
      @ttl = ttl.to_i
      @ttl = 1 if @ttl < 1
      @write_timeout = ConfigParser.handle_nil(write_timeout)
      @write_timeout = @write_timeout.to_f if @write_timeout
      @read_timeout = ConfigParser.handle_nil(read_timeout)
      @read_timeout = @read_timeout.to_f if @read_timeout
      @bind_address = ConfigParser.handle_nil(bind_address)
      if @bind_address && @bind_address.casecmp('LOCALHOST').zero?
        @bind_address = '127.0.0.1'
      end
      @write_socket = nil
      @read_socket = nil
      @read_allowed = false unless @read_port
      @write_allowed = false unless @write_dest_port
      @write_raw_allowed = false unless @write_dest_port
      # nil means "use the buffered backend if it is available" (the default).
      # OPTION BUFFERED FALSE or COSMOS_NO_BUFFERED_IO force the stock sockets.
      @buffered = nil
      @ring_datagrams = DEFAULT_RING_DATAGRAMS
      @ring_bytes = DEFAULT_RING_BYTES
      @overflow_policy = :drop_oldest
      @flush_timeout = DEFAULT_FLUSH_TIMEOUT
      @read_channel = nil
      @write_channel = nil
      @last_read_time_f = nil
    end

    # @return [Boolean] Whether this interface reads and writes through the
    #   buffered C++ backend
    def buffered?
      return false if @buffered == false
      BufferedIO.available?
    end

    # Adds the BUFFERED option which disables the buffered C++ backend for this
    # interface, plus BUFFERED_RING_DATAGRAMS / BUFFERED_RING_BYTES which size
    # the read ring (whichever limit is reached first starts dropping) and
    # BUFFERED_OVERFLOW which selects drop_oldest (default) or drop_newest.
    #
    # @param option_name (see Interface#set_option)
    # @param option_values (see Interface#set_option)
    def set_option(option_name, option_values)
      super(option_name, option_values)
      case option_name.to_s.upcase
      when 'BUFFERED'
        @buffered = ConfigParser.handle_true_false(option_values[0].to_s)
      when 'BUFFERED_RING_DATAGRAMS'
        @ring_datagrams = Integer(option_values[0])
      when 'BUFFERED_RING_BYTES'
        @ring_bytes = Integer(option_values[0])
      when 'BUFFERED_OVERFLOW'
        @overflow_policy = option_values[0].to_s.downcase.to_sym
      end
    end

    # @return [Time|nil] Time the datagram returned by the last
    #   {#read_interface} was taken off the socket by the C++ reader thread.
    #   This is a kernel handoff time sampled without the GVL, so unlike
    #   Time.now in a starved Ruby thread it is not skewed by scheduling.
    def last_read_time
      @last_read_time_f ? Time.at(@last_read_time_f).sys : nil
    end

    # @return [Float|nil] {#last_read_time} as seconds since the epoch
    def last_read_time_f
      @last_read_time_f
    end

    # @return [Hash] Buffered channel statistics. Unlike the kernel's silent
    #   SO_RCVBUF overflow, everything lost here is counted.
    def buffered_stats
      # The common shape (see BufferedIO.empty_stats) plus the datagram
      # specific counter. :stall_count stays zero: a datagram channel refuses
      # :backpressure on purpose, so it never stalls - :drop_count is the
      # counter that matters here, and unlike the kernel's it is visible.
      stats = BufferedIO.empty_stats
      stats[:buffered_datagrams] = 0
      return stats unless @read_channel or @write_channel
      stats[:buffered] = true
      if @read_channel
        stats[:bytes_read] = @read_channel.bytes_read
        stats[:drop_count] = @read_channel.drop_count
        stats[:buffered_datagrams] = @read_channel.buffered_datagrams
        stats[:buffered_bytes] = @read_channel.buffered_bytes
        stats[:high_water] = @read_channel.high_water
        stats[:ring_bytes] = @read_channel.ring_bytes
      end
      if @write_channel
        stats[:bytes_written] = @write_channel.bytes_written
        stats[:pending_write_bytes] = @write_channel.pending_write_bytes
      end
      stats
    end

    # Creates a new {UdpWriteSocket} if the the write_dest_port was given in
    # the constructor and a new {UdpReadSocket} if the read_port was given in
    # the constructor.
    def connect
      if @read_port and @write_dest_port and @write_src_port and (@read_port == @write_src_port)
        @read_socket = UdpReadWriteSocket.new(
          @read_port,
          @bind_address,
          @write_dest_port,
          @hostname,
          @interface_address,
          @ttl)
        @write_socket = @read_socket
      else
        @read_socket = UdpReadSocket.new(
          @read_port,
          @hostname,
          @interface_address,
          @bind_address) if @read_port
        @write_socket = UdpWriteSocket.new(
          @hostname,
          @write_dest_port,
          @write_src_port,
          @interface_address,
          @ttl,
          @bind_address) if @write_dest_port
      end
      @thread_sleeper = nil
      adopt_buffered_channels()
    end

    # @return [Boolean] Whether the active ports (read and/or write) have
    #   created sockets. Since UDP is connectionless, creation of the sockets
    #   is used to determine connection.
    def connected?
      if @write_dest_port && @read_port
        (@write_socket && @read_socket) ? true : false
      elsif @write_dest_port
        @write_socket ? true : false
      else
        @read_socket ? true : false
      end
    end

    # Close the active ports (read and/or write) and set the sockets to nil.
    def disconnect
      # Stop the C++ threads first: they own dup'ed descriptors, and stopping
      # them is what unblocks a read parked in the interface thread.
      release_channels(@flush_timeout)
      if @write_socket != @read_socket
        Cosmos.close_socket(@write_socket)
      end
      Cosmos.close_socket(@read_socket)
      @write_socket = nil
      @read_socket = nil
      @thread_sleeper.cancel if @thread_sleeper
      @thread_sleeper = nil
    end

    def read
      return super() if @read_port
      # Write only interface so stop the thread which calls read
      @thread_sleeper = Sleeper.new
      @thread_sleeper.sleep(1_000_000_000) while connected?
      return nil
    end

    # Reads one datagram from the socket if the read_port is defined. Exactly
    # one datagram per call, buffered or not.
    def read_interface
      if @read_channel
        result = @read_channel.read_with_time(@read_timeout)
        # UdpReadSocket#read raises on timeout, so the buffered path must too
        raise Timeout::Error, "Read Timeout" if result.nil?
        data, @last_read_time_f = result
      else
        data = @read_socket.read(@read_timeout)
        @last_read_time_f = nil
      end
      read_interface_base(data)
      # The C++ reader stamped this datagram when the kernel handed it over.
      # That is a truer receive time than Time.now in a thread that may have
      # been waiting on the GVL, so prefer it when we have it.
      @read_raw_data_time = Time.at(@last_read_time_f).sys if @last_read_time_f
      return data
    rescue IOError # Disconnected
      return nil
    end

    # Writes one datagram to the socket
    # @param data [String] Raw packet data
    def write_interface(data)
      write_interface_base(data)
      if @write_channel
        # The C++ writer thread owns the syscall - this only queues, in order.
        result = @write_channel.write(data, @write_timeout)
        raise Timeout::Error, "Write Timeout" if result == false
      else
        @write_socket.write(data, @write_timeout)
      end
      data
    end

    protected

    # @return [Array<Cosmos::BufferedIO::DatagramChannel>] Unique live channels
    def channels
      [@read_channel, @write_channel].compact.uniq { |channel| channel.object_id }
    end

    # Hand the socket descriptors to the C++ channels. Any failure at all falls
    # back to the stock Ruby sockets - a buffering problem must never be able
    # to break an interface that plain Ruby can serve.
    def adopt_buffered_channels
      return unless buffered?
      return if @read_channel or @write_channel

      begin
        if adoptable_socket?(@read_socket)
          @read_channel = BufferedIO::DatagramChannel.adopt(
            raw_socket(@read_socket).fileno, @ring_datagrams, @ring_bytes)
          @read_channel.overflow_policy = @overflow_policy if @overflow_policy
        end
        if adoptable_socket?(@write_socket)
          if @write_socket.equal?(@read_socket) and @read_channel
            @write_channel = @read_channel
          else
            # A write only socket never delivers telemetry, so it does not need
            # a telemetry sized ring.
            @write_channel = BufferedIO::DatagramChannel.adopt(
              raw_socket(@write_socket).fileno, 1024, 1024 * 1024)
          end
          # An unconnected write socket has nowhere to send(2) to. The stock
          # write_nonblock would fail the same way, so just use it instead.
          unless @write_channel.writable?
            @write_channel.disconnect(0) unless @write_channel.equal?(@read_channel)
            @write_channel = nil
          end
        end
      rescue Exception => error
        BufferedIO.log_fallback(@name)
        Logger.warn("#{@name}: buffered UDP unavailable: "\
                    "#{error.class}: #{error.message}") if defined?(Logger)
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

    # Only a real, bound UDP socket is adopted. A test double, a mock or
    # anything else keeps the stock Ruby path. Deliberately uses is_a? and
    # instance_variable_get rather than duck typing: UdpReadWriteSocket
    # forwards through method_missing without a respond_to_missing?, and
    # probing a double with an unexpected message would fail the caller's test
    # instead of quietly falling back.
    def adoptable_socket?(socket)
      return false unless socket.is_a?(UdpReadWriteSocket)
      raw = raw_socket(socket)
      return false unless raw.is_a?(::UDPSocket)
      return false if raw.closed?
      true
    rescue Exception
      false
    end

    # @return [UDPSocket|nil] The UDPSocket wrapped by a UdpReadWriteSocket
    def raw_socket(socket)
      socket.instance_variable_get(:@socket)
    end
  end
end
