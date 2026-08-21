# encoding: ascii-8bit

# Copyright 2014 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/interfaces/interface'
require 'cosmos/interfaces/protocols/protocol'

module Cosmos
  class InterfaceTestProtocol < Protocol
    def initialize(added_data, stop_count = 0, packet_added_data = nil, packet_stop_count = 0)
      @added_data = added_data
      @packet_added_data = packet_added_data
      @stop_count = stop_count.to_i
      @packet_stop_count = packet_stop_count.to_i
    end

    def read_data(data)
      return :STOP if data == ''
      if @stop_count > 0
        @stop_count -= 1
        return :STOP
      end
      if @added_data
        return :DISCONNECT if @added_data == :DISCONNECT
        return data if @added_data == :STOP
        data << @added_data
        return data
      else
        return data
      end
    end
    alias write_data read_data

    def read_packet(packet)
      if @packet_stop_count > 0
        @packet_stop_count -= 1
        return :STOP
      end
      if @packet_added_data
        return :DISCONNECT if @packet_added_data == :DISCONNECT
        return packet if @packet_added_data == :STOP
        packet.buffer(false) << @packet_added_data
        return packet
      else
        return packet
      end
    end
    alias write_packet read_packet

    def post_write_interface(packet, data)
      $packet = packet
      $data = data
    end
  end

  describe Interface do
    describe "include API" do
      it "includes API" do
        expect(Interface.new.methods).to include :cmd
      end
    end

    describe "initialize" do
      it "initializes the instance variables" do
        i = Interface.new
        expect(i.name).to eql "Interface"
        expect(i.target_names).to eql []
        expect(i.thread).to be_nil
        expect(i.connect_on_startup).to be true
        expect(i.auto_reconnect).to be true
        expect(i.reconnect_delay).to eql 5.0
        expect(i.disable_disconnect).to be false
        expect(i.packet_log_writer_pairs).to eql []
        expect(i.routers).to eql []
        expect(i.read_count).to eql 0
        expect(i.write_count).to eql 0
        expect(i.bytes_read).to eql 0
        expect(i.bytes_written).to eql 0
        expect(i.num_clients).to eql 0
        expect(i.read_queue_size).to eql 0
        expect(i.write_queue_size).to eql 0
        expect(i.interfaces).to eql []
        expect(i.options).to be_empty
        expect(i.read_protocols).to be_empty
        expect(i.write_protocols).to be_empty
        expect(i.protocol_info).to be_empty
      end
    end

    describe "connected?" do
      it "raises an exception" do
        expect { Interface.new.connected? }.to raise_error(/connected\? not defined by Interface/)
      end
    end

    describe "read_allowed?" do
      it "is true" do
        expect(Interface.new.read_allowed?).to be true
      end
    end

    describe "write_allowed?" do
      it "is true" do
        expect(Interface.new.write_allowed?).to be true
      end
    end

    describe "write_raw_allowed?" do
      it "is true" do
        expect(Interface.new.write_raw_allowed?).to be true
      end
    end

    describe "read" do
      let(:interface) { Interface.new }

      it "raises unless connected" do
        class <<interface
          def connected?; false; end
        end
        expect { interface.read }.to raise_error(/Interface not connected/)
      end

      it "optionally logs raw data received from read_interface" do
        class <<interface
          def connected?; true; end
          def read_interface; data = "\x01\x02\x03\x04"; read_interface_base(data); data; end
        end
        interface.start_raw_logging
        packet = interface.read
        expect(packet.buffer).to eql "\x01\x02\x03\x04"
        expect(interface.read_count).to eq 1
        expect(interface.bytes_read).to eq 4
        filename = interface.raw_logger_pair.read_logger.filename
        interface.stop_raw_logging
        expect(File.read(filename)).to eq "\x01\x02\x03\x04"
      end

      it "aborts and doesn't log if no data is returned from read_interface" do
        class <<interface
          def connected?; true; end
          def read_interface; nil end
        end
        interface.start_raw_logging
        expect(interface.read).to be_nil
        # Filenames don't get assigned until logging starts
        expect(interface.raw_logger_pair.read_logger.filename).to be_nil
        expect(interface.bytes_read).to eq 0
      end

      it "counts raw bytes read" do
        $i = 0
        class <<interface
          def connected?; true; end
          def read_interface
            case $i
            when 0
              $i += 1
              data = "\x01\x02\x03\x04"
            when 1
              $i += 1
              data = "\x01\x02"
            when 2
              $i += 1
              data = "\x01\x02\x03\x04\x01\x02"
            end
            read_interface_base(data)
            data
          end
        end
        interface.read
        expect(interface.bytes_read).to eq 4
        interface.read
        expect(interface.bytes_read).to eq 6
        interface.read
        expect(interface.bytes_read).to eq 12
      end

      it "allows protocol read_data to manipulate data" do
        class <<interface
          def connected?; true; end
          def read_interface; data = "\x01\x02\x03\x04"; read_interface_base(data); data; end
        end
        interface.add_protocol(InterfaceTestProtocol, ["\x05"], :READ)
        interface.add_protocol(InterfaceTestProtocol, ["\x06"], :READ)
        interface.start_raw_logging
        packet = interface.read
        expect(packet.buffer).to eq "\x01\x02\x03\x04\x05\x06"
        expect(interface.read_count).to eq 1
        expect(interface.bytes_read).to eq 4
        filename = interface.raw_logger_pair.read_logger.filename
        interface.stop_raw_logging
        # Raw logging is still the original read_data return
        expect(File.read(filename)).to eq "\x01\x02\x03\x04"
      end

      it "aborts if protocol read_data returns :DISCONNECT" do
        class <<interface
          def connected?; true; end
          def read_interface; data = "\x01\x02\x03\x04"; read_interface_base(data); data; end
        end
        interface.add_protocol(InterfaceTestProtocol, [:DISCONNECT], :READ)
        interface.start_raw_logging
        packet = interface.read
        expect(packet).to be_nil
        expect(interface.read_count).to eq 0
        expect(interface.bytes_read).to eq 4
        filename = interface.raw_logger_pair.read_logger.filename
        interface.stop_raw_logging
        expect(File.read(filename)).to eq "\x01\x02\x03\x04"
      end

      it "gets more data if a protocol read_data returns :STOP" do
        class <<interface
          def connected?; true; end
          def read_interface; data = "\x01\x02\x03\x04"; read_interface_base(data); data; end
        end
        interface.add_protocol(InterfaceTestProtocol, [nil, 1], :READ)
        interface.start_raw_logging
        packet = interface.read
        expect(packet.buffer).to eq "\x01\x02\x03\x04"
        expect(interface.read_count).to eq 1
        expect(interface.bytes_read).to eq 8
        filename = interface.raw_logger_pair.read_logger.filename
        interface.stop_raw_logging
        expect(File.read(filename)).to eq "\x01\x02\x03\x04\x01\x02\x03\x04"
      end

      it "allows protocol read_packet to manipulate packet" do
        class <<interface
          def connected?; true; end
          def read_interface; data = "\x01\x02\x03\x04"; read_interface_base(data); data; end
        end
        interface.add_protocol(InterfaceTestProtocol, [nil, 0, "\x08"], :READ)
        packet = interface.read
        expect(packet.buffer).to eq "\x01\x02\x03\x04\x08"
        expect(interface.read_count).to eq 1
        expect(interface.bytes_read).to eq 4
      end

      it "aborts if protocol read_packet returns :DISCONNECT" do
        class <<interface
          def connected?; true; end
          def read_interface; data = "\x01\x02\x03\x04"; read_interface_base(data); data; end
          def post_read_packet(packet); nil; end
        end
        interface.add_protocol(InterfaceTestProtocol, [nil, 0, :DISCONNECT], :READ)
        packet = interface.read
        expect(packet).to be_nil
        expect(interface.read_count).to eq 0
        expect(interface.bytes_read).to eq 4
      end

      it "gets more data if protocol read_packet returns :STOP" do
        class <<interface
          def connected?; true; end
          def read_interface; data = "\x01\x02\x03\x04"; read_interface_base(data); data; end
        end
        interface.add_protocol(InterfaceTestProtocol, [nil, 0, nil, 1], :READ)
        packet = interface.read
        expect(packet.buffer).to eq "\x01\x02\x03\x04"
        expect(interface.read_count).to eq 1
        expect(interface.bytes_read).to eq 8
      end

      it "returns an unidentified packet" do
        class <<interface
          def connected?; true; end
          def read_interface; data = "\x01\x02\x03\x04"; read_interface_base(data); data; end
        end
        packet = interface.read
        expect(packet.target_name).to be_nil
        expect(packet.packet_name).to be_nil
      end
    end

    describe "write" do
      let(:interface) { Interface.new }
      let(:packet) { Packet.new('TGT', 'PKT', :BIG_ENDIAN, 'Packet', "\x01\x02\x03\x04") }

      it "raises unless connected" do
        class <<interface
          def connected?; false; end
        end
        expect { interface.write(packet)}.to raise_error(/Interface not connected/)
      end

      it "is single threaded" do
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); sleep 0.1; end
        end
        start_time = Time.now
        threads = []
        10.times do
          threads << Thread.new do
            interface.write(packet)
          end
        end
        threads.collect {|t| t.join }
        expect(Time.now - start_time).to be > 1
        expect(interface.write_count).to eq 10
        expect(interface.bytes_written).to eq 40
      end

      it "raises an error if not connected" do
        class <<interface
          def connected?; false; end
        end
        expect { interface.write(packet)}.to raise_error(/Interface not connected/)
        expect(interface.write_count).to be 0
        expect(interface.bytes_written).to be 0
      end

      it "disconnects if write_interface raises an exception" do
        class <<interface
          attr_accessor :disconnect_called
          def disconnect; @disconnect_called = true; end
          def connected?; true; end
          def write_interface(data); raise "Doom"; end
        end
        expect { interface.write(packet)}.to raise_error(/Doom/)
        expect(interface.disconnect_called).to be true
        expect(interface.write_count).to be 1
        expect(interface.bytes_written).to be 0
      end

      it "allows protocols write_packet to modify the packet" do
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); end
        end
        interface.add_protocol(InterfaceTestProtocol, [nil, 0, "\x06", 0], :WRITE)
        interface.add_protocol(InterfaceTestProtocol, [nil, 0, "\x05", 0], :WRITE)
        interface.start_raw_logging
        interface.write(packet)
        expect(interface.write_count).to eq 1
        expect(interface.bytes_written).to eq 6
        filename = interface.raw_logger_pair.write_logger.filename
        interface.stop_raw_logging
        expect(File.read(filename)).to eq "\x01\x02\x03\x04\x05\x06"
      end

      it "aborts if write_packet returns :DISCONNECT" do
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); end
        end
        interface.add_protocol(InterfaceTestProtocol, [nil, 0, :DISCONNECT, 0], :WRITE)
        interface.write(packet)
        expect(interface.write_count).to be 1
        expect(interface.bytes_written).to be 0
      end

      it "stops if write_packet returns :STOP" do
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); end
        end
        interface.add_protocol(InterfaceTestProtocol, [nil, 0, :STOP, 1], :WRITE)
        interface.write(packet)
        interface.write(packet)
        expect(interface.write_count).to be 2
        expect(interface.bytes_written).to be 4
      end

      it "allows protocol write_data to modify the data" do
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); end
        end
        interface.add_protocol(InterfaceTestProtocol, ["\x07", 0, nil, 0], :WRITE)
        interface.add_protocol(InterfaceTestProtocol, ["\x08", 0, nil, 0], :WRITE)
        interface.start_raw_logging
        interface.write(packet)
        expect(interface.write_count).to be 1
        expect(interface.bytes_written).to be 6
        filename = interface.raw_logger_pair.write_logger.filename
        interface.stop_raw_logging
        expect(File.read(filename)).to eq "\x01\x02\x03\x04\x08\x07"
      end

      it "aborts if write_data returns :DISCONNECT" do
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); end
        end
        interface.add_protocol(InterfaceTestProtocol, [:DISCONNECT, 0, nil, 0], :WRITE)
        interface.write(packet)
        expect(interface.write_count).to be 1
        expect(interface.bytes_written).to be 0
      end

      it "stops if write_data returns :STOP" do
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); end
        end
        interface.add_protocol(InterfaceTestProtocol, [:STOP, 1, nil, 0], :WRITE)
        interface.write(packet)
        interface.write(packet)
        expect(interface.write_count).to be 2
        expect(interface.bytes_written).to be 4
      end

      it "calls post_write_interface with the packet and data" do
        $packet = nil
        $data = nil
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); end
        end
        interface.add_protocol(InterfaceTestProtocol, [nil, 0, nil, 0], :WRITE)
        expect($packet).to be_nil
        expect($data).to be_nil
        interface.write(packet)
        expect(interface.write_count).to be 1
        expect(interface.bytes_written).to be 4
        expect($packet).to eq packet
        expect($data).to eq packet.buffer
      end
    end

    describe "write_raw" do
      let(:interface) { Interface.new }
      let(:data) { "\x01\x02\x03\x04" }

      it "raises unless connected" do
        class <<interface
          def connected?; false; end
        end
        expect { interface.write_raw(data)}.to raise_error(/Interface not connected/)
      end

      it "is single threaded" do
        class <<interface
          def connected?; true; end
          def write_interface(data); write_interface_base(data); sleep 0.1; end
        end
        start_time = Time.now
        threads = []
        10.times do
          threads << Thread.new do
            interface.write_raw(data)
          end
        end
        threads.collect {|t| t.join }
        expect(Time.now - start_time).to be > 1
        expect(interface.write_count).to eq 0
        expect(interface.bytes_written).to eq 40
      end
    end

    describe "copy_to" do
      it "copies the interface" do
        i = Interface.new
        i.name = 'TEST'
        i.target_names = ['TGT1','TGT2']
        i.thread = Thread.new {}
        i.connect_on_startup = false
        i.auto_reconnect = false
        i.reconnect_delay = 1.0
        i.disable_disconnect = true
        i.packet_log_writer_pairs = [1,2]
        i.routers = [3,4]
        i.read_count = 1
        i.write_count = 2
        i.bytes_read = 3
        i.bytes_written = 4
        i.num_clients = 5
        i.read_queue_size = 6
        i.write_queue_size = 7
        i.interfaces = [5,6]
        i.read_protocols = [1, 2]
        i.write_protocols = [3, 4]
        i.protocol_info = [[Protocol, [], :READ_WRITE]]

        i2 = Interface.new
        i.copy_to(i2)
        expect(i2.name).to eql 'TEST'
        expect(i2.target_names).to eql ['TGT1','TGT2']
        expect(i2.thread).to be_nil # Thread does not get copied
        expect(i2.connect_on_startup).to be false
        expect(i2.auto_reconnect).to be false
        expect(i2.reconnect_delay).to eql 1.0
        expect(i2.disable_disconnect).to be true
        expect(i2.packet_log_writer_pairs).to eql [1,2]
        expect(i2.routers).to eql [3,4]
        expect(i2.read_count).to eql 1
        expect(i2.write_count).to eql 2
        expect(i2.bytes_read).to eql 3
        expect(i2.bytes_written).to eql 4
        expect(i2.num_clients).to eql 0 # does not get copied
        expect(i2.read_queue_size).to eql 0 # does not get copied
        expect(i2.write_queue_size).to eql 0 # does not get copied
        expect(i2.interfaces).to eql [5,6]
        expect(i2.read_protocols).to_not be_empty
        expect(i2.write_protocols).to_not be_empty
        expect(i2.protocol_info).to eql [[Protocol, [], :READ_WRITE]]
        Cosmos.kill_thread(nil, i.thread)
      end

      # Copying the @options Hash only preserves what the OPTION line said.
      # Every option that is parsed into an ivar of its own - and that is most
      # of them - also has to be replayed through set_option, or a recreate
      # brings the interface back up at the class default for it.
      it "replays options through set_option so parsed state survives" do
        source = TcpipClientInterface.new('localhost', '8888', '8888', nil, nil, 'BURST')
        source.set_option('BUFFERED', ['FALSE'])
        source.set_option('BUFFERED_RING_BYTES', ['1048576'])
        expect(source.buffered?).to be false

        # A recreate builds a fresh instance from new connect parameters, so it
        # starts out buffered exactly as if no OPTION had ever been given.
        target = TcpipClientInterface.new('localhost', '9999', '9999', nil, nil, 'BURST')
        expect(target.instance_variable_get(:@buffered)).to be_nil

        source.copy_to(target)
        expect(target.options['BUFFERED']).to eql ['FALSE']
        expect(target.buffered?).to be false
        expect(target.instance_variable_get(:@buffered_options)[:ring_bytes]).to eql 1048576
      end

      it "does not abort the copy when an option cannot be replayed" do
        allow(Logger).to receive(:warn)
        source = Interface.new
        source.name = 'TEST'
        # An option the target refuses. The old behavior was to lose every
        # parsed option silently; losing just this one is strictly better than
        # failing the whole recreate.
        source.instance_variable_get(:@options)['BOGUS'] = ['VALUE']

        target = Interface.new
        allow(target).to receive(:set_option).and_raise(ArgumentError, 'nope')
        expect { source.copy_to(target) }.to_not raise_error
        expect(target.name).to eql 'TEST'
        expect(target.options['BOGUS']).to eql ['VALUE']
      end
    end

  end
end

