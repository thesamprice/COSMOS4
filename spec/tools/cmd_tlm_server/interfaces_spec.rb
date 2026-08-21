# encoding: ascii-8bit

# Copyright 2014 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'tempfile'
require 'cosmos'
require 'cosmos/tools/cmd_tlm_server/interfaces'
require 'cosmos/tools/cmd_tlm_server/cmd_tlm_server_config'

module Cosmos

  describe Interfaces do
    describe "map_all_targets" do
      it "complains about an unknown interface" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE MY_INT interface.rb'
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        expect { interfaces.map_all_targets("BLAH") }.to raise_error("Unknown interface: BLAH")
        tf.unlink
      end

      it "maps all targets to the interface" do
        System.targets.each do |name, target|
          target.interface = nil
          expect(target.interface).to be_nil
        end
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE MY_INT interface.rb'
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        interfaces.map_all_targets("MY_INT")
        System.targets.each do |name, target|
          expect(target.interface.name).to eql 'MY_INT'
        end
        tf.unlink
      end
    end

    describe "map_target" do
      it "complains about an unknown interface" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE MY_INT interface.rb'
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        expect { interfaces.map_target("COSMOS","BLAH") }.to raise_error("Unknown interface: BLAH")
        tf.unlink
      end

      it "complains about an unknown target" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE MY_INT interface.rb'
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        expect { interfaces.map_target("BLAH","MY_INT") }.to raise_error("Unknown target: BLAH")
        tf.unlink
      end


      it "maps a target to the interface" do
        System.targets.each do |name, target|
          target.interface = nil
          expect(target.interface).to be_nil
        end
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE MY_INT interface.rb'
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        interfaces.map_target("SYSTEM","MY_INT")
        expect(System.targets["SYSTEM"].interface.name).to eql "MY_INT"
        tf.unlink
      end
    end

    describe "start" do
      it "connects each interface" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE MY_INT interface.rb'
        tf.close
        capture_io do |stdout|
          interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
          interfaces.all['MY_INT'].connect_on_startup = false

          allow_any_instance_of(Interface).to receive(:connected?)
          allow_any_instance_of(Interface).to receive(:connect)
          allow_any_instance_of(Interface).to receive(:disconnect)
          allow_any_instance_of(Interface).to receive(:read)

          interfaces.all['MY_INT'].connect_on_startup = true
          interfaces.start

          expect(stdout.string).to match("Creating thread for interface MY_INT")

          interfaces.stop
          sleep 0.1
        end
        tf.unlink
      end
    end

    describe "stop" do
      it "disconnects each interface" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE MY_INT interface.rb'
        tf.close
        capture_io do |stdout|
          interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))

          allow_any_instance_of(Interface).to receive(:connected?).and_return(false, false, true, false)
          allow_any_instance_of(Interface).to receive(:connect)
          allow_any_instance_of(Interface).to receive(:disconnect)
          allow_any_instance_of(Interface).to receive(:read)

          interfaces.all['MY_INT'].connect_on_startup = true
          interfaces.start
          sleep 0.5
          expect(interfaces.state("MY_INT")).to eql "ATTEMPTING"
          sleep 0.1
          expect(interfaces.state("MY_INT")).to eql "CONNECTED"
          sleep 0.1
          interfaces.stop
          sleep 0.5
          expect(interfaces.state("MY_INT")).to eql "DISCONNECTED"

          expect(stdout.string).to match("Disconnected from interface MY_INT")

          sleep 0.1
        end
        tf.unlink
      end
    end

    describe "connect" do
      it "complains about unknown interfaces" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE MY_INT interface.rb'
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        expect { interfaces.connect("TEST") }.to raise_error("Unknown interface: TEST")
        tf.unlink
      end

      it "connects a interface" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE DEST1 tcpip_client_interface.rb localhost 8888 8888 5 5 burst'
        tf.puts 'INTERFACE DEST2 tcpip_client_interface.rb localhost 8888 8888 5 5 burst'
        tf.puts 'ROUTER MY_ROUTER tcpip_client_interface.rb localhost 8888 8888 5 5 burst'
        tf.puts 'ROUTE DEST1'
        tf.puts 'ROUTE DEST2'
        tf.close
        capture_io do |stdout|
          server = TCPServer.new('127.0.0.1', 8888)
          def server.graceful_kill
          end
          clients = []
          pipe_reader, pipe_writer = IO.pipe
          server_thread = Thread.new do
            loop do
              clients << server.accept
              begin
                clients << server.accept_nonblock
              rescue Errno::EAGAIN, Errno::ECONNABORTED, Errno::EINTR, Errno::EWOULDBLOCK
                read_ready, _ = IO.select([server, pipe_reader])
                if read_ready.include?(pipe_reader)
                  break
                else
                  retry
                end
              end
            end
          end

          config = CmdTlmServerConfig.new(tf.path)
          interfaces = Interfaces.new(config)
          expect(config.interfaces['DEST1'].routers[0].name).to eql "MY_ROUTER"
          expect(config.interfaces['DEST2'].routers[0].name).to eql "MY_ROUTER"
          interfaces.connect("DEST1")
          sleep 0.2
          expect(stdout.string).to match("Connecting to DEST1")
          interfaces.disconnect("DEST1")
          interfaces.connect("DEST1",'localhost',8888,8888,6,6,'length')
          sleep 0.2
          expect(config.interfaces['DEST1'].routers[0].name).to eql "MY_ROUTER"
          expect(config.interfaces['DEST2'].routers[0].name).to eql "MY_ROUTER"
          expect(stdout.string).to match("Disconnected from interface DEST1")
          expect(stdout.string).to match("Connecting to DEST1")
          interfaces.disconnect("DEST1")
          interfaces.stop

          pipe_writer.write('.')
          Cosmos.kill_thread(server, server_thread)
          server.close
          clients.each do |c|
            c.close
          end
        end
        tf.unlink
        sleep(0.2)
      end
    end

    describe "names" do
      it "lists all the interface names" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE INTERFACE1 interface.rb'
        tf.puts 'INTERFACE INTERFACE2 interface.rb'
        tf.puts 'INTERFACE INTERFACE3 interface.rb'
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        expect(interfaces.names).to eql %w(INTERFACE1 INTERFACE2 INTERFACE3)
        tf.unlink
      end
    end

    describe "get_info" do
      # The ninth element is the buffered counters. Everything else about
      # get_info predates this work; what is asserted here is that the shape
      # arrives intact - String keys, the full BufferedIO.empty_stats key set,
      # and 'clients' for a server - because the CmdTlmServer status display
      # indexes into it by name and a missing key is a crash rather than a
      # blank cell.
      def build_interfaces(*lines)
        tf = Tempfile.new('unittest')
        lines.each { |line| tf.puts line }
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        [interfaces, tf]
      end

      # The abstract Interface deliberately raises from connected?, and
      # get_info asks for the state first. Stubbing it keeps these examples
      # about the ninth element rather than about the base class's contract.
      def build_stock_interface
        interfaces, tf = build_interfaces('INTERFACE MY_INT interface.rb')
        allow(interfaces.all['MY_INT']).to receive(:connected?).and_return(false)
        [interfaces, tf]
      end

      # BufferedIO.empty_stats keys, as Strings
      def expected_keys
        BufferedIO.empty_stats.keys.map(&:to_s)
      end

      it "appends the buffered counters without disturbing the first eight" do
        interfaces, tf = build_stock_interface
        begin
          info = interfaces.get_info('MY_INT')
          expect(info.length).to eql 9
          # The eight that have always been there
          expect(info[0]).to eql 'DISCONNECTED'
          expect(info[1, 7]).to eql [0, 0, 0, 0, 0, 0, 0]
          expect(info[8]).to be_a Hash
        ensure
          tf.unlink
        end
      end

      # A stock Interface has no buffered backend at all, and the promise is
      # that it answers zeros rather than nothing - so a display never has to
      # special case it.
      it "reports the zeroed shape for an interface with no buffered backend" do
        interfaces, tf = build_stock_interface
        begin
          buffered = interfaces.get_info('MY_INT')[8]
          expect(buffered.keys.sort).to eql expected_keys.sort
          expect(buffered['buffered']).to be false
          expect(buffered['drop_count']).to eql 0
          expect(buffered['stall_count']).to eql 0
          # String keys, so JSON-RPC and a direct API call agree
          expect(buffered.keys.all? { |key| key.is_a?(String) }).to be true
        ensure
          tf.unlink
        end
      end

      it "reports the zeroed shape rather than {} when an interface raises" do
        interfaces, tf = build_stock_interface
        begin
          interface = interfaces.all['MY_INT']
          allow(interface).to receive(:buffered_stats).and_raise('counters exploded')
          buffered = interfaces.get_info('MY_INT')[8]
          # Not {}: a caller promised 'buffered' and 'drop_count' blows up on a
          # bare Hash, and an empty one is indistinguishable from "no counters
          # exist", which this method documents as reporting zeros.
          expect(buffered.keys.sort).to eql expected_keys.sort
          expect(buffered['buffered']).to be false
        ensure
          tf.unlink
        end
      end

      if RUBY_ENGINE == 'ruby' and BufferedIO.available?
        # Against a REAL buffered interface with a REAL client attached, not a
        # double: the aggregation across clients is the part with arithmetic in
        # it, and it is what the operator reads to answer "is any client
        # backing up".
        it "aggregates the counters of a server's connected clients" do
          allow(Logger.instance).to receive(:info)
          probe = TCPServer.new('127.0.0.1', 0)
          port = probe.addr[1]
          probe.close

          interfaces, tf = build_interfaces(
            "INTERFACE MY_INT tcpip_server_interface.rb #{port} #{port} 5 5 burst",
            '  OPTION LISTEN_ADDRESS 127.0.0.1')
          interface = interfaces.all['MY_INT']
          clients = []
          begin
            interface.connect
            2.times { clients << TCPSocket.new('127.0.0.1', port) }
            start = Time.now.sys
            sleep 0.01 while interface.num_clients < 2 and (Time.now.sys - start) < 5.0

            clients.each { |client| client.write('hello'); client.flush }
            start = Time.now.sys
            while interfaces.get_info('MY_INT')[8]['bytes_read'] < 10 and
                  (Time.now.sys - start) < 5.0
              sleep 0.01
            end

            buffered = interfaces.get_info('MY_INT')[8]
            expect(buffered['buffered']).to be true
            # Aggregation: 'clients' counts the buffered ones, bytes_read sums
            # across them, ring_bytes is the worst (largest) rather than a sum
            # because it is a per client size.
            expect(buffered['clients']).to eql 2
            expect(buffered['bytes_read']).to eql 10
            expect(buffered['drop_count']).to eql 0
            expect(buffered['ring_bytes']).to eql BufferedIO::Transport::DEFAULT_RING_BYTES
            expect((expected_keys + ['clients']).sort).to eql buffered.keys.sort
          ensure
            clients.each { |client| Cosmos.close_socket(client) }
            begin
              interface.disconnect
            rescue Exception
            end
            tf.unlink
          end
        end
      end
    end

    describe "clear_counters" do
      it "clears all interface counters" do
        tf = Tempfile.new('unittest')
        tf.puts 'INTERFACE INTERFACE1 interface.rb'
        tf.puts 'INTERFACE INTERFACE2 interface.rb'
        tf.puts 'INTERFACE INTERFACE3 interface.rb'
        tf.close
        interfaces = Interfaces.new(CmdTlmServerConfig.new(tf.path))
        interfaces.all.each do |name, interface|
          interface.bytes_written = 100
          interface.bytes_read = 200
          interface.write_count = 10
          interface.read_count = 20
        end
        interfaces.clear_counters
        interfaces.all.each do |name, interface|
          expect(interface.bytes_written).to eql 0
          expect(interface.bytes_read).to eql 0
          expect(interface.write_count).to eql 0
          expect(interface.read_count).to eql 0
        end
        tf.unlink
      end
    end
  end
end

