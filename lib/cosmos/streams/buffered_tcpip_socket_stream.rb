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
  # Everything the two byte stream transports do the same way - options,
  # statistics, read, write, flush, disconnect - lives in
  # {Cosmos::BufferedIO::Transport}. What is left here is what is specific to a
  # socket: probing a descriptor with remote_address, and the :adopt_write_only
  # switch the TCP server needs.
  #
  # Everything else (return values, exceptions, timeouts) matches
  # {TcpipSocketStream} so protocols and interfaces see no difference. If a
  # channel cannot be created the stock Ruby implementation is used.
  module BufferedSocketStream
    include BufferedIO::Transport

    # Errors that mean the socket went away underneath us. The stock
    # {TcpipSocketStream} returns an empty string for these and lets the
    # interface handle the disconnect.
    SOCKET_READ_ERRORS = [IOError, Errno::ECONNRESET, Errno::ECONNABORTED,
                          Errno::ENOTSOCK, Errno::EBADF, Errno::ENOTCONN,
                          Errno::EPIPE].freeze

    # (see BufferedIO::Transport#setup_buffered_options)
    #
    # @param options [Hash] Adds :adopt_write_only to the shared options
    def setup_buffered_options(options = {})
      options ||= {}
      # Whether a socket that is only ever written (a separate write port) gets
      # a channel of its own. True everywhere except the TCP server, which
      # detects a departed write-only client by reading that socket in Ruby -
      # a C++ reader thread on the same descriptor would eat the EOF and the
      # client would never be reaped. See TcpipServerInterface.
      @adopt_write_only = options.key?(:adopt_write_only) ? !!options[:adopt_write_only] : true
      super(options)
    end

    # Connect the sockets (super) and then adopt their descriptors
    def connect
      super()
      adopt_buffered_channels
      @connected
    end

    protected

    # (see BufferedIO::Transport#buffered_readable?)
    def buffered_readable?
      !!@read_socket
    end

    # (see BufferedIO::Transport#buffered_writable?)
    def buffered_writable?
      !!@write_socket
    end

    # (see BufferedIO::Transport#buffered_read_errors)
    def buffered_read_errors
      SOCKET_READ_ERRORS
    end

    # Adopt the connected sockets. Called inside the fallback-on-any-failure
    # wrapper in {BufferedIO::Transport#adopt_buffered_channels}.
    def adopt_channels
      if @read_socket and adoptable?(@read_socket)
        @read_channel = BufferedIO::StreamChannel.adopt(@read_socket.fileno, @ring_bytes)
        @read_channel.overflow_policy = @overflow_policy if @overflow_policy
      end
      if @write_socket and adoptable?(@write_socket)
        if @read_socket and @write_socket.equal?(@read_socket) and @read_channel
          @write_channel = @read_channel
        elsif @adopt_write_only
          # A write only socket never delivers telemetry, so it does not need
          # a telemetry sized ring.
          @write_channel = BufferedIO::StreamChannel.adopt(@write_socket.fileno,
                                                           WRITE_ONLY_RING_BYTES)
          @write_channel.overflow_policy = @overflow_policy if @overflow_policy
        end
      end
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
