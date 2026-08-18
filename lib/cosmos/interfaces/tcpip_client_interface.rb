# encoding: ascii-8bit

# Copyright 2017 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'cosmos/interfaces/stream_interface'
require 'cosmos/streams/tcpip_client_stream'
require 'cosmos/streams/buffered_tcpip_client_stream'

module Cosmos
  # Base class for interfaces that act as a TCP/IP client
  class TcpipClientInterface < StreamInterface

    # @param hostname [String] Machine to connect to
    # @param write_port [Integer] Port to write commands to
    # @param read_port [Integer] Port to read telemetry from
    # @param write_timeout [Integer] Seconds to wait before aborting writes
    # @param read_timeout [Integer] Seconds to wait before aborting reads
    # @param protocol_type [String] Name of the protocol to use
    #   with this interface
    # @param protocol_args [Array<String>] Arguments to pass to the protocol
    def initialize(
      hostname,
      write_port,
      read_port,
      write_timeout,
      read_timeout,
      protocol_type = nil,
      *protocol_args)

      super(protocol_type, protocol_args)

      @hostname = hostname
      @write_port = ConfigParser.handle_nil(write_port)
      @read_port = ConfigParser.handle_nil(read_port)
      @write_timeout = write_timeout
      @read_timeout = read_timeout
      @read_allowed = false unless @read_port
      @write_allowed = false unless @write_port
      @write_raw_allowed = false unless @write_port
      # nil means "use the buffered backend if it is available" (the default).
      # OPTION BUFFERED FALSE or COSMOS_NO_BUFFERED_IO force the stock stream.
      @buffered = nil
      @buffered_options = {}
    end

    # Connects the stream by passing the initialization parameters to
    # {BufferedTcpipClientStream} (the default) or {TcpipClientStream}.
    def connect
      @stream = build_stream()
      super()
    end

    # @return [Boolean] Whether this interface reads and writes through the
    #   buffered C++ backend
    def buffered?
      return false if @buffered == false
      BufferedIO.available?
    end

    # Adds the BUFFERED option which disables the buffered C++ backend for this
    # interface. Also supports BUFFERED_RING_BYTES to size the read ring.
    #
    # @param option_name (see Interface#set_option)
    # @param option_values (see Interface#set_option)
    def set_option(option_name, option_values)
      super(option_name, option_values)
      case option_name.to_s.upcase
      when 'BUFFERED'
        @buffered = ConfigParser.handle_true_false(option_values[0].to_s)
      when 'BUFFERED_RING_BYTES'
        @buffered_options[:ring_bytes] = Integer(option_values[0])
      end
    end

    protected

    def build_stream
      if buffered?
        BufferedTcpipClientStream.new(
          @hostname,
          @write_port,
          @read_port,
          @write_timeout,
          @read_timeout,
          5.0,
          @buffered_options
        )
      else
        # Automatic, logged once: the extension is not available on this
        # platform so the original pure Ruby stream is used unchanged.
        BufferedIO.log_fallback(@name) if @buffered.nil? and !BufferedIO.extension_loaded?
        TcpipClientStream.new(
          @hostname,
          @write_port,
          @read_port,
          @write_timeout,
          @read_timeout
        )
      end
    end
  end
end
