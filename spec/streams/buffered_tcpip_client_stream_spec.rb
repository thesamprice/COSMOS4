# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/streams/buffered_tcpip_client_stream'
require 'cosmos/interfaces/tcpip_client_interface'
require 'socket'

module Cosmos

  # Skipped when the C++ extension is not built or buffered I/O is switched
  # off with COSMOS_NO_BUFFERED_IO: the stock specs cover that path.
  if RUBY_ENGINE == 'ruby' and BufferedIO.available?

  describe BufferedTcpipClientStream do
    # These examples really connect, so they need the real TcpipClientStream
    # rather than the no-ops linc_interface_spec leaves on it process wide.
    # See BufferedSpecs.claim_real_tcpip_client_stream for what that is about.
    before(:all) { @spec_overrides = BufferedSpecs.claim_real_tcpip_client_stream }
    after(:all) { BufferedSpecs.restore_spec_methods(TcpipClientStream, @spec_overrides) }

    before(:each) do
      @listen_socket = TCPServer.new('127.0.0.1', 0)
      @port = @listen_socket.addr[1]
      @stream = nil
    end

    after(:each) do
      @stream.disconnect if @stream and @stream.connected?
      Cosmos.close_socket(@listen_socket)
    end

    describe "initialize" do
      it "complains if the host is bad" do
        expect { BufferedTcpipClientStream.new('asdf', @port, @port, nil, nil) }.to raise_error(/Invalid hostname/)
      end

      it "uses the same socket if read_port == write_port" do
        @stream = BufferedTcpipClientStream.new('localhost', @port, @port, nil, nil)
        @stream.connect
        expect(@stream.connected?).to be true
        expect(@stream.read_channel).to be @stream.write_channel
        @stream.disconnect
      end

      it "creates the write socket" do
        @stream = BufferedTcpipClientStream.new('localhost', @port, nil, nil, nil)
        @stream.connect
        expect(@stream.connected?).to be true
        expect(@stream.write_channel).to_not be_nil
        expect(@stream.read_channel).to be_nil
        @stream.disconnect
      end

      it "creates the read socket" do
        @stream = BufferedTcpipClientStream.new('localhost', nil, @port, nil, nil)
        @stream.connect
        expect(@stream.connected?).to be true
        expect(@stream.read_channel).to_not be_nil
        expect(@stream.write_channel).to be_nil
        @stream.disconnect
      end
    end

    describe "read and write" do
      it "round trips data through the channels" do
        @stream = BufferedTcpipClientStream.new('localhost', @port, @port, 5, 5)
        @stream.connect
        peer = @listen_socket.accept
        begin
          @stream.write('command')
          expect(@stream.flush(2)).to be true
          expect(peer.recv(7)).to eql 'command'
          peer.write('telemetry')
          expect(@stream.read).to eql 'telemetry'
          expect(@stream.last_read_time).to be_a Time
        ensure
          Cosmos.close_socket(peer)
        end
      end
    end

    describe TcpipClientInterface, "buffered wiring" do
      it "uses the buffered stream by default" do
        listen_socket = TCPServer.new('127.0.0.1', 0)
        port = listen_socket.addr[1]
        interface = TcpipClientInterface.new('localhost', port.to_s, port.to_s, '5', '5', 'burst')
        begin
          expect(interface.buffered?).to be true
          interface.connect
          expect(interface.stream).to be_a BufferedTcpipClientStream
          expect(interface.stream.read_channel).to_not be_nil
        ensure
          interface.disconnect
          Cosmos.close_socket(listen_socket)
        end
      end

      it "uses the stock stream with OPTION BUFFERED FALSE" do
        listen_socket = TCPServer.new('127.0.0.1', 0)
        port = listen_socket.addr[1]
        interface = TcpipClientInterface.new('localhost', port.to_s, port.to_s, '5', '5', 'burst')
        begin
          interface.set_option('BUFFERED', ['FALSE'])
          expect(interface.buffered?).to be false
          interface.connect
          expect(interface.stream).to be_a TcpipClientStream
          expect(interface.stream).to_not be_a BufferedTcpipClientStream
        ensure
          interface.disconnect
          Cosmos.close_socket(listen_socket)
        end
      end

      it "uses the stock stream with COSMOS_NO_BUFFERED_IO" do
        listen_socket = TCPServer.new('127.0.0.1', 0)
        port = listen_socket.addr[1]
        interface = TcpipClientInterface.new('localhost', port.to_s, port.to_s, '5', '5', 'burst')
        begin
          ENV['COSMOS_NO_BUFFERED_IO'] = '1'
          expect(interface.buffered?).to be false
          interface.connect
          expect(interface.stream).to_not be_a BufferedTcpipClientStream
        ensure
          ENV.delete('COSMOS_NO_BUFFERED_IO')
          interface.disconnect
          Cosmos.close_socket(listen_socket)
        end
      end

      it "sizes the ring with OPTION BUFFERED_RING_BYTES" do
        listen_socket = TCPServer.new('127.0.0.1', 0)
        port = listen_socket.addr[1]
        interface = TcpipClientInterface.new('localhost', port.to_s, port.to_s, '5', '5', 'burst')
        begin
          interface.set_option('BUFFERED_RING_BYTES', ['131072'])
          interface.connect
          expect(interface.stream.read_channel.ring_bytes).to eql 131072
        ensure
          interface.disconnect
          Cosmos.close_socket(listen_socket)
        end
      end

      it "reads telemetry through the buffered stream" do
        listen_socket = TCPServer.new('127.0.0.1', 0)
        port = listen_socket.addr[1]
        interface = TcpipClientInterface.new('localhost', port.to_s, port.to_s, '5', '5', 'burst')
        peer = nil
        begin
          interface.connect
          peer = listen_socket.accept
          peer.write("\x01\x02\x03\x04")
          packet = interface.read
          expect(packet.buffer).to eql "\x01\x02\x03\x04"
          expect(interface.read_count).to eql 1
        ensure
          Cosmos.close_socket(peer) if peer
          interface.disconnect
          Cosmos.close_socket(listen_socket)
        end
      end
    end
  end

  else

  # Not silence: a spec file that simply vanishes when the extension is
  # missing makes the run look green for code nobody ran. See BufferedSpecs.
  BufferedSpecs.skipped_group('BufferedTcpipClientStream')

  end # RUBY_ENGINE == 'ruby' and BufferedIO.available?
end
