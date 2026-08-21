# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/interfaces/udp_interface'
require 'cosmos/io/udp_sockets'
require 'socket'

# Every port is claimed from the ephemeral range rather than hard coded so
# examples cannot steal each other's datagrams.
#
# In a module of its own rather than as Cosmos.free_udp_port: a spec has no
# business adding methods to the library's own namespace, where they outlive
# this file, are visible to every other spec in the process, and would collide
# outright if the library ever grows a method by that name.
module BufferedUdpSpecPorts
  def self.free_udp_port
    socket = UDPSocket.new
    socket.bind('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    port
  end
end

module Cosmos

  # Skipped when the C++ extension is not built or buffered I/O is switched off
  # with COSMOS_NO_BUFFERED_IO: spec/interfaces/udp_interface_spec.rb covers
  # that path, and it is run in both modes.
  if RUBY_ENGINE == 'ruby' and BufferedIO.available?

  describe BufferedIO::DatagramChannel do
    def free_port
      BufferedUdpSpecPorts.free_udp_port
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
      @socket = nil
      @sender = nil
      @channel = nil
    end

    after(:each) do
      begin
        @channel.disconnect(0) if @channel
      rescue Exception
      end
      Cosmos.close_socket(@socket) if @socket
      Cosmos.close_socket(@sender) if @sender
    end

    # Returns [channel, port, sender socket]
    def build_channel(datagrams = nil, bytes = nil)
      @socket = UDPSocket.new
      @socket.bind('127.0.0.1', 0)
      port = @socket.addr[1]
      @channel = BufferedIO::DatagramChannel.adopt(@socket.fileno, datagrams, bytes)
      @sender = UDPSocket.new
      [@channel, port]
    end

    def send_datagram(port, data)
      @sender.send(data, 0, '127.0.0.1', port)
    end

    describe "adopt" do
      it "adopts a bound UDP socket" do
        channel, _port = build_channel
        expect(channel.connected?).to be true
        expect(channel.ring_datagrams).to eql BufferedIO::DatagramChannel::DEFAULT_RING_DATAGRAMS
        expect(channel.ring_bytes).to eql BufferedIO::DatagramChannel::DEFAULT_RING_BYTES
        expect(channel.overflow_policy).to eql :drop_oldest
      end

      it "refuses a stream socket" do
        server = TCPServer.new('127.0.0.1', 0)
        begin
          expect { BufferedIO::DatagramChannel.adopt(server.fileno) }.to raise_error(ArgumentError)
        ensure
          Cosmos.close_socket(server)
        end
      end

      it "refuses a descriptor that is not a socket" do
        file = File.open(File::NULL, 'r')
        begin
          expect { BufferedIO::DatagramChannel.adopt(file.fileno) }.to raise_error(ArgumentError)
        ensure
          file.close
        end
      end

      it "duplicates the descriptor so Ruby can close its own copy" do
        channel, port = build_channel
        send_datagram(port, 'still here')
        expect(wait_until { channel.buffered_datagrams > 0 }).to be true
        @socket.close
        expect(channel.read(1)).to eql 'still here'
      end
    end

    describe "read" do
      it "returns exactly one datagram per read" do
        channel, port = build_channel
        send_datagram(port, 'aaa')
        send_datagram(port, 'bbbbbb')
        expect(wait_until { channel.buffered_datagrams == 2 }).to be true
        expect(channel.read(2)).to eql 'aaa'
        expect(channel.read(2)).to eql 'bbbbbb'
      end

      it "never coalesces datagrams even when many are buffered" do
        channel, port = build_channel
        200.times { |index| send_datagram(port, "%04d" % index) }
        expect(wait_until(5) { channel.buffered_datagrams >= 200 }).to be true
        200.times do |index|
          expect(channel.read(2)).to eql("%04d" % index)
        end
      end

      it "preserves ordering" do
        channel, port = build_channel
        500.times { |index| send_datagram(port, [index].pack('N')) }
        expect(wait_until(5) { channel.buffered_datagrams >= 500 }).to be true
        received = []
        500.times { received << channel.read(2).unpack1('N') }
        expect(received).to eql (0...500).to_a
      end

      it "delivers a zero length datagram as a datagram" do
        channel, port = build_channel
        send_datagram(port, '')
        send_datagram(port, 'after')
        expect(wait_until { channel.buffered_datagrams == 2 }).to be true
        expect(channel.read(2)).to eql ''
        expect(channel.read(2)).to eql 'after'
      end

      it "returns nil on timeout" do
        channel, _port = build_channel
        start = Time.now.sys
        expect(channel.read(0.1)).to be_nil
        expect(Time.now.sys - start).to be < 2.0
      end

      it "carries the receive time with the datagram" do
        channel, port = build_channel
        before = Time.now.sys.to_f
        send_datagram(port, 'stamped')
        data, time = channel.read_with_time(2)
        expect(data).to eql 'stamped'
        expect(time).to be >= (before - 1.0)
        expect(time).to be <= (Time.now.sys.to_f + 1.0)
        expect(channel.last_read_time).to eql time
      end

      it "reports the peer address" do
        channel, port = build_channel
        send_datagram(port, 'whoami')
        data, _time, host, peer_port = channel.read_with_peer(2)
        expect(data).to eql 'whoami'
        expect(host).to eql '127.0.0.1'
        expect(peer_port).to eql @sender.addr[1]
      end

      it "is interrupted by disconnect from another thread" do
        # The unconnected UDP case: shutdown(2) returns ENOTCONN on macOS and
        # would leave the reader parked forever, so the channel uses a
        # self-pipe. This example is what proves teardown really unblocks.
        channel, _port = build_channel
        result = :none
        thread = Thread.new do
          begin
            channel.read(nil) # nil timeout - blocks forever
          rescue Exception => error
            result = error.class
          end
        end
        sleep 0.2
        expect(thread.alive?).to be true
        channel.disconnect(0)
        expect(thread.join(5)).to_not be_nil
        expect(result).to eql IOError
      end

      it "is interrupted by Thread#kill so Cosmos.kill_thread still works" do
        allow(Logger).to receive(:warn)
        channel, _port = build_channel
        thread = Thread.new do
          begin
            channel.read(nil)
          rescue Exception
          end
        end
        sleep 0.2
        expect(thread.alive?).to be true
        Cosmos.kill_thread(nil, thread)
        expect(thread.alive?).to be false
      end

      it "does not block other Ruby threads" do
        channel, port = build_channel
        counter = 0
        spinner = Thread.new { 200.times { counter += 1; sleep 0.001 } }
        sleep 0.05
        send_datagram(port, 'go')
        expect(channel.read(2)).to eql 'go'
        expect(counter).to be > 0
        spinner.kill
        spinner.join(2)
      end

      it "raises IOError once disconnected" do
        channel, _port = build_channel
        channel.disconnect(0)
        expect { channel.read(1) }.to raise_error(IOError)
      end
    end

    describe "overflow" do
      # Loopback UDP is NOT lossless. SO_RCVBUF can overflow before the C++
      # reader reaches a datagram, and that loss happens inside the kernel
      # where this channel can neither see nor count it. So none of these
      # examples may assume all N datagrams arrived.
      #
      # What they assert instead: the ring's own arithmetic, which is exact and
      # kernel independent (everything that arrived was either kept or counted
      # as a drop), plus the property actually under test - which end of the
      # queue survives. A tolerance on the sequence numbers absorbs a handful of
      # kernel drops without weakening either claim, because drop-oldest and
      # drop-newest produce ranges at opposite ends of what was sent and no
      # plausible amount of kernel loss makes one look like the other.

      # @return [Integer] Datagrams the channel actually saw, from its own
      #   counters. bytes_read counts every datagram off the wire whether or
      #   not the ring kept it.
      def arrived(channel)
        channel.drop_count + channel.buffered_datagrams
      end

      # Wait until the reader thread has stopped receiving, so the counters can
      # be compared against each other. They are read one at a time and the
      # reader is still running: without this, bytes_read and drop_count are
      # sampled at different instants and disagree by however many datagrams
      # landed in between - which is a racy spec, not a broken channel.
      def settle(channel, timeout = 5.0)
        deadline = Time.now.sys + timeout
        previous = -1
        while Time.now.sys < deadline
          current = channel.bytes_read
          return true if current == previous and current > 0
          previous = current
          sleep 0.05
        end
        false
      end

      it "drops the oldest datagrams and counts them" do
        channel, port = build_channel(16, 1024 * 1024)
        expect(channel.ring_datagrams).to eql 16
        50.times { |index| send_datagram(port, [index].pack('N')) }
        expect(wait_until(5) { channel.drop_count >= 20 }).to be true
        expect(settle(channel)).to be true
        expect(channel.buffered_datagrams).to eql 16
        expect(channel.high_water).to eql 16
        # Nothing that arrived went unaccounted for
        expect(arrived(channel)).to eql(channel.bytes_read / 4)
        expect(arrived(channel)).to be <= 50

        kept = []
        16.times { kept << channel.read(2).unpack1('N') }
        # Freshest telemetry wins: the survivors are the newest 16 of what
        # arrived, in order, right at the end of what was sent. Under the
        # opposite policy this would be 0..15.
        expect(kept).to eql kept.sort
        expect(kept.uniq.length).to eql 16
        expect(kept.last).to be >= 45
        expect(kept.first).to be >= 28
      end

      it "drops the newest datagrams when asked to" do
        channel, port = build_channel(16, 1024 * 1024)
        channel.overflow_policy = :drop_newest
        expect(channel.overflow_policy).to eql :drop_newest
        30.times { |index| send_datagram(port, [index].pack('N')) }
        expect(wait_until(5) { channel.drop_count >= 8 }).to be true
        expect(settle(channel)).to be true
        expect(channel.buffered_datagrams).to eql 16

        kept = []
        16.times { kept << channel.read(2).unpack1('N') }
        # The oldest win: the survivors sit at the start of what was sent, not
        # the end. Under drop-oldest this would be 14..29.
        expect(kept).to eql kept.sort
        expect(kept.uniq.length).to eql 16
        expect(kept.first).to be <= 2
        expect(kept.last).to be <= 21
      end

      it "stops at the byte cap before the datagram cap" do
        # 4096 byte cap with 1024 byte datagrams: 4 fit, the datagram cap of
        # 1000 is never reached.
        channel, port = build_channel(1000, 4096)
        expect(channel.ring_bytes).to eql 4096
        20.times { |index| send_datagram(port, ('%04d' % index) * 256) }
        expect(wait_until(5) { channel.drop_count >= 8 }).to be true
        expect(channel.buffered_datagrams).to eql 4
        expect(channel.buffered_bytes).to eql 4096
      end

      # Only reachable when the byte cap is smaller than a single datagram,
      # which the defaults never are. DROP_OLDEST evicts until the datagram
      # fits, and its loop stops at an empty ring - so without an explicit
      # refusal the ring ended up holding more than the cap it was given, which
      # is the one thing that cap exists to prevent.
      it "refuses a datagram larger than the whole byte cap" do
        channel, port = build_channel(16, 4096)
        send_datagram(port, 'A' * 8192)
        send_datagram(port, 'fits')
        expect(wait_until(5) { channel.drop_count >= 1 }).to be true
        expect(wait_until(5) { channel.buffered_datagrams >= 1 }).to be true
        # The oversized one was refused and counted, the next one was not
        expect(channel.read(2)).to eql 'fits'
        expect(channel.buffered_bytes).to be <= 4096
      end

      # The WRITE queue, not the read ring. Under the default :block policy a
      # writer waits for space; under :raise it gets OverflowError instead, so
      # a tool that must never sit on a full queue can say so. Covered for the
      # socket transport already - this is the datagram channel's own path
      # through the same C++ code.
      it "raises when the write queue overflows with the raise policy" do
        receiver = UDPSocket.new
        receiver.bind('127.0.0.1', 0)
        # A tiny receive buffer, and nothing reading it, so the sender's own
        # send buffer backs up and the writer thread parks.
        receiver.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 2048)
        port = receiver.addr[1]
        begin
          channel, _my_port = build_channel
          channel.set_destination('127.0.0.1', port)
          channel.write_policy = :raise
          channel.write_high_water = 4096
          expect(channel.write_policy).to eql :raise
          expect {
            10000.times { channel.write('u' * 4096) }
          }.to raise_error(BufferedIO::OverflowError)
        ensure
          Cosmos.close_socket(receiver)
        end
      end

      it "refuses back pressure, which cannot make UDP lossless" do
        channel, _port = build_channel
        expect { channel.overflow_policy = :backpressure }.to raise_error(ArgumentError, /back pressure/)
        expect(channel.overflow_policy).to eql :drop_oldest
      end

      it "counts every datagram off the wire even when the ring drops" do
        channel, port = build_channel(16, 1024 * 1024)
        40.times { send_datagram(port, '12345') }
        expect(wait_until(5) { channel.drop_count >= 8 }).to be true
        expect(settle(channel)).to be true
        # The point: bytes_read is what came off the wire, not what survived
        # the ring. Tied to the channel's own accounting rather than to 40,
        # which assumes the kernel dropped none of them.
        expect(channel.bytes_read).to eql(arrived(channel) * 5)
        expect(channel.bytes_read).to be > (16 * 5)
        expect(channel.bytes_read).to be <= (40 * 5)
      end
    end

    describe "write" do
      it "sends through a connected socket" do
        receiver = UDPSocket.new
        receiver.bind('127.0.0.1', 0)
        port = receiver.addr[1]
        begin
          @socket = UDPSocket.new
          @socket.bind('127.0.0.1', 0)
          @socket.connect('127.0.0.1', port)
          @channel = BufferedIO::DatagramChannel.adopt(@socket.fileno)
          expect(@channel.writable?).to be true
          @channel.write('command')
          expect(@channel.flush(2)).to be true
          expect(receiver.recvfrom(100)[0]).to eql 'command'
        ensure
          Cosmos.close_socket(receiver)
        end
      end

      it "sends to an explicit destination on an unconnected socket" do
        receiver = UDPSocket.new
        receiver.bind('127.0.0.1', 0)
        port = receiver.addr[1]
        begin
          channel, _my_port = build_channel
          expect(channel.writable?).to be false
          channel.set_destination('127.0.0.1', port)
          expect(channel.writable?).to be true
          channel.write('unconnected')
          expect(channel.flush(2)).to be true
          expect(receiver.recvfrom(100)[0]).to eql 'unconnected'
        ensure
          Cosmos.close_socket(receiver)
        end
      end

      it "preserves message boundaries and ordering" do
        receiver = UDPSocket.new
        receiver.bind('127.0.0.1', 0)
        port = receiver.addr[1]
        begin
          channel, _my_port = build_channel
          channel.set_destination('127.0.0.1', port)
          100.times { |index| channel.write("%04d" % index) }
          expect(channel.flush(5)).to be true
          100.times do |index|
            expect(receiver.recvfrom(100)[0]).to eql("%04d" % index)
          end
        ensure
          Cosmos.close_socket(receiver)
        end
      end

      it "sends a zero length datagram" do
        receiver = UDPSocket.new
        receiver.bind('127.0.0.1', 0)
        port = receiver.addr[1]
        begin
          channel, _my_port = build_channel
          channel.set_destination('127.0.0.1', port)
          channel.write('')
          expect(channel.flush(2)).to be true
          expect(receiver.recvfrom(100)[0]).to eql ''
        ensure
          Cosmos.close_socket(receiver)
        end
      end
    end

    describe "disconnect" do
      it "can be called twice" do
        channel, _port = build_channel
        channel.disconnect(0)
        expect(channel.connected?).to be false
        channel.disconnect(0)
        expect(channel.connected?).to be false
      end

      # The old version of this queued ONE seven byte datagram and then
      # disconnected. The writer thread had already sent it before disconnect
      # was even called, so it passed whether the disconnect flush worked or
      # did nothing at all - it asserted nothing.
      #
      # This one leaves a queue that is demonstrably still full when disconnect
      # is called (asserted, not assumed) and then requires every queued byte
      # to have reached the kernel by the time disconnect returns. That is what
      # "flushes queued writes before stopping" has to mean.
      #
      # Receipt is checked separately and loosely: UDP on loopback drops, and
      # what the flush controls is how much left this process, not how much
      # survived the trip. bytes_written is the exact, kernel-independent
      # measure of the former.
      it "drains a queue that is still full when disconnect is called" do
        receiver = UDPSocket.new
        receiver.bind('127.0.0.1', 0)
        receiver.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4 * 1024 * 1024)
        port = receiver.addr[1]
        begin
          channel, _my_port = build_channel
          channel.set_destination('127.0.0.1', port)
          # High enough that queueing is what happens rather than blocking, so
          # the backlog is real and the writer thread cannot have cleared it.
          channel.write_high_water = 64 * 1024 * 1024
          count = 2000
          payload = 'D' * 512
          count.times { channel.write(payload) }
          expect(channel.pending_write_bytes).to be > 0

          channel.disconnect(10)
          expect(channel.pending_write_bytes).to eql 0
          expect(channel.bytes_written).to eql(count * payload.length)
        ensure
          Cosmos.close_socket(receiver)
        end
      end
    end

    describe "process teardown" do
      it "does not hang at exit with a reader parked in the kernel" do
        # The VM teardown end proc has to stop the C++ threads. If the self-pipe
        # wakeup were broken this child would hang forever instead of exiting.
        script = <<-RUBY
          $LOAD_PATH.unshift(#{File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'lib')).inspect})
          require 'cosmos/io/buffered_io'
          require 'socket'
          socket = UDPSocket.new
          socket.bind('127.0.0.1', 0)
          channel = Cosmos::BufferedIO::DatagramChannel.adopt(socket.fileno)
          Thread.new { channel.read(nil) }
          sleep 0.2
          exit(0)
        RUBY
        require 'tempfile'
        file = Tempfile.new(['teardown', '.rb'])
        begin
          file.write(script)
          file.close
          pid = spawn(RbConfig.ruby, file.path, :out => File::NULL, :err => File::NULL)
          finished = false
          20.times do
            if Process.waitpid(pid, Process::WNOHANG)
              finished = true
              break
            end
            sleep 0.25
          end
          unless finished
            Process.kill('KILL', pid) rescue nil
            Process.waitpid(pid) rescue nil
          end
          expect(finished).to be true
          expect($?.exitstatus).to eql 0
        ensure
          file.unlink
        end
      end
    end
  end

  describe UdpInterface do
    def free_port
      BufferedUdpSpecPorts.free_udp_port
    end

    before(:each) do
      @interface = nil
      @peer = nil
    end

    after(:each) do
      begin
        @interface.disconnect if @interface
      rescue Exception
      end
      Cosmos.close_socket(@peer) if @peer
    end

    describe "buffering by default" do
      it "adopts the read socket into a datagram channel" do
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        expect(@interface.buffered?).to be true
        @interface.connect
        expect(@interface.read_channel).to be_a BufferedIO::DatagramChannel
        expect(@interface.buffered_stats[:buffered]).to be true
      end

      it "adopts the write socket into a datagram channel" do
        port = free_port
        @interface = UdpInterface.new('localhost', port.to_s, 'nil')
        @interface.connect
        expect(@interface.write_channel).to be_a BufferedIO::DatagramChannel
        expect(@interface.write_channel.writable?).to be true
      end

      it "shares one channel when read and write use one socket" do
        port = free_port
        @interface = UdpInterface.new('localhost', free_port.to_s, port.to_s, port.to_s)
        @interface.connect
        expect(@interface.read_channel).to_not be_nil
        expect(@interface.write_channel).to be @interface.read_channel
      end

      it "returns one packet per datagram with stock counters" do
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        @interface.connect
        @peer = UdpWriteSocket.new('localhost', port)
        expect(@interface.read_count).to eql 0
        expect(@interface.bytes_read).to eql 0

        packet = nil
        thread = Thread.new { packet = @interface.read }
        @peer.write("\x00\x01\x02\x03")
        thread.join(5)
        expect(@interface.read_count).to eql 1
        expect(@interface.bytes_read).to eql 4
        expect(packet.buffer).to eql "\x00\x01\x02\x03"

        thread = Thread.new { packet = @interface.read }
        @peer.write("\x04\x05\x06\x07\x08")
        thread.join(5)
        expect(@interface.read_count).to eql 2
        expect(@interface.bytes_read).to eql 9
        expect(packet.buffer).to eql "\x04\x05\x06\x07\x08"
      end

      it "keeps datagram boundaries when many arrive while Ruby is busy" do
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        @interface.connect
        @peer = UdpWriteSocket.new('localhost', port)
        100.times { |index| @peer.write("%04d" % index) }
        received = []
        100.times { received << @interface.read.buffer }
        expect(received).to eql (0...100).map { |index| "%04d" % index }
        expect(@interface.read_count).to eql 100
        expect(@interface.bytes_read).to eql 400
      end

      it "stamps the kernel receive time on the raw data" do
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        @interface.connect
        @peer = UdpWriteSocket.new('localhost', port)
        before = Time.now.sys.to_f
        @peer.write("\x01")
        @interface.read
        expect(@interface.last_read_time).to be_a Time
        expect(@interface.last_read_time_f).to be >= (before - 1.0)
        expect(@interface.last_read_time_f).to be <= (Time.now.sys.to_f + 1.0)
        expect(@interface.read_raw_data_time.to_f).to be_within(0.001).of(@interface.last_read_time_f)
      end

      it "writes datagrams through the writer thread" do
        port = free_port
        @peer = UdpReadSocket.new(port, 'localhost')
        @interface = UdpInterface.new('localhost', port.to_s, 'nil')
        @interface.connect
        packet = Packet.new('tgt', 'pkt')
        packet.buffer = "\x00\x01\x02\x03"
        @interface.write(packet)
        expect(@peer.read(5)).to eql "\x00\x01\x02\x03"
        expect(@interface.write_count).to eql 1
        expect(@interface.bytes_written).to eql 4
      end

      it "raises Timeout::Error on a read timeout exactly like UdpReadSocket" do
        port = free_port
        stock = UdpReadSocket.new(port, 'localhost')
        begin
          expect { stock.read(0.1) }.to raise_error(Timeout::Error)
        ensure
          Cosmos.close_socket(stock)
        end
        @interface = UdpInterface.new('localhost', 'nil', free_port.to_s, nil, nil, 128, 10.0, 0.1)
        @interface.connect
        expect(@interface.read_channel).to_not be_nil
        expect { @interface.read_interface }.to raise_error(Timeout::Error)
      end

      it "counts ring drops instead of losing datagrams silently" do
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        @interface.set_option('BUFFERED_RING_DATAGRAMS', ['16'])
        @interface.connect
        @peer = UdpWriteSocket.new('localhost', port)
        100.times { |index| @peer.write([index].pack('N')) }
        start = Time.now.sys
        while @interface.buffered_stats[:drop_count] == 0 and (Time.now.sys - start) < 5.0
          sleep 0.01
        end
        stats = @interface.buffered_stats
        expect(stats[:drop_count]).to be > 0
        expect(stats[:high_water]).to eql 16
        # Freshest telemetry survived and is still readable
        expect(@interface.read.buffer.unpack1('N')).to be >= 16
      end
    end

    describe "read thread lifecycle" do
      it "returns nil from read when disconnected on another thread" do
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        @interface.connect
        result = :none
        thread = Thread.new { result = @interface.read }
        sleep 0.2
        expect(thread.alive?).to be true
        @interface.disconnect
        expect(thread.join(5)).to_not be_nil
        expect(result).to be_nil
        expect(@interface.connected?).to be false
      end

      it "is unblocked by Cosmos.kill_thread" do
        allow(Logger).to receive(:warn)
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        @interface.connect
        thread = Thread.new do
          begin
            @interface.read
          rescue Exception
          end
        end
        sleep 0.2
        expect(thread.alive?).to be true
        Cosmos.kill_thread(nil, thread)
        expect(thread.alive?).to be false
      end

      it "releases the channels on disconnect and can reconnect" do
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        @interface.connect
        channel = @interface.read_channel
        @interface.disconnect
        expect(channel.connected?).to be false
        expect(@interface.read_channel).to be_nil
        @interface.connect
        expect(@interface.read_channel).to_not be_nil
        expect(@interface.read_channel).to_not be channel
        @peer = UdpWriteSocket.new('localhost', port)
        @peer.write('reconnected')
        expect(@interface.read.buffer).to eql 'reconnected'
      end
    end

    describe "fallbacks" do
      it "uses the stock sockets with OPTION BUFFERED FALSE" do
        port = free_port
        @interface = UdpInterface.new('localhost', 'nil', port.to_s)
        @interface.set_option('BUFFERED', ['FALSE'])
        expect(@interface.buffered?).to be false
        @interface.connect
        expect(@interface.read_channel).to be_nil
        expect(@interface.buffered_stats[:buffered]).to be false
        @peer = UdpWriteSocket.new('localhost', port)
        @peer.write('stock')
        expect(@interface.read.buffer).to eql 'stock'
      end

      it "uses the stock sockets with COSMOS_NO_BUFFERED_IO" do
        port = free_port
        begin
          ENV['COSMOS_NO_BUFFERED_IO'] = '1'
          @interface = UdpInterface.new('localhost', 'nil', port.to_s)
          expect(@interface.buffered?).to be false
          @interface.connect
          expect(@interface.read_channel).to be_nil
        ensure
          ENV.delete('COSMOS_NO_BUFFERED_IO')
        end
        @peer = UdpWriteSocket.new('localhost', port)
        @peer.write('stock')
        expect(@interface.read.buffer).to eql 'stock'
      end

      it "uses the stock path for a socket that is not a real UDP socket" do
        # Exactly what spec/interfaces/udp_interface_spec.rb does: never probe
        # a double with an unexpected message, just fall back.
        stub = double("read")
        allow(stub).to receive(:read).and_raise(IOError)
        expect(UdpReadSocket).to receive(:new).and_return(stub)
        @interface = UdpInterface.new('localhost', 'nil', free_port.to_s)
        @interface.connect
        expect(@interface.read_channel).to be_nil
        expect(@interface.read_interface).to be_nil
      end

      it "keeps the stock write path when the write socket has no peer" do
        # No hostname means UdpReadWriteSocket never connects, so there is
        # nowhere for send(2) to go.
        port = free_port
        @interface = UdpInterface.new(nil, port.to_s, port.to_s, port.to_s)
        @interface.connect
        expect(@interface.read_channel).to_not be_nil
        expect(@interface.write_channel).to be_nil
      end
    end
  end

  else

  # Not silence: a spec file that simply vanishes when the extension is
  # missing makes the run look green for code nobody ran. See BufferedSpecs.
  BufferedSpecs.skipped_group('UdpInterface (buffered datagrams)')

  end # RUBY_ENGINE == 'ruby' and BufferedIO.available?
end
