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

module Cosmos

  # Skipped when the C++ extension is not built or buffered I/O is switched off
  # with COSMOS_NO_BUFFERED_IO: spec/interfaces/udp_interface_spec.rb covers
  # that path, and it is run in both modes.
  if RUBY_ENGINE == 'ruby' and BufferedIO.available?

  # Every port is claimed from the ephemeral range rather than hard coded so
  # examples cannot steal each other's datagrams.
  def self.free_udp_port
    socket = UDPSocket.new
    socket.bind('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    port
  end

  describe BufferedIO::DatagramChannel do
    def free_port
      Cosmos.free_udp_port
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
      it "drops the oldest datagrams and counts them" do
        channel, port = build_channel(10, 1024 * 1024)
        expect(channel.ring_datagrams).to eql 10
        50.times { |index| send_datagram(port, [index].pack('N')) }
        expect(wait_until(5) { channel.drop_count >= 40 }).to be true
        expect(channel.buffered_datagrams).to eql 10
        expect(channel.high_water).to eql 10
        # Freshest telemetry wins: the last 10 sequence numbers survived
        kept = []
        10.times { kept << channel.read(2).unpack1('N') }
        expect(kept).to eql (40...50).to_a
        expect(channel.drop_count).to eql 40
      end

      it "drops the newest datagrams when asked to" do
        channel, port = build_channel(10, 1024 * 1024)
        channel.overflow_policy = :drop_newest
        expect(channel.overflow_policy).to eql :drop_newest
        30.times { |index| send_datagram(port, [index].pack('N')) }
        expect(wait_until(5) { channel.drop_count >= 20 }).to be true
        kept = []
        10.times { kept << channel.read(2).unpack1('N') }
        expect(kept).to eql (0...10).to_a
      end

      it "stops at the byte cap before the datagram cap" do
        # 40 byte cap with 10 byte datagrams: 4 fit, the datagram cap of 1000
        # is never reached.
        channel, port = build_channel(1000, 40)
        expect(channel.ring_bytes).to eql 40
        20.times { |index| send_datagram(port, ('%02d' % index) * 5) }
        expect(wait_until(5) { channel.drop_count >= 16 }).to be true
        expect(channel.buffered_datagrams).to eql 4
        expect(channel.buffered_bytes).to eql 40
      end

      it "refuses back pressure, which cannot make UDP lossless" do
        channel, _port = build_channel
        expect { channel.overflow_policy = :backpressure }.to raise_error(ArgumentError, /back pressure/)
        expect(channel.overflow_policy).to eql :drop_oldest
      end

      it "counts every datagram off the wire even when the ring drops" do
        channel, port = build_channel(4, 1024 * 1024)
        20.times { send_datagram(port, '12345') }
        expect(wait_until(5) { channel.drop_count >= 16 }).to be true
        expect(channel.bytes_read).to eql 100
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

      it "flushes queued writes before stopping" do
        receiver = UDPSocket.new
        receiver.bind('127.0.0.1', 0)
        port = receiver.addr[1]
        begin
          channel, _my_port = build_channel
          channel.set_destination('127.0.0.1', port)
          channel.write('goodbye')
          channel.disconnect(1)
          expect(receiver.recvfrom(100)[0]).to eql 'goodbye'
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
      Cosmos.free_udp_port
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
        @interface.set_option('BUFFERED_RING_DATAGRAMS', ['8'])
        @interface.connect
        @peer = UdpWriteSocket.new('localhost', port)
        100.times { |index| @peer.write([index].pack('N')) }
        start = Time.now.sys
        while @interface.buffered_stats[:drop_count] == 0 and (Time.now.sys - start) < 5.0
          sleep 0.01
        end
        stats = @interface.buffered_stats
        expect(stats[:drop_count]).to be > 0
        expect(stats[:high_water]).to eql 8
        # Freshest telemetry survived and is still readable
        expect(@interface.read.buffer.unpack1('N')).to be >= 8
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

  end # RUBY_ENGINE == 'ruby' and BufferedIO.available?
end
