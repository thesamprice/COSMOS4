# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/interfaces/tcpip_server_interface'
require 'socket'

module Cosmos

  # Skipped when the C++ extension is not built or buffered I/O is switched off
  # with COSMOS_NO_BUFFERED_IO: spec/interfaces/tcpip_server_interface_spec.rb
  # covers that path unchanged, and it is run in both modes.
  if RUBY_ENGINE == 'ruby' and BufferedIO.available?

  describe TcpipServerInterface do
    before(:each) do
      # The listen and read threads log every connect and disconnect
      allow(Logger.instance).to receive(:info)
      @interface = nil
      @clients = []
    end

    after(:each) do
      begin
        @interface.disconnect if @interface
      rescue Exception
      end
      @clients.each { |client| Cosmos.close_socket(client) }
      @clients.clear
    end

    # A port nobody is listening on. Claimed from the ephemeral range rather
    # than hard coded so examples cannot steal each other's connections.
    def free_port
      socket = TCPServer.new('127.0.0.1', 0)
      port = socket.addr[1]
      socket.close
      port
    end

    def wait_until(timeout = 5.0)
      start = Time.now.sys
      while (Time.now.sys - start) < timeout
        return true if yield
        sleep 0.01
      end
      false
    end

    # One socket per client (write_port == read_port), which is how the vast
    # majority of COSMOS servers are configured.
    def start_server(port, options = {})
      @interface = TcpipServerInterface.new(port.to_s, port.to_s, '5', '5', 'burst')
      @interface.listen_address = '127.0.0.1'
      options.each { |name, values| @interface.set_option(name, values) }
      @interface.connect
      @interface
    end

    def connect_client(port)
      client = TCPSocket.new('127.0.0.1', port)
      @clients << client
      client
    end

    def read_interfaces
      @interface.instance_variable_get(:@read_interface_infos).map { |info| info.interface }
    end

    def write_interfaces
      @interface.instance_variable_get(:@write_interface_infos).map { |info| info.interface }
    end

    # Reads count packets off the server, failing rather than hanging forever
    def read_packets(count, timeout = 5.0)
      packets = []
      count.times do
        expect(wait_until(timeout) { @interface.read_queue_size > 0 }).to be true
        packets << @interface.read
      end
      packets
    end

    describe "accepting clients" do
      it "adopts each accepted socket into its own buffered stream" do
        port = free_port
        start_server(port)
        connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true

        stream = read_interfaces[0].stream
        expect(stream).to be_a BufferedTcpipSocketStream
        expect(stream.buffered?).to be true
        expect(stream.read_channel).to_not be_nil
        # One socket serves both directions, so one channel does too
        expect(stream.write_channel).to be stream.read_channel
      end

      it "reads client data through the buffered channel" do
        port = free_port
        start_server(port)
        client = connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true

        client.write("hello")
        client.flush
        packet = read_packets(1)[0]
        expect(packet.buffer).to eql 'hello'
        expect(read_interfaces[0].stream.buffered_stats[:bytes_read]).to be >= 5
      end

      it "writes to the client through the buffered channel" do
        port = free_port
        start_server(port)
        client = connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true

        @interface.write_raw("command")
        expect(client.read(7)).to eql 'command'
      end

      it "gives every client its own channel" do
        port = free_port
        start_server(port)
        3.times { connect_client(port) }
        expect(wait_until { @interface.num_clients == 3 }).to be true

        channels = read_interfaces.map { |interface| interface.stream.read_channel }
        expect(channels.length).to eql 3
        expect(channels.none?(&:nil?)).to be true
        expect(channels.map(&:object_id).uniq.length).to eql 3
      end

      it "keeps multiple clients' data separate and complete" do
        port = free_port
        start_server(port)
        clients = 3.times.map { connect_client(port) }
        expect(wait_until { @interface.num_clients == 3 }).to be true

        clients.each_with_index do |client, index|
          client.write("client#{index}")
          client.flush
        end
        packets = read_packets(3)
        expect(packets.map { |packet| packet.buffer }.sort).to eql %w(client0 client1 client2)
      end
    end

    describe "per client disconnect" do
      it "tears down only the client that went away" do
        port = free_port
        start_server(port)
        clients = 3.times.map { connect_client(port) }
        expect(wait_until { @interface.num_clients == 3 }).to be true
        survivors = read_interfaces.dup

        # Drop one client and let its read thread notice
        going_away = clients[1]
        going_away.close
        @clients.delete(going_away)
        expect(wait_until { @interface.num_clients == 2 }).to be true

        # The other two are untouched and still deliver telemetry
        [clients[0], clients[2]].each_with_index do |client, index|
          client.write("still#{index}")
          client.flush
        end
        packets = read_packets(2)
        expect(packets.map { |packet| packet.buffer }.sort).to eql %w(still0 still1)

        remaining = read_interfaces
        expect(remaining.length).to eql 2
        remaining.each do |interface|
          expect(interface.stream.read_channel).to_not be_nil
          expect(interface.stream.read_channel.connected?).to be true
          expect(interface.stream.connected?).to be true
        end
        # Nothing about the survivors' identity changed either
        expect((remaining - survivors)).to be_empty
      end

      it "accepts a replacement client after one disconnects" do
        port = free_port
        start_server(port)
        first = connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        first.close
        @clients.delete(first)
        expect(wait_until { @interface.num_clients == 0 }).to be true

        second = connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        second.write("again")
        second.flush
        expect(read_packets(1)[0].buffer).to eql 'again'
      end

      it "stops every client channel on server disconnect" do
        port = free_port
        start_server(port)
        2.times { connect_client(port) }
        expect(wait_until { @interface.num_clients == 2 }).to be true
        channels = read_interfaces.map { |interface| interface.stream.read_channel }

        @interface.disconnect
        expect(@interface.connected?).to be false
        channels.each { |channel| expect(channel.connected?).to be false }
        expect(@interface.num_clients).to eql 0
      end
    end

    describe "separate read and write ports" do
      # The write only socket must stay on the stock Ruby path:
      # check_for_dead_clients reaps a departed write client by reading that
      # socket in Ruby, and a C++ reader thread would eat the EOF first.
      it "does not adopt a write only client socket" do
        write_port = free_port
        read_port = free_port
        @interface = TcpipServerInterface.new(write_port.to_s, read_port.to_s, '5', '5', 'burst')
        @interface.listen_address = '127.0.0.1'
        @interface.connect

        client = connect_client(write_port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        stream = write_interfaces[0].stream
        expect(stream).to be_a BufferedTcpipSocketStream
        expect(stream.write_channel).to be_nil
        expect(stream.read_channel).to be_nil
        expect(stream.buffered?).to be false

        # ...and the stock write path still delivers
        @interface.write_raw("stock")
        expect(client.read(5)).to eql 'stock'
      end

      it "still reaps a departed write only client" do
        write_port = free_port
        read_port = free_port
        @interface = TcpipServerInterface.new(write_port.to_s, read_port.to_s, '5', '5', 'burst')
        @interface.listen_address = '127.0.0.1'
        @interface.connect

        client = connect_client(write_port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        client.close
        @clients.delete(client)
        # check_for_dead_clients runs off the write thread every 100 ms
        expect(wait_until(10.0) { @interface.num_clients == 0 }).to be true
      end

      it "adopts a read only client socket" do
        write_port = free_port
        read_port = free_port
        @interface = TcpipServerInterface.new(write_port.to_s, read_port.to_s, '5', '5', 'burst')
        @interface.listen_address = '127.0.0.1'
        @interface.connect

        client = connect_client(read_port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        stream = read_interfaces[0].stream
        expect(stream.read_channel).to_not be_nil
        expect(stream.write_channel).to be_nil

        client.write("telemetry")
        client.flush
        expect(read_packets(1)[0].buffer).to eql 'telemetry'
      end
    end

    describe "options" do
      it "sizes each client's ring with BUFFERED_RING_BYTES" do
        port = free_port
        start_server(port, 'BUFFERED_RING_BYTES' => ['65536'])
        connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        expect(read_interfaces[0].stream.read_channel.ring_bytes).to eql 65536
      end

      it "back pressures by default and honors BUFFERED_OVERFLOW" do
        port = free_port
        start_server(port)
        connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        expect(read_interfaces[0].stream.read_channel.overflow_policy).to eql :backpressure
        @interface.disconnect

        port = free_port
        start_server(port, 'BUFFERED_OVERFLOW' => ['drop_oldest'])
        connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        expect(read_interfaces[0].stream.read_channel.overflow_policy).to eql :drop_oldest
      end
    end

    describe "buffered_stats" do
      it "reports zeros with no clients" do
        port = free_port
        start_server(port)
        stats = @interface.buffered_stats
        expect(stats[:buffered]).to be false
        expect(stats[:clients]).to eql 0
        expect(stats[:drop_count]).to eql 0
        expect(stats[:stall_count]).to eql 0
      end

      it "sums the counters over every connected client" do
        port = free_port
        start_server(port)
        clients = 2.times.map { connect_client(port) }
        expect(wait_until { @interface.num_clients == 2 }).to be true
        clients.each do |client|
          client.write("0123456789")
          client.flush
        end
        read_packets(2)

        stats = @interface.buffered_stats
        expect(stats[:buffered]).to be true
        expect(stats[:clients]).to eql 2
        expect(stats[:bytes_read]).to eql 20
        expect(stats[:drop_count]).to eql 0  # TCP back pressures, never drops
        expect(stats[:stall_count]).to eql 0
        expect(stats[:ring_bytes]).to eql BufferedSocketStream::DEFAULT_RING_BYTES
      end
    end

    describe "fallbacks" do
      it "uses the stock stream with OPTION BUFFERED FALSE" do
        port = free_port
        @interface = TcpipServerInterface.new(port.to_s, port.to_s, '5', '5', 'burst')
        @interface.listen_address = '127.0.0.1'
        @interface.set_option('BUFFERED', ['FALSE'])
        expect(@interface.buffered?).to be false
        @interface.connect

        client = connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        stream = read_interfaces[0].stream
        expect(stream).to be_a TcpipSocketStream
        expect(stream).to_not be_a BufferedTcpipSocketStream

        client.write("stock")
        client.flush
        expect(read_packets(1)[0].buffer).to eql 'stock'
        expect(@interface.buffered_stats[:buffered]).to be false
      end

      it "uses the stock stream with COSMOS_NO_BUFFERED_IO" do
        port = free_port
        begin
          ENV['COSMOS_NO_BUFFERED_IO'] = '1'
          @interface = TcpipServerInterface.new(port.to_s, port.to_s, '5', '5', 'burst')
          @interface.listen_address = '127.0.0.1'
          expect(@interface.buffered?).to be false
          @interface.connect
          client = connect_client(port)
          expect(wait_until { @interface.num_clients == 1 }).to be true
          stream = read_interfaces[0].stream
          expect(stream).to_not be_a BufferedTcpipSocketStream

          client.write("stock")
          client.flush
          expect(read_packets(1)[0].buffer).to eql 'stock'
        ensure
          ENV.delete('COSMOS_NO_BUFFERED_IO')
        end
      end

      it "keeps the stock Ruby path for a socket that cannot be adopted" do
        # A double has no descriptor to adopt. Nothing may raise: the stream
        # falls back and the server carries on exactly as it does today, which
        # is what keeps spec/interfaces/tcpip_server_interface_spec.rb green.
        @interface = TcpipServerInterface.new('8888', '8888', '5', '5', 'burst')
        socket = double("socket")
        allow(socket).to receive(:closed?).and_return(false)
        stream = @interface.send(:build_client_stream, socket, socket)
        stream.connect
        expect(stream).to be_a BufferedTcpipSocketStream
        expect(stream.read_channel).to be_nil
        expect(stream.write_channel).to be_nil
        expect(stream.buffered?).to be false
        expect(stream.buffered_stats[:buffered]).to be false
        @interface = nil
      end
    end

    # read_interface_base stamps @read_raw_data_time with Time.now, which is
    # when the Ruby thread was scheduled, not when the bytes landed. The C++
    # reader stamped the real thing without the GVL; StreamInterface prefers it.
    describe "receive timestamps" do
      it "stamps the packet with the C++ receive time, not Time.now" do
        port = free_port
        start_server(port)
        client = connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true

        client.write("stamped")
        client.flush
        read_packets(1)
        client_interface = read_interfaces[0]
        kernel_time = client_interface.stream.last_read_time_f
        expect(kernel_time).to_not be_nil
        expect(client_interface.read_raw_data_time.to_f).to be_within(0.001).of(kernel_time)
      end

      # The whole point: under GVL starvation Time.now is late by however long
      # the hog held the lock, while the C++ timestamp is not. Asserted as
      # "earlier than now" rather than by a fixed margin so a fast machine that
      # never actually starves cannot fail it.
      it "is not skewed by a thread holding the GVL" do
        port = free_port
        start_server(port)
        client = connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true

        hog_running = true
        hog = Thread.new { hog_running = hog_running while hog_running }
        begin
          sleep 0.05
          client.write("late")
          client.flush
          read_packets(1, 30.0)
          client_interface = read_interfaces[0]
          expect(client_interface.read_raw_data_time.to_f)
            .to be_within(0.001).of(client_interface.stream.last_read_time_f)
          expect(client_interface.read_raw_data_time.to_f).to be <= Time.now.sys.to_f
        ensure
          hog_running = false
          hog.join(2)
          hog.kill if hog.alive?
        end
      end
    end

    # Regression: anything raising between accept and registration used to kill
    # the listen thread for good AND leak the accepted socket - it was never
    # registered, so disconnect could not reach it either. The server then
    # accepted nothing for the rest of the process's life while the peer sat
    # blocked writing into a receive queue nobody drained. (This is what hung
    # test/benchmarks/buffered_io_bench.rb server.)
    describe "a connection that cannot be set up" do
      it "keeps accepting after one connection fails" do
        allow(Logger.instance).to receive(:error)
        port = free_port
        start_server(port)

        # Fail exactly the first client's setup, then behave normally.
        calls = 0
        allow(@interface).to receive(:build_client_stream).and_wrap_original do |original, *args|
          calls += 1
          raise "synthetic setup failure" if calls == 1
          original.call(*args)
        end

        doomed = connect_client(port)
        # The failed connection is dropped, not registered, and the peer sees
        # the close rather than a socket that stays open forever.
        expect(wait_until { begin; doomed.read_nonblock(1); false; rescue EOFError; true; rescue IO::WaitReadable; false; rescue Exception; true; end }).to be true
        expect(@interface.num_clients).to eql 0

        # The listener is still alive: the whole point of the fix.
        client = connect_client(port)
        expect(wait_until { @interface.num_clients == 1 }).to be true
        client.write("survived")
        client.flush
        expect(read_packets(1)[0].buffer).to eql 'survived'
      end
    end

    describe "GVL starvation" do
      # The point of the whole exercise: with another Ruby thread hogging the
      # GVL the kernel receive queues still drain, because the draining is
      # done by C++ threads that never ask for it.
      it "drains every client while a Ruby thread hogs the GVL" do
        port = free_port
        start_server(port)
        clients = 3.times.map { connect_client(port) }
        expect(wait_until { @interface.num_clients == 3 }).to be true

        hog_running = true
        hog = Thread.new { hog_running = hog_running while hog_running }
        begin
          sleep 0.05
          # Kept small on purpose: every client.write here has to win the GVL
          # back from the hog too, which is exactly the latency the C++ readers
          # are not subject to.
          payload = 'T' * 1024
          clients.each do |client|
            10.times { client.write(payload) }
            client.flush
          end
          # The C++ readers have the data whether or not Ruby is scheduled
          expect(wait_until(30.0) do
            read_interfaces.length == 3 and
              read_interfaces.all? { |i| i.stream.read_channel.bytes_read >= 10240 }
          end).to be true
          # Nothing was lost: TCP back pressures, it does not drop
          read_interfaces.each do |interface|
            expect(interface.stream.read_channel.drop_count).to eql 0
          end
        ensure
          hog_running = false
          hog.join(2)
          hog.kill if hog.alive?
        end
      end
    end
  end

  else

  # Not silence: a spec file that simply vanishes when the extension is
  # missing makes the run look green for code nobody ran. See BufferedSpecs.
  BufferedSpecs.skipped_group('TcpipServerInterface (buffered clients)')

  end # RUBY_ENGINE == 'ruby' and BufferedIO.available?
end
