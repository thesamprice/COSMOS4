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
  #
  # Options: BUFFERED, BUFFERED_RING_BYTES and BUFFERED_OVERFLOW, all parsed by
  # {BufferedIO::InterfaceOptions#set_option}. TCP is lossless today and stays
  # lossless by default; see doc/buffered_io_design.md for why a byte stream
  # defaults to back pressure while UDP defaults to dropping.
  class TcpipClientInterface < StreamInterface
    include BufferedIO::InterfaceOptions

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
      # BUFFERED, BUFFERED_RING_BYTES and BUFFERED_OVERFLOW; the stream's own
      # defaults (16 MiB ring, :backpressure) apply until one is given.
      initialize_buffered_options()
    end

    # Connects the stream by passing the initialization parameters to
    # {BufferedTcpipClientStream} (the default) or {TcpipClientStream}.
    def connect
      @stream = build_stream()
      super()
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
        log_buffered_fallback()
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
