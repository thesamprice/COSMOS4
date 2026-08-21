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

      # A timestamp that survives the disconnect reads as "data arrived at
      # 10:31" on a link that went down at 10:31 and has been dead since. The
      # counters all reset at disconnect; this has to as well.
      it "forgets the receive time once the channels are released" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        @peer.write("timestamped")
        expect(@stream.read).to eql 'timestamped'
        expect(@stream.last_read_time).to be_a Time
        @stream.disconnect
        expect(@stream.last_read_time).to be_nil
        expect(@stream.last_read_time_f).to be_nil
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

    # The reader thread cannot raise - it holds no GVL and has no Ruby thread
    # to raise into - so a transport failure is latched as an errno and handed
    # to whoever reads next. Asserted at the channel rather than the stream
    # because BufferedSocketStream deliberately turns these into the stock
    # empty read; the class of the underlying exception is what decides that,
    # and it has to be the real Errno::*, not a generic IOError.
    describe "error latch" do
      it "surfaces a latched errno as the matching Errno from the next read" do
        @client, @peer, @server = loopback_pair
        channel = BufferedIO::StreamChannel.adopt(@client.fileno)
        begin
          # SO_LINGER with a zero timeout makes close(2) send RST instead of
          # FIN, so the parked reader gets ECONNRESET rather than a clean EOF.
          # Unread data in the peer's receive queue is what guarantees the RST.
          @peer.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack('ii'))
          @client.write('x' * 100)
          sleep 0.2
          @peer.close
          @peer = nil

          expect { channel.read(5) }.to raise_error(Errno::ECONNRESET)
          # Latched, not consumed: it keeps reporting the same failure rather
          # than looking healthy again on the next call.
          expect { channel.read(5) }.to raise_error(Errno::ECONNRESET)
          expect(channel.connected?).to be false
        ensure
          channel.disconnect(0) rescue nil
        end
      end

      # An empty read is how the stream tells the interface to shut down, and
      # the socket transport lists ECONNRESET among the errors that mean that.
      it "is turned into the stock empty read by the stream" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        @peer.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack('ii'))
        @client.write('x' * 100)
        sleep 0.2
        @peer.close
        @peer = nil
        expect(@stream.read).to eql ''
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
        # A per read Timeout::Error here is not a failure, it is the loop
        # racing the blaster: the blaster is parked in a blocked write, this
        # thread drains the ring dry, and the next read waits out its 5 second
        # timeout before the blaster gets scheduled again. On a loaded machine
        # that is ordinary. Rescue and keep draining, bounded by one overall
        # deadline so a genuinely wedged reader still fails instead of looping
        # for ever.
        received = 0
        deadline = Time.now.sys + 60.0
        while (received < sent or blaster.alive?) and Time.now.sys < deadline
          begin
            data = @stream.read
          rescue Timeout::Error
            next
          end
          break if data.length == 0
          received += data.length
        end
        blaster.join(5)
        blaster.kill if blaster.alive?
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

      # The old version of this wrote 7 bytes and then disconnected. The writer
      # thread had already put them on the wire before disconnect was even
      # called, so it passed whether the disconnect flush worked or did nothing
      # at all - it asserted nothing about flushing.
      #
      # This one blocks the writer first: the peer never reads, so the send
      # buffer fills and the writer thread parks in poll(POLLOUT) with the rest
      # of the payload still queued (asserted, not assumed). Only then does the
      # peer start reading and the disconnect run, and every byte has to arrive.
      it "flushes a queue the writer is still working through" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, @client, 5, 5)
        # Comfortably more than any SO_SNDBUF/SO_RCVBUF pair holds, so the
        # backlog cannot simply be absorbed by the kernel.
        payload = 'Q' * (4 * 1024 * 1024)
        @stream.write_channel.write_high_water = payload.length * 2
        @stream.write(payload)
        expect(@stream.write_channel.pending_write_bytes).to be > 0

        received = 0
        reader = Thread.new do
          begin
            while (chunk = @peer.readpartial(65536))
              received += chunk.length
            end
          rescue EOFError, IOError, Errno::ECONNRESET
          end
        end

        @stream.disconnect
        reader.join(10)
        reader.kill if reader.alive?
        expect(received).to eql payload.length
      end

      # FIX 2c. The peer half closes (it will never send again) so the reader
      # latches EOF, which makes the channel report connected? == false while
      # the socket is still perfectly writable. Gating the disconnect flush on
      # connected? therefore threw away everything still queued; gating it on
      # stopped? drains it. Writing to a half closed TCP socket is legal, and
      # this is the ordinary shutdown sequence - the peer stops talking, we
      # still owe it the last command.
      it "drains queued writes after the peer half closes (EOF latched)" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, @client, 5, 5)
        # More than any socket buffer pair will hold, so the bytes really do
        # have to be drained by the writer thread during the disconnect.
        payload = 'Z' * (4 * 1024 * 1024)

        @peer.shutdown(Socket::SHUT_WR)
        expect(wait_until(5) { @stream.read_channel.eof? }).to be true
        expect(@stream.read_channel.connected?).to be false

        @stream.write_channel.write_high_water = payload.length * 2
        @stream.write(payload)
        expect(@stream.write_channel.pending_write_bytes).to be > 0

        received = 0
        reader = Thread.new do
          begin
            while (chunk = @peer.readpartial(65536))
              received += chunk.length
            end
          rescue EOFError, IOError, Errno::ECONNRESET
          end
        end

        @stream.disconnect
        reader.join(10)
        reader.kill if reader.alive?
        expect(received).to eql payload.length
      end

      # FIX 2b. A stopped channel has no writer thread left, so bytes handed to
      # it can never leave. Reporting them as written (which is what a plain
      # "queue full" answer amounted to once stop_ was set) loses commands
      # silently; the write has to fail.
      it "raises IOError on a write after disconnect instead of counting the bytes" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, @client, 5, 5)
        channel = @stream.write_channel
        @stream.disconnect
        expect { channel.write('too late') }.to raise_error(IOError)
        # ... and nothing is left claiming to be on its way out
        expect(channel.pending_write_bytes).to eql 0
      end
    end

    # FIX 7. A BURST protocol turns whatever one read returns into one packet,
    # so the read cap decides packet sizes for every existing configuration.
    # It has to stay at the stock 64 KiB unless an operator asks otherwise.
    describe "read chunk sizing" do
      it "returns at most 65536 bytes from a larger backlog by default" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5)
        expect(@stream.instance_variable_get(:@read_chunk_bytes)).to eql 65536

        total = 512 * 1024
        writer = Thread.new { @peer.write('y' * total); @peer.flush }
        expect(wait_until(5) { @stream.read_channel.buffered_bytes > 65536 }).to be true
        chunk = @stream.read
        expect(chunk.length).to eql 65536
        writer.join(5)
      end

      it "honors a larger BUFFERED_READ_CHUNK" do
        @client, @peer, @server = loopback_pair
        build_stream(nil, @client, nil, 5, :read_chunk_bytes => 1024 * 1024)
        total = 512 * 1024
        writer = Thread.new { @peer.write('y' * total); @peer.flush }
        expect(wait_until(5) { @stream.read_channel.buffered_bytes > 65536 }).to be true
        expect(@stream.read.length).to be > 65536
        writer.join(5)
      end
    end

    # FIX 5. disconnect() nils the channel ivars from another thread, so any
    # method that tests @read_channel and then dereferences it can hit nil in
    # between. Every one of them snapshots into a local first. This is a stress
    # test rather than a deterministic one - the window is a few instructions -
    # so it asserts the only thing that matters: no NoMethodError ever escapes.
    describe "channel nil race" do
      it "never raises NoMethodError when the channel is dropped mid call" do
        @client, @peer, @server = loopback_pair
        build_stream(@client, @client, 5, 0.01)
        channel = @stream.read_channel
        errors = []
        stop = false

        workers = []
        workers << Thread.new do
          until stop
            begin
              @stream.read
            rescue NoMethodError => error
              errors << error
            rescue Exception
              # Every other outcome is legitimate: a timeout, an EOF, or the
              # IOError a stopped channel raises.
            end
          end
        end
        workers << Thread.new do
          until stop
            begin
              @stream.buffered_stats
              @stream.connected?
              @stream.flush(0)
              @stream.read_nonblock
              @stream.write('x')
            rescue NoMethodError => error
              errors << error
            rescue Exception
            end
          end
        end

        # Flap the ivars underneath the workers.
        200.times do
          @stream.instance_variable_set(:@read_channel, nil)
          @stream.instance_variable_set(:@write_channel, nil)
          @stream.instance_variable_set(:@read_channel, channel)
          @stream.instance_variable_set(:@write_channel, channel)
        end
        stop = true
        workers.each { |worker| worker.join(5) }
        workers.each { |worker| worker.kill if worker.alive? }
        expect(errors).to be_empty
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

  else

  # Not silence: a spec file that simply vanishes when the extension is
  # missing makes the run look green for code nobody ran. See BufferedSpecs.
  BufferedSpecs.skipped_group('BufferedTcpipSocketStream')

  end # RUBY_ENGINE == 'ruby' and BufferedIO.available?
end
