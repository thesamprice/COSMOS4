# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/streams/buffered_tcpip_socket_stream'
require 'socket'

module Cosmos

  # Skipped when the C++ extension is not built or buffered I/O is switched
  # off with COSMOS_NO_BUFFERED_IO: the stock specs cover that path.
  if RUBY_ENGINE == 'ruby' and BufferedIO.available?

  describe BufferedTcpipSocketStream do
    # Creates a connected loopback pair. Returns the client socket (ours) and
    # the accepted server socket (the peer).
    def loopback_pair
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      client = TCPSocket.new('127.0.0.1', port)
      peer = server.accept
      [client, peer, server]
    end

    def wait_until(timeout = 2.0)
      start = Time.now.sys
      while (Time.now.sys - start) < timeout
        return true if yield
        sleep 0.01
      end
      false
    end

    before(:each) do
      @client = nil
      @peer = nil
      @server = nil
      @stream = nil
    end

    after(:each) do
      @stream.disconnect if @stream and @stream.connected?
      Cosmos.close_socket(@client) if @client
      Cosmos.close_socket(@peer) if @peer
      Cosmos.close_socket(@server) if @server
    end

    def build_stream(write_socket, read_socket, write_timeout = nil, read_timeout = nil, options = {})
      @stream = BufferedTcpipSocketStream.new(write_socket, read_socket, write_timeout, read_timeout, options)
      @stream.connect
      @stream
    end

    describe "initialize, connected?" do
      it "is not connected when initialized" do
        stream = BufferedTcpipSocketStream.new(nil, nil, nil, nil)
        expect(stream.connected?).to be false
      end

      it "adopts the connected socket descriptors" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, @client)
        expect(@stream.connected?).to be true
        expect(@stream.read_channel).to_not be_nil
        # Same socket for read and write shares one channel
        expect(@stream.write_channel).to be @stream.read_channel
        expect(@stream.buffered_stats[:buffered]).to be true
      end

      it "uses separate channels for separate sockets" do
        @client, @peer, @server = loopback_pair
        client2, peer2, server2 = loopback_pair
        begin
          build_stream(client2, @client)
          expect(@stream.read_channel).to_not be @stream.write_channel
        ensure
          @stream.disconnect
          Cosmos.close_socket(client2)
          Cosmos.close_socket(peer2)
          Cosmos.close_socket(server2)
        end
      end

      it "falls back to the stock implementation for a socket that is not connected" do
        socket = double("socket")
        allow(socket).to receive(:closed?).and_return(false)
        stream = BufferedTcpipSocketStream.new(socket, socket, nil, nil)
        stream.connect
        expect(stream.connected?).to be true
        expect(stream.read_channel).to be_nil
        expect(stream.buffered_stats[:buffered]).to be false
      end
    end

    describe "read" do
      it "raises an error if no read socket given" do
        stream = BufferedTcpipSocketStream.new('write', nil, nil, nil)
        stream.connect
        expect { stream.read }.to raise_error("Attempt to read from write only stream")
        stream.disconnect
      end

      it "returns data written by the peer" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        @peer.write("test")
        expect(@stream.read).to eql 'test'
      end

      it "returns everything buffered while Ruby was busy" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        100.times { |index| @peer.write("%04d" % index) }
        @peer.flush
        data = ''
        while data.length < 400
          chunk = @stream.read
          break if chunk.length == 0
          data << chunk
        end
        expect(data.length).to eql 400
        expect(data[0, 4]).to eql '0000'
        expect(data[-4, 4]).to eql '0099'
      end

      it "records the receive time of the data" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        expect(@stream.last_read_time).to be_nil
        before = Time.now.sys
        @peer.write("timestamped")
        expect(@stream.read).to eql 'timestamped'
        expect(@stream.last_read_time).to be_a Time
        expect(@stream.last_read_time_f).to be >= (before.to_f - 1.0)
        expect(@stream.last_read_time_f).to be <= (Time.now.sys.to_f + 1.0)
      end

      it "raises EOFError when the peer closes" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        @peer.write("last")
        expect(@stream.read).to eql 'last'
        @peer.close
        expect { @stream.read }.to raise_error(EOFError)
      end

      it "returns buffered data before reporting EOF" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        @peer.write("data")
        @peer.close
        expect(wait_until { @stream.read_channel.eof? }).to be true
        expect(@stream.read).to eql 'data'
        expect { @stream.read }.to raise_error(EOFError)
      end

      it "handles socket timeouts" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 0.1)
        start = Time.now.sys
        expect { @stream.read }.to raise_error(Timeout::Error)
        expect(Time.now.sys - start).to be < 2.0
      end

      it "is interrupted by disconnect" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, nil) # nil timeout - blocks forever
        result = :none
        thread = Thread.new { result = @stream.read }
        sleep 0.2
        expect(thread.alive?).to be true
        @stream.disconnect
        expect(thread.join(2)).to_not be_nil
        expect(result).to eql ''
      end

      it "is interrupted by Thread#kill so Cosmos.kill_thread still works" do
        allow(Logger).to receive(:warn)
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, nil)
        thread = Thread.new do
          begin
            @stream.read
          rescue Exception
          end
        end
        sleep 0.2
        expect(thread.alive?).to be true
        Cosmos.kill_thread(nil, thread)
        expect(thread.alive?).to be false
      end

      it "does not block other Ruby threads" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        counter = 0
        spinner = Thread.new { 200.times { counter += 1; sleep 0.001 } }
        sleep 0.05
        @peer.write("go")
        expect(@stream.read).to eql 'go'
        expect(counter).to be > 0
        spinner.kill
        spinner.join(2)
      end
    end

    describe "read_nonblock" do
      it "returns immediately" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        expect(@stream.read_nonblock).to eql ''
        @peer.write("test")
        expect(wait_until { @stream.read_channel.buffered_bytes > 0 }).to be true
        expect(@stream.read_nonblock).to eql 'test'
      end
    end

    describe "write" do
      it "raises an error if no write socket given" do
        stream = BufferedTcpipSocketStream.new(nil, 'read', nil, nil)
        stream.connect
        expect { stream.write('test') }.to raise_error("Attempt to write to read only stream")
        stream.disconnect
      end

      it "queues data for the C++ writer thread" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, nil, 5, nil)
        @stream.write('test')
        expect(@stream.flush(2)).to be true
        expect(@peer.recv(4)).to eql 'test'
      end

      it "preserves write ordering" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, nil, 5, nil)
        received = ''
        reader = Thread.new do
          while received.length < 400
            chunk = @peer.recv(65536)
            break if chunk.nil? or chunk.length == 0
            received << chunk
          end
        end
        100.times { |index| @stream.write("%04d" % index) }
        expect(@stream.flush(5)).to be true
        reader.join(5)
        expect(received.length).to eql 400
        expect(received).to eql (0...100).map { |index| "%04d" % index }.join
      end

      it "raises when the queue overflows with the raise policy" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, nil, 5, nil, :write_policy => :raise, :write_high_water => 4096)
        expect(@stream.write_channel.write_policy).to eql :raise
        expect {
          # Nothing is reading the peer so the queue backs up behind the socket
          10000.times { @stream.write('x' * 4096) }
        }.to raise_error(BufferedIO::OverflowError)
      end
    end

    describe "statistics" do
      it "counts bytes read and written" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, @client, 5, 5)
        @stream.write('command')
        expect(@stream.flush(2)).to be true
        expect(@peer.recv(7)).to eql 'command'
        @peer.write('telemetry')
        expect(@stream.read).to eql 'telemetry'
        stats = @stream.buffered_stats
        expect(stats[:bytes_read]).to eql 9
        expect(stats[:bytes_written]).to eql 7
        expect(stats[:high_water]).to eql 9
        expect(stats[:drop_count]).to eql 0
      end

      it "back pressures instead of dropping by default" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5, :ring_bytes => 65536)
        expect(@stream.read_channel.overflow_policy).to eql :backpressure
        sent = 0
        blaster = Thread.new do
          begin
            20.times { @peer.write('B' * 65536); sent += 65536 }
          rescue Exception
          end
        end
        sleep 0.5
        # The ring fills and the reader thread stops reading the socket, which
        # is exactly the flow control the stock stream relies on: no drops.
        expect(@stream.read_channel.drop_count).to eql 0
        received = 0
        while received < sent or blaster.alive?
          data = @stream.read
          break if data.length == 0
          received += data.length
        end
        blaster.join(5)
        expect(@stream.read_channel.drop_count).to eql 0
        expect(received).to be >= 65536
      end

      it "counts drops instead of silently losing data with a drop policy" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5, :ring_bytes => 65536, :overflow_policy => :drop_oldest)
        expect(@stream.read_channel.ring_bytes).to eql 65536
        expect(@stream.read_channel.overflow_policy).to eql :drop_oldest
        blaster = Thread.new do
          begin
            50.times { @peer.write('A' * 65536) }
          rescue Exception
          end
        end
        blaster.join(10)
        expect(wait_until(5) { @stream.read_channel.drop_count > 0 }).to be true
        expect(@stream.buffered_stats[:drop_count]).to be > 0
        expect(@stream.buffered_stats[:high_water]).to eql 65536
        # Still usable after overflowing
        expect(@stream.read.length).to be > 0
      end
    end

    describe "disconnect" do
      it "stops the channels and closes the sockets" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, @client, 5, 5)
        channel = @stream.read_channel
        expect(@stream.connected?).to be true
        @stream.disconnect
        expect(@stream.connected?).to be false
        expect(channel.connected?).to be false
        expect(@client.closed?).to be true
      end

      it "can be called twice" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, @client, 5, 5)
        @stream.disconnect
        expect(@stream.connected?).to be false
        @stream.disconnect
        expect(@stream.connected?).to be false
      end

      it "flushes queued writes before stopping" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, nil, 5, nil)
        @stream.write('goodbye')
        @stream.disconnect
        expect(@peer.recv(7)).to eql 'goodbye'
      end
    end
  end

  describe BufferedIO do
    it "reports whether the extension is loaded" do
      expect(BufferedIO.extension_loaded?).to be true
      expect(BufferedIO.available?).to be true
    end

    it "is disabled by COSMOS_NO_BUFFERED_IO" do
      begin
        ENV['COSMOS_NO_BUFFERED_IO'] = '1'
        expect(BufferedIO.disabled_by_env?).to be true
        expect(BufferedIO.available?).to be false
      ensure
        ENV.delete('COSMOS_NO_BUFFERED_IO')
      end
      expect(BufferedIO.available?).to be true
    end

    it "does not disable on a false value" do
      begin
        ENV['COSMOS_NO_BUFFERED_IO'] = 'false'
        expect(BufferedIO.disabled_by_env?).to be false
      ensure
        ENV.delete('COSMOS_NO_BUFFERED_IO')
      end
    end
  end

  end # RUBY_ENGINE == 'ruby' and BufferedIO.available?
end
