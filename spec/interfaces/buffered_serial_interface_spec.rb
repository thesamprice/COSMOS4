# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/interfaces/serial_interface'

# openpty gives every POSIX box a real tty, so unlike
# spec/interfaces/serial_interface_spec.rb (which needs a physical port and
# only exercises the Windows path) these examples run the whole interface end
# to end. Skipped when the C++ extension is not built or buffered I/O is
# switched off with COSMOS_NO_BUFFERED_IO - serial_interface_spec.rb covers
# that path and is run in both modes.
begin
  require 'pty'
  BUFFERED_SERIAL_PTY = true
rescue LoadError
  BUFFERED_SERIAL_PTY = false
end

module Cosmos

  if RUBY_ENGINE == 'ruby' and !Gem.win_platform? and BUFFERED_SERIAL_PTY and BufferedIO.available?

    describe SerialInterface do
      before(:each) do
        @ptys = []
        @interface = nil
      end

      after(:each) do
        begin
          @interface.disconnect if @interface
        rescue Exception
        end
        @ptys.each do |master, slave|
          begin
            slave.close unless slave.closed?
          rescue Exception
          end
          begin
            master.close unless master.closed?
          rescue Exception
          end
        end
      end

      def open_pty
        master, slave = PTY.open
        @ptys << [master, slave]
        [master, slave]
      end

      # A serial interface talking to a pty we hold the other end of
      def build_interface(read_timeout = '2.0', protocol = 'burst')
        master, slave = open_pty
        @interface = SerialInterface.new(slave.path, slave.path, '9600', 'NONE', '1',
                                         '10.0', read_timeout, protocol)
        [@interface, master]
      end

      describe "buffering by default" do
        it "connects through a BufferedSerialStream" do
          interface, _master = build_interface
          expect(interface.buffered?).to be true
          interface.connect
          expect(interface.stream).to be_a BufferedSerialStream
          expect(interface.stream.read_channel).to be_a BufferedIO::StreamChannel
          expect(interface.stream.read_channel.tty?).to be true
          expect(interface.connected?).to be true
        end

        it "reads packets with the stock counters" do
          interface, master = build_interface
          interface.connect
          expect(interface.read_count).to eql 0
          expect(interface.bytes_read).to eql 0

          packet = nil
          thread = Thread.new { packet = interface.read }
          master.write("\x00\x01\x02\x03")
          thread.join(5)
          expect(interface.read_count).to eql 1
          expect(interface.bytes_read).to eql 4
          expect(packet.buffer).to eql "\x00\x01\x02\x03"
        end

        it "keeps framing intact for a length protocol while Ruby is busy" do
          # The framing argument for defaulting serial to back pressure: a
          # Length protocol resyncs badly if bytes go missing mid stream. The
          # C++ reader drains the tty while the Ruby thread is asleep, so
          # nothing is lost and every frame parses.
          master, slave = open_pty
          @interface = SerialInterface.new(slave.path, slave.path, '9600', 'NONE', '1',
                                           '10.0', '5.0', 'length', 0, 16, 2)
          @interface.connect
          frames = 50
          frames.times do |index|
            payload = ('%02d' % (index % 100)) * 4 # 8 bytes
            # length_value_offset is 2, so the field carries the payload length
            master.write([payload.length].pack('n') << payload)
          end
          sleep 0.3 # Ruby does nothing at all while the port fills
          received = []
          frames.times { received << @interface.read.buffer }
          expect(received.length).to eql frames
          frames.times do |index|
            expect(received[index][2..-1]).to eql(('%02d' % (index % 100)) * 4)
          end
          expect(@interface.stream.buffered_stats[:drop_count]).to eql 0
        end

        it "writes commands through the writer thread" do
          interface, master = build_interface
          interface.connect
          packet = Packet.new('tgt', 'pkt')
          packet.buffer = "\x00\x01\x02\x03"
          interface.write(packet)
          interface.stream.flush(2)
          expect(master.readpartial(100)).to eql "\x00\x01\x02\x03"
          expect(interface.write_count).to eql 1
          expect(interface.bytes_written).to eql 4
        end

        it "surfaces the buffered counters" do
          interface, master = build_interface
          interface.connect
          master.write('counted')
          interface.read
          stats = interface.stream.buffered_stats
          expect(stats[:buffered]).to be true
          expect(stats[:bytes_read]).to eql 7
          expect(stats[:drop_count]).to eql 0
          expect(stats[:ring_bytes]).to eql BufferedIO::StreamChannel::DEFAULT_RING_BYTES
        end
      end

      describe "read thread lifecycle" do
        it "returns nil from read when disconnected on another thread" do
          interface, _master = build_interface(nil)
          interface.connect
          result = :none
          thread = Thread.new { result = interface.read }
          sleep 0.3
          expect(thread.alive?).to be true
          interface.disconnect
          expect(thread.join(5)).to_not be_nil
          expect(result).to be_nil
          expect(interface.connected?).to be false
        end

        it "is unblocked by Cosmos.kill_thread" do
          allow(Logger).to receive(:warn)
          interface, _master = build_interface(nil)
          interface.connect
          thread = Thread.new do
            begin
              interface.read
            rescue Exception
            end
          end
          sleep 0.3
          expect(thread.alive?).to be true
          Cosmos.kill_thread(nil, thread)
          expect(thread.alive?).to be false
        end

        it "releases the channels on disconnect and can reconnect" do
          interface, master = build_interface
          interface.connect
          channel = interface.stream.read_channel
          interface.disconnect
          expect(channel.connected?).to be false
          interface.connect
          expect(interface.stream.read_channel).to_not be_nil
          expect(interface.stream.read_channel).to_not be channel
          master.write('reconnected')
          expect(interface.read.buffer).to eql 'reconnected'
        end
      end

      describe "options" do
        it "sizes the ring with BUFFERED_RING_BYTES" do
          interface, _master = build_interface
          interface.set_option('BUFFERED_RING_BYTES', ['262144'])
          interface.connect
          expect(interface.stream.read_channel.ring_bytes).to eql(256 * 1024)
        end

        it "selects a drop policy with BUFFERED_OVERFLOW" do
          interface, _master = build_interface
          interface.set_option('BUFFERED_OVERFLOW', ['drop_oldest'])
          interface.connect
          expect(interface.stream.read_channel.overflow_policy).to eql :drop_oldest
        end

        it "still supports the stock serial options" do
          interface, _master = build_interface
          interface.set_option('FLOW_CONTROL', ['NONE'])
          interface.set_option('DATA_BITS', ['8'])
          interface.connect
          expect(interface.stream.instance_variable_get(:@flow_control)).to eql :NONE
          expect(interface.stream.instance_variable_get(:@data_bits)).to eql 8
        end
      end

      describe "fallbacks" do
        it "uses the stock stream with OPTION BUFFERED FALSE" do
          interface, master = build_interface
          interface.set_option('BUFFERED', ['FALSE'])
          expect(interface.buffered?).to be false
          interface.connect
          expect(interface.stream).to be_a SerialStream
          expect(interface.stream).to_not be_a BufferedSerialStream
          master.write('stock')
          expect(interface.read.buffer).to eql 'stock'
        end

        it "uses the stock stream with COSMOS_NO_BUFFERED_IO" do
          interface, master = build_interface
          begin
            ENV['COSMOS_NO_BUFFERED_IO'] = '1'
            expect(interface.buffered?).to be false
            interface.connect
            expect(interface.stream).to_not be_a BufferedSerialStream
          ensure
            ENV.delete('COSMOS_NO_BUFFERED_IO')
          end
          master.write('stock')
          expect(interface.read.buffer).to eql 'stock'
        end
      end

      describe "connect, disconnect, connect" do
        # An auto-reconnecting interface does exactly this every time a link
        # drops, so the second connect has to build a brand new stream with
        # brand new channels rather than reuse (or leak) the stopped ones.
        # UdpInterface and TcpipClientInterface have the same example; serial
        # is the one where the port is reopened by name, which is a different
        # code path again.
        it "releases the channels on disconnect and reconnects with new ones" do
          interface, master = build_interface
          interface.connect
          first = interface.stream.read_channel
          expect(first).to_not be_nil
          master.write('before')
          expect(interface.read.buffer).to eql 'before'

          interface.disconnect
          expect(first.connected?).to be false
          expect(interface.connected?).to be false

          interface.connect
          second = interface.stream.read_channel
          expect(second).to_not be_nil
          expect(second).to_not be first
          expect(second.connected?).to be true
          expect(interface.stream.buffered_stats[:buffered]).to be true
          master.write('after')
          expect(interface.read.buffer).to eql 'after'
        end

        # The counters belong to the channels that were just released, so a
        # reconnected interface starts from zero rather than reporting the
        # previous link's traffic as its own.
        it "starts the counters over on reconnect" do
          interface, master = build_interface
          interface.connect
          master.write('counted')
          interface.read
          expect(interface.stream.buffered_stats[:bytes_read]).to eql 7

          interface.disconnect
          interface.connect
          stats = interface.stream.buffered_stats
          expect(stats[:buffered]).to be true
          expect(stats[:bytes_read]).to eql 0
          expect(interface.stream.last_read_time).to be_nil
        end
      end

      describe "OPTION BUFFERED_OVERFLOW" do
        # End to end: the OPTION line an operator writes has to reach the C++
        # channel's policy, through set_option, @buffered_options and the
        # stream constructor.
        it "reaches the C++ channel" do
          interface, _master = build_interface
          interface.set_option('BUFFERED_OVERFLOW', ['drop_newest'])
          interface.connect
          expect(interface.stream.read_channel.overflow_policy).to eql :drop_newest
        end

        it "leaves back pressure in place by default" do
          # Dropping bytes out of the middle of a serial byte stream
          # desynchronizes framing, and back pressure is what keeps RTS/CTS
          # working. See doc/buffered_io_design.md.
          interface, _master = build_interface
          interface.connect
          expect(interface.stream.read_channel.overflow_policy).to eql :backpressure
        end
      end
    end

  end # RUBY_ENGINE == 'ruby' and PTY and BufferedIO.available?
end
