# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/interfaces/tcpip_client_interface'
require 'socket'

module Cosmos

  # Skipped when the C++ extension is not built or buffered I/O is switched off
  # with COSMOS_NO_BUFFERED_IO: spec/interfaces/tcpip_client_interface_spec.rb
  # covers that path unchanged, and it is run in both modes.
  if RUBY_ENGINE == 'ruby' and BufferedIO.available?

  # The TCP client interface end of the buffered stack. The stream itself is
  # covered by spec/streams/buffered_tcpip_client_stream_spec.rb; what is here
  # is the part only an Interface has - OPTION parsing reaching the channel,
  # and the connect / disconnect / connect cycle an auto-reconnecting interface
  # performs for real every time a link drops.
  describe TcpipClientInterface do
    # These examples really connect, so they need the real TcpipClientStream
    # rather than the no-ops linc_interface_spec leaves on it process wide -
    # with those in place connect returns without connecting and the accept on
    # the other end blocks for ever. See
    # BufferedSpecs.claim_real_tcpip_client_stream.
    before(:all) { @spec_overrides = BufferedSpecs.claim_real_tcpip_client_stream }
    after(:all) { BufferedSpecs.restore_spec_methods(TcpipClientStream, @spec_overrides) }

    before(:each) do
      @listen_socket = nil
      @interface = nil
      @peer = nil
    end

    after(:each) do
      begin
        @interface.disconnect if @interface
      rescue Exception
      end
      Cosmos.close_socket(@peer) if @peer
      Cosmos.close_socket(@listen_socket) if @listen_socket
    end

    def listen
      @listen_socket = TCPServer.new('127.0.0.1', 0)
      @listen_socket.addr[1]
    end

    def build_interface(port, options = {})
      @interface = TcpipClientInterface.new('127.0.0.1', port.to_s, port.to_s,
                                            '5', '5', 'burst')
      options.each { |name, values| @interface.set_option(name, values) }
      @interface
    end

    # Connects the interface and accepts the other end of the link.
    #
    # The accept is bounded. A bare TCPServer#accept that never returns takes
    # the whole suite down with it and gives no clue why, which is exactly what
    # happened when this file first met linc_interface_spec's stubbed
    # connect_nonblock: connect returned without connecting and nothing ever
    # arrived. Failing here says so in one line.
    def connect_and_accept(port)
      @interface.connect
      unless IO.select([@listen_socket], nil, nil, 10.0)
        raise "no connection arrived within 10s - is TcpipClientStream#connect_nonblock stubbed?"
      end
      @peer = @listen_socket.accept
    end

    describe "connect, disconnect, connect" do
      # An auto-reconnecting interface does exactly this every time a link
      # drops, so the second connect has to build brand new channels rather
      # than reuse (or leak) the stopped ones. UdpInterface has the same
      # example; this is the byte stream half of it.
      it "releases the channels on disconnect and reconnects with new ones" do
        port = listen
        build_interface(port)
        connect_and_accept(port)

        stream = @interface.stream
        first_read = stream.read_channel
        expect(first_read).to_not be_nil
        expect(stream.write_channel).to be first_read
        @peer.write('before')
        expect(@interface.read.buffer).to eql 'before'

        @interface.disconnect
        expect(first_read.connected?).to be false
        expect(@interface.connected?).to be false
        Cosmos.close_socket(@peer)

        connect_and_accept(port)
        second = @interface.stream
        expect(second.read_channel).to_not be_nil
        # A fresh channel, not the stopped one handed back
        expect(second.read_channel).to_not be first_read
        expect(second.buffered_stats[:buffered]).to be true
        @peer.write('after')
        expect(@interface.read.buffer).to eql 'after'
      end

      # Each channel adopts a dup(2) of Ruby's descriptor, so a channel that
      # failed to close its copy at disconnect would cost one descriptor per
      # reconnect and eventually take out a long lived server with EMFILE. Ten
      # cycles is enough to make that obvious.
      #
      # GC first, and a tolerance: a completed cycle leaves the previous
      # TCPSocket unreferenced but not yet collected, and an uncollected Ruby
      # socket still holds its descriptor. That is ordinary Ruby, not a leak -
      # measured, it accounts for exactly the two per cycle that come back the
      # moment GC runs. What must NOT come back is a descriptor no Ruby object
      # owns, which is what this is looking for.
      it "survives several cycles without leaking descriptors" do
        port = listen
        build_interface(port)
        GC.start
        before = open_descriptor_count
        10.times do
          connect_and_accept(port)
          @interface.disconnect
          Cosmos.close_socket(@peer)
          @peer = nil
        end
        GC.start
        expect(open_descriptor_count).to be <= (before + 4)
      end

      # @return [Integer] Descriptors this process holds open
      def open_descriptor_count
        count = 0
        # Probing the table directly rather than shelling out to lsof: no
        # dependency, and it counts what this process actually holds.
        0.upto(1023) do |descriptor|
          begin
            IO.for_fd(descriptor, :autoclose => false).stat
            count += 1
          rescue Exception
          end
        end
        count
      end
    end

    describe "OPTION BUFFERED_OVERFLOW" do
      # End to end: the OPTION line an operator writes in cmd_tlm_server.txt
      # has to reach the C++ channel's policy, through set_option,
      # @buffered_options and the stream constructor. Every link in that chain
      # was covered separately; nothing covered the chain.
      it "reaches the C++ channel" do
        port = listen
        build_interface(port, 'BUFFERED_OVERFLOW' => ['drop_newest'])
        connect_and_accept(port)
        expect(@interface.stream.read_channel.overflow_policy).to eql :drop_newest
      end

      it "leaves back pressure in place by default" do
        port = listen
        build_interface(port)
        connect_and_accept(port)
        # TCP is lossless today and stays lossless unless asked otherwise
        expect(@interface.stream.read_channel.overflow_policy).to eql :backpressure
      end

      it "carries the ring size through as well" do
        port = listen
        build_interface(port, 'BUFFERED_RING_BYTES' => ['131072'])
        connect_and_accept(port)
        expect(@interface.stream.read_channel.ring_bytes).to eql 131072
      end

      it "refuses a policy that is not one of the three" do
        port = listen
        expect {
          build_interface(port, 'BUFFERED_OVERFLOW' => ['drop_everything'])
        }.to raise_error(ArgumentError, /BUFFERED_OVERFLOW/)
      end
    end

    describe "OPTION BUFFERED FALSE" do
      it "uses the stock stream" do
        port = listen
        build_interface(port, 'BUFFERED' => ['FALSE'])
        expect(@interface.buffered?).to be false
        connect_and_accept(port)
        expect(@interface.stream).to be_a TcpipClientStream
        expect(@interface.stream).to_not be_a BufferedTcpipClientStream
        expect(@interface.buffered_stats[:buffered]).to be false
        @peer.write('stock')
        expect(@interface.read.buffer).to eql 'stock'
      end
    end
  end

  else

  # Not silence: a spec file that simply vanishes when the extension is
  # missing makes the run look green for code nobody ran. See BufferedSpecs.
  BufferedSpecs.skipped_group('TcpipClientInterface (buffered)')

  end # RUBY_ENGINE == 'ruby' and BufferedIO.available?
end
