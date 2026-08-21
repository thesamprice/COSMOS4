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

      it "logs the fallback at most once per name" do
        BufferedIO.reset_fallback_log
        expect(Cosmos::Logger).to receive(:info).once
        BufferedIO.log_fallback('TEST_INT')
        BufferedIO.log_fallback('TEST_INT')
        BufferedIO.reset_fallback_log
      end

      # Keyed per name, not module-global: a server with ten interfaces where
      # one cannot adopt its descriptor used to log that one and then go silent
      # about the other nine, whatever happened to them.
      it "logs each interface separately" do
        BufferedIO.reset_fallback_log
        expect(Cosmos::Logger).to receive(:info).twice
        BufferedIO.log_fallback('INT_ONE')
        BufferedIO.log_fallback('INT_TWO')
        BufferedIO.log_fallback('INT_ONE')
        BufferedIO.log_fallback('INT_TWO')
        expect(BufferedIO.fallback_logged?('INT_ONE')).to be true
        expect(BufferedIO.fallback_logged?('INT_THREE')).to be false
        BufferedIO.reset_fallback_log
      end

      # The two reasons are completely different problems and the operator acts
      # on them differently: rebuild the extension, versus look at what is wrong
      # with this one descriptor. Reporting the first when it was the second
      # sends them off to fix a build that is fine.
      it "reports the caller's reason rather than blaming the extension" do
        BufferedIO.reset_fallback_log
        logged = nil
        expect(Cosmos::Logger).to receive(:info) { |message| logged = message }
        BufferedIO.log_fallback('TEST_INT', 'buffered channel could not be created (Errno::EBADF: bad)')
        expect(logged).to include 'TEST_INT'
        expect(logged).to include 'Errno::EBADF'
        expect(logged).to_not include 'extension unavailable'
        BufferedIO.reset_fallback_log
      end

      it "blames the extension when no reason is given" do
        BufferedIO.reset_fallback_log
        logged = nil
        expect(Cosmos::Logger).to receive(:info) { |message| logged = message }
        BufferedIO.log_fallback('TEST_INT')
        expect(logged).to include 'extension unavailable'
        BufferedIO.reset_fallback_log
      end
    end

    # These run in BOTH modes: a configuration file has to be accepted or
    # refused identically whether or not the C++ extension is built, otherwise
    # a config that loads on the developer's machine fails on the flight
    # machine (or worse, quietly runs different settings).
    describe "option validation" do
      def tcp_interface
        TcpipClientInterface.new('localhost', '8888', '8889', '5', '5', 'burst')
      end

      def udp_interface
        UdpInterface.new('localhost', '8888', '8889')
      end

      it "accepts TRUE and FALSE for BUFFERED" do
        interface = tcp_interface
        interface.set_option('BUFFERED', ['FALSE'])
        expect(interface.buffered?).to be false
        interface.set_option('BUFFERED', ['true'])
        expect(interface.instance_variable_get(:@buffered)).to be true
      end

      # ConfigParser.handle_true_false passes anything it does not recognize
      # straight back, so these used to be stored as truthy strings and read as
      # "buffered on" - the exact opposite of what was written.
      it "raises on a BUFFERED value that is not TRUE or FALSE" do
        %w(no 0 off yes maybe).each do |value|
          expect { tcp_interface.set_option('BUFFERED', [value]) }
            .to raise_error(ArgumentError, /BUFFERED must be TRUE or FALSE/)
        end
      end

      it "raises on a BUFFERED_RING_BYTES that is not a positive integer" do
        ['0', '-1', 'lots', '', '16MB'].each do |value|
          expect { tcp_interface.set_option('BUFFERED_RING_BYTES', [value]) }
            .to raise_error(ArgumentError, /BUFFERED_RING_BYTES/)
        end
      end

      it "raises on a BUFFERED_RING_BYTES outside the legal range" do
        expect { tcp_interface.set_option('BUFFERED_RING_BYTES', ['1024']) }
          .to raise_error(ArgumentError, /between #{BufferedIO::MIN_RING_BYTES}/)
        expect { tcp_interface.set_option('BUFFERED_RING_BYTES',
                                          [(BufferedIO::MAX_RING_BYTES + 1).to_s]) }
          .to raise_error(ArgumentError, /between/)
      end

      it "accepts a legal BUFFERED_RING_BYTES" do
        interface = tcp_interface
        interface.set_option('BUFFERED_RING_BYTES', ['1048576'])
        expect(interface.instance_variable_get(:@buffered_options)[:ring_bytes]).to eql 1048576
      end

      it "raises on a garbage BUFFERED_OVERFLOW" do
        expect { tcp_interface.set_option('BUFFERED_OVERFLOW', ['drop_oldst']) }
          .to raise_error(ArgumentError, /must be one of/)
      end

      # Not reading a UDP socket cannot make UDP lossless, it only moves the
      # loss into SO_RCVBUF where nothing counts it. Asking for it is a
      # mistake worth failing the config load over.
      it "raises on backpressure for UDP but allows it for a byte stream" do
        expect { udp_interface.set_option('BUFFERED_OVERFLOW', ['backpressure']) }
          .to raise_error(ArgumentError, /drop_oldest, drop_newest/)
        interface = tcp_interface
        interface.set_option('BUFFERED_OVERFLOW', ['backpressure'])
        expect(interface.instance_variable_get(:@buffered_options)[:overflow_policy])
          .to eql :backpressure
      end

      it "raises on a BUFFERED_RING_DATAGRAMS outside the legal range" do
        expect { udp_interface.set_option('BUFFERED_RING_DATAGRAMS', ['8']) }
          .to raise_error(ArgumentError, /between #{BufferedIO::MIN_RING_DATAGRAMS}/)
        interface = udp_interface
        interface.set_option('BUFFERED_RING_DATAGRAMS', ['1024'])
        expect(interface.instance_variable_get(:@buffered_options)[:ring_datagrams])
          .to eql 1024
      end

      it "validates BUFFERED_READ_CHUNK and BUFFERED_WRITE_HIGH_WATER" do
        expect { tcp_interface.set_option('BUFFERED_READ_CHUNK', ['0']) }
          .to raise_error(ArgumentError, /BUFFERED_READ_CHUNK/)
        expect { tcp_interface.set_option('BUFFERED_WRITE_HIGH_WATER', ['nope']) }
          .to raise_error(ArgumentError, /BUFFERED_WRITE_HIGH_WATER must be an integer/)
        interface = tcp_interface
        interface.set_option('BUFFERED_READ_CHUNK', ['1048576'])
        interface.set_option('BUFFERED_WRITE_HIGH_WATER', ['8388608'])
        options = interface.instance_variable_get(:@buffered_options)
        expect(options[:read_chunk_bytes]).to eql 1048576
        expect(options[:write_high_water]).to eql 8388608
      end

      # An option a transport has no use for stays ignored, exactly as an
      # unknown option always has been.
      it "ignores an option this transport does not accept" do
        interface = tcp_interface
        expect { interface.set_option('BUFFERED_RING_DATAGRAMS', ['garbage']) }
          .to_not raise_error
        expect(interface.instance_variable_get(:@buffered_options)[:ring_datagrams])
          .to be_nil
      end
    end

    describe "stream option defaults" do
      it "defaults the read chunk to the stock 64 KiB, not to the ring size" do
        stream = BufferedTcpipSocketStream.new(nil, nil, nil, nil)
        expect(stream.instance_variable_get(:@read_chunk_bytes)).to eql 65536
        expect(stream.instance_variable_get(:@ring_bytes))
          .to eql BufferedIO::Transport::DEFAULT_RING_BYTES
      end

      it "treats a non positive size as use the default" do
        stream = BufferedTcpipSocketStream.new(nil, nil, nil, nil,
                                               :ring_bytes => 0, :read_chunk_bytes => -5)
        expect(stream.instance_variable_get(:@ring_bytes))
          .to eql BufferedIO::Transport::DEFAULT_RING_BYTES
        expect(stream.instance_variable_get(:@read_chunk_bytes)).to eql 65536
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

  # The C++ boundary itself. These use the channel classes directly, so they
  # run whenever the extension is built - including under COSMOS_NO_BUFFERED_IO,
  # which only decides whether the interfaces reach for a channel.
  if RUBY_ENGINE == 'ruby' and BufferedIO.extension_loaded?
    describe "buffered channel boundary" do
      before(:each) do
        @channel = nil
        @sockets = []
      end

      after(:each) do
        begin
          @channel.disconnect(0) if @channel
        rescue Exception
        end
        @sockets.each { |socket| Cosmos.close_socket(socket) rescue nil }
      end

      def stream_pair
        server = TCPServer.new('127.0.0.1', 0)
        client = TCPSocket.new('127.0.0.1', server.addr[1])
        peer = server.accept
        @sockets.concat([server, client, peer])
        [client, peer]
      end

      def bound_udp
        socket = UDPSocket.new
        socket.bind('127.0.0.1', 0)
        @sockets << socket
        socket
      end

      # FIX 9. A StreamChannel's ring has no message boundaries, so its reader
      # would splice datagrams together silently. A datagram socket has to go
      # to DatagramChannel; refusing it here is what makes the interface fall
      # back instead of quietly corrupting UDP.
      it "refuses to adopt a SOCK_DGRAM socket as a stream channel" do
        expect { BufferedIO::StreamChannel.adopt(bound_udp.fileno) }
          .to raise_error(ArgumentError, /SOCK_STREAM/)
      end

      it "refuses to adopt something that is neither a socket nor a tty" do
        reader, writer = IO.pipe
        begin
          expect { BufferedIO::StreamChannel.adopt(reader.fileno) }
            .to raise_error(ArgumentError, /socket or tty/)
        ensure
          reader.close
          writer.close
        end
      end

      # FIX 1. The Ruby layer validates first; these prove the extension does
      # not simply trust whatever reaches it, and that it raises a Ruby
      # exception rather than allocating something absurd.
      it "refuses a ring size outside the documented bounds" do
        client, _peer = stream_pair
        expect { BufferedIO::StreamChannel.adopt(client.fileno, 1024) }
          .to raise_error(ArgumentError, /ring bytes/)
        expect { BufferedIO::StreamChannel.adopt(client.fileno,
                                                 BufferedIO::MAX_RING_BYTES + 1) }
          .to raise_error(ArgumentError, /ring bytes/)
        expect { BufferedIO::DatagramChannel.adopt(bound_udp.fileno, 4) }
          .to raise_error(ArgumentError, /ring datagrams/)
      end

      it "accepts exactly the bounds the Ruby layer advertises" do
        client, _peer = stream_pair
        @channel = BufferedIO::StreamChannel.adopt(client.fileno, BufferedIO::MIN_RING_BYTES)
        expect(@channel.connected?).to be true
        @channel.disconnect(0)
        @channel = BufferedIO::DatagramChannel.adopt(bound_udp.fileno,
                                                     BufferedIO::MIN_RING_DATAGRAMS,
                                                     BufferedIO::MIN_RING_BYTES)
        expect(@channel.ring_datagrams).to eql BufferedIO::MIN_RING_DATAGRAMS
      end

      # FIX 9. A zero cap can only return an empty string, which the caller
      # cannot tell apart from a closed device.
      it "refuses a non positive max_bytes on read" do
        client, peer = stream_pair
        @channel = BufferedIO::StreamChannel.adopt(client.fileno)
        peer.write('data')
        expect { @channel.read(1, 0) }.to raise_error(ArgumentError, /max_bytes/)
        expect { @channel.read(1, -1) }.to raise_error(ArgumentError, /max_bytes/)
      end

      # FIX 2a. The queue exists to absorb a burst while the GVL is held, not
      # to hide a dead peer: a 16 MiB mark delayed the Timeout::Error the stock
      # stream would already have raised.
      it "defaults the write high water mark to 2 MiB" do
        client, _peer = stream_pair
        @channel = BufferedIO::StreamChannel.adopt(client.fileno)
        expect(@channel.write_high_water).to eql 2 * 1024 * 1024
        expect(BufferedIO::DEFAULT_WRITE_HIGH_WATER).to eql 2 * 1024 * 1024
      end

      # FIX 3. A stop that hangs must still be interruptible: without a real
      # unblock function the disconnect ran with the GVL released and nothing
      # could reach the thread.
      # FIX 9. Adopting used to force the descriptor blocking, which is Ruby's
      # flag (a dup shares the file status flags) and changes how Ruby's own
      # read_nonblock/write_nonblock behave on the same socket. Both loops park
      # in poll(2) on EAGAIN instead, so either mode works and the flag is left
      # exactly as Ruby set it.
      it "leaves the socket's O_NONBLOCK flag alone and still moves data" do
        client, peer = stream_pair
        client.fcntl(Fcntl::F_SETFL, client.fcntl(Fcntl::F_GETFL, 0) | File::NONBLOCK)
        before = client.fcntl(Fcntl::F_GETFL, 0)

        @channel = BufferedIO::StreamChannel.adopt(client.fileno)
        expect(client.fcntl(Fcntl::F_GETFL, 0)).to eql before
        expect(before & File::NONBLOCK).to_not eql 0

        peer.write('nonblocking')
        expect(@channel.read(5)).to eql 'nonblocking'
        @channel.write('back')
        expect(@channel.flush(5)).to be true
        expect(peer.recv(4)).to eql 'back'
      end

      # FIX 9. set_destination copies a sockaddr the writer thread reads at the
      # same time. Unsynchronized, a send could go out against a half written
      # address - one that never existed.
      it "retargets a datagram channel safely while writes are in flight" do
        first = bound_udp
        second = bound_udp
        source = UDPSocket.new
        source.bind('127.0.0.1', 0)
        @sockets << source
        @channel = BufferedIO::DatagramChannel.adopt(source.fileno)

        @channel.set_destination('127.0.0.1', first.addr[1])
        flapper = Thread.new do
          200.times do |index|
            target = index.even? ? first : second
            @channel.set_destination('127.0.0.1', target.addr[1])
          end
        end
        200.times { |index| @channel.write("msg%03d" % index) }
        flapper.join(10)
        expect(@channel.flush(5)).to be true

        # Every datagram landed on one of the two real ports, intact.
        seen = 0
        [first, second].each do |socket|
          loop do
            begin
              data, = socket.recvfrom_nonblock(100)
            rescue IO::WaitReadable, Errno::EAGAIN
              break
            end
            expect(data).to match(/\Amsg\d{3}\z/)
            seen += 1
          end
        end
        expect(seen).to be > 0
      end

      it "lets Thread#kill escape a disconnect that is stuck flushing" do
        client, _peer = stream_pair
        channel = BufferedIO::StreamChannel.adopt(client.fileno)
        @channel = channel
        # More than the socket buffers hold, to a peer that never reads: the
        # writer thread parks in send(2) and the flush can never finish.
        channel.write_high_water = 64 * 1024 * 1024
        channel.write('Q' * (16 * 1024 * 1024))
        expect(channel.pending_write_bytes).to be > 0

        thread = Thread.new { channel.disconnect(300.0) }
        sleep 0.3
        expect(thread.alive?).to be true
        thread.kill
        expect(thread.join(10)).to_not be_nil
        expect(thread.alive?).to be false
      end
    end
  end
end
