# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/io/buffered_io'
require 'cosmos/interfaces/tcpip_client_interface'
require 'cosmos/interfaces/tcpip_server_interface'
require 'cosmos/interfaces/udp_interface'
require 'cosmos/interfaces/serial_interface'
require 'cosmos/streams/buffered_tcpip_socket_stream'
require 'socket'

module Cosmos

  # This file runs in BOTH modes on purpose. It is the proof that every
  # buffered class degrades to the original pure Ruby code when the C++
  # extension is unavailable - the platforms the first pass does not cover, and
  # the COSMOS_NO_BUFFERED_IO opt-out.
  describe BufferedIO do
    describe "feature switch" do
      it "reports whether the extension is loaded" do
        expect([true, false]).to include BufferedIO.extension_loaded?
        expect(BufferedIO.available?).to eql(BufferedIO.extension_loaded? &&
                                             !BufferedIO.disabled_by_env?)
      end

      it "is disabled by COSMOS_NO_BUFFERED_IO" do
        begin
          ENV['COSMOS_NO_BUFFERED_IO'] = '1'
          expect(BufferedIO.disabled_by_env?).to be true
          expect(BufferedIO.available?).to be false
        ensure
          ENV.delete('COSMOS_NO_BUFFERED_IO')
        end
      end

      it "treats falsy values as not set" do
        %w(0 false FALSE no NO).each do |value|
          begin
            ENV['COSMOS_NO_BUFFERED_IO'] = value
            expect(BufferedIO.disabled_by_env?).to be false
          ensure
            ENV.delete('COSMOS_NO_BUFFERED_IO')
          end
        end
      end

      it "logs the fallback at most once" do
        BufferedIO.reset_fallback_log
        expect(Cosmos::Logger).to receive(:info).once
        BufferedIO.log_fallback('TEST_INT')
        BufferedIO.log_fallback('TEST_INT')
        BufferedIO.reset_fallback_log
      end
    end

    describe "empty_stats" do
      it "is the canonical zeroed shape every transport answers with" do
        stats = BufferedIO.empty_stats
        expect(stats[:buffered]).to be false
        %i(bytes_read bytes_written drop_count stall_count buffered_bytes
           high_water ring_bytes pending_write_bytes).each do |key|
          expect(stats[key]).to eql 0
        end
      end

      it "returns a fresh hash each time so callers can mutate it" do
        first = BufferedIO.empty_stats
        first[:drop_count] = 99
        expect(BufferedIO.empty_stats[:drop_count]).to eql 0
      end
    end
  end

  # Everything below forces the "extension not available" answer, which is
  # exactly what a platform without the extension sees. Nothing may raise and
  # every interface must land on its original stream.
  describe "buffered I/O fallback (extension unavailable)" do
    before(:each) do
      allow(BufferedIO).to receive(:available?).and_return(false)
      allow(BufferedIO).to receive(:extension_loaded?).and_return(false)
      allow(BufferedIO).to receive(:log_fallback)
    end

    def free_tcp_port
      socket = TCPServer.new('127.0.0.1', 0)
      port = socket.addr[1]
      socket.close
      port
    end

    def free_udp_port
      socket = UDPSocket.new
      socket.bind('127.0.0.1', 0)
      port = socket.addr[1]
      socket.close
      port
    end

    describe "TcpipClientInterface" do
      it "reports it is not buffered and builds the stock stream" do
        interface = TcpipClientInterface.new('localhost', '8888', '8889', '5', '5', 'burst')
        expect(interface.buffered?).to be false
        expect(TcpipClientStream).to receive(:new).and_return(double("stream"))
        expect(BufferedTcpipClientStream).to_not receive(:new)
        interface.send(:build_stream)
      end
    end

    describe "TcpipServerInterface" do
      it "reports it is not buffered and wraps clients in the stock stream" do
        interface = TcpipServerInterface.new('8888', '8888', '5', '5', 'burst')
        expect(interface.buffered?).to be false
        stream = interface.send(:build_client_stream, nil, nil)
        expect(stream).to be_a TcpipSocketStream
        expect(stream).to_not be_a BufferedTcpipSocketStream
      end

      it "still answers buffered_stats with zeros" do
        interface = TcpipServerInterface.new('8888', '8888', '5', '5', 'burst')
        stats = interface.buffered_stats
        expect(stats[:buffered]).to be false
        expect(stats[:clients]).to eql 0
        expect(stats[:drop_count]).to eql 0
        expect(stats[:stall_count]).to eql 0
      end
    end

    describe "UdpInterface" do
      it "reports it is not buffered and adopts no channels" do
        port = free_udp_port
        interface = UdpInterface.new('localhost', 'nil', port.to_s)
        expect(interface.buffered?).to be false
        begin
          interface.connect
          expect(interface.read_channel).to be_nil
          expect(interface.write_channel).to be_nil
          expect(interface.buffered_stats[:buffered]).to be false
          expect(interface.buffered_stats[:drop_count]).to eql 0
        ensure
          interface.disconnect
        end
      end
    end

    describe "SerialInterface" do
      it "reports it is not buffered and builds the stock stream" do
        interface = SerialInterface.new('/dev/null', '/dev/null', 9600, :NONE, 1, 10.0, nil, 'burst')
        expect(interface.buffered?).to be false
        expect(SerialStream).to receive(:new).and_return(double("stream"))
        expect(BufferedSerialStream).to_not receive(:new)
        interface.send(:build_stream)
      end
    end

    describe "BufferedTcpipSocketStream" do
      # The buffered stream class itself must still work when it cannot get a
      # channel: it inherits the stock implementation and simply uses it.
      it "reads and writes through the stock Ruby implementation" do
        server = TCPServer.new('127.0.0.1', 0)
        port = server.addr[1]
        client = TCPSocket.new('127.0.0.1', port)
        peer = server.accept
        stream = BufferedTcpipSocketStream.new(client, client, 5, 5)
        begin
          stream.connect
          expect(stream.connected?).to be true
          expect(stream.read_channel).to be_nil
          expect(stream.write_channel).to be_nil
          expect(stream.buffered?).to be false
          expect(stream.buffered_stats[:buffered]).to be false

          stream.write('command')
          expect(peer.recv(7)).to eql 'command'
          peer.write('telemetry')
          expect(stream.read).to eql 'telemetry'
          expect(stream.flush(1)).to be true
          expect(stream.last_read_time).to be_nil
        ensure
          stream.disconnect
          Cosmos.close_socket(peer)
          Cosmos.close_socket(server)
        end
      end
    end
  end
end
