# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'cosmos/streams/tcpip_client_stream'
require 'cosmos/streams/buffered_tcpip_socket_stream'

module Cosmos

  # {TcpipClientStream} which reads and writes through the buffered C++
  # backend. Ruby still resolves the hostname, creates the sockets and performs
  # the non blocking connect (all unchanged from {TcpipClientStream}); the C++
  # channels adopt the descriptors once the connection is up.
  class BufferedTcpipClientStream < TcpipClientStream
    include BufferedSocketStream

    # @param hostname (see TcpipClientStream#initialize)
    # @param write_port (see TcpipClientStream#initialize)
    # @param read_port (see TcpipClientStream#initialize)
    # @param write_timeout (see TcpipClientStream#initialize)
    # @param read_timeout (see TcpipClientStream#initialize)
    # @param connect_timeout (see TcpipClientStream#initialize)
    # @param options [Hash] Buffered channel options (see
    #   BufferedSocketStream#setup_buffered_options)
    def initialize(hostname, write_port, read_port, write_timeout, read_timeout,
                   connect_timeout = 5.0, options = {})
      super(hostname, write_port, read_port, write_timeout, read_timeout, connect_timeout)
      setup_buffered_options(options)
    end
  end

end # module Cosmos
