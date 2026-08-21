# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos/streams/buffered_serial_stream'

# Everything here needs a real tty. openpty gives us one on any POSIX box,
# which is why these specs do not self skip the way spec/io/posix_serial_driver_spec.rb
# has to (it needs a physical /dev/ttyS0). Skipped when the C++ extension is
# not built or buffered I/O is switched off with COSMOS_NO_BUFFERED_IO:
# spec/streams/serial_stream_spec.rb covers that path and is run in both modes.
begin
  require 'pty'
  require 'io/console'
  PTY_AVAILABLE = true
rescue LoadError
  PTY_AVAILABLE = false
end

module Cosmos

  if RUBY_ENGINE == 'ruby' and !Gem.win_platform? and PTY_AVAILABLE and BufferedIO.available?

    # A loopback serial link: we hold the pty master, the code under test opens
    # the slave *by name* through the stock PosixSerialDriver, so every bit of
    # the termios configuration is the production path.
    module PtyHelpers
      def open_pty
        master, slave = PTY.open
        @ptys << [master, slave]
        [master, slave]
      end

      def close_ptys
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
        @ptys = []
      end

      def wait_until(timeout = 2.0)
        start = Time.now.sys
        while (Time.now.sys - start) < timeout
          return true if yield
          sleep 0.01
        end
        false
      end
    end

    describe "BufferedIO::StreamChannel on a tty" do
      include PtyHelpers

      before(:each) do
        @ptys = []
        @channel = nil
      end

      after(:each) do
        begin
          @channel.disconnect(0) if @channel
        rescue Exception
        end
        close_ptys
      end

      # Adopts the raw pty slave directly. PTY.open hands back a *cooked*
      # terminal, so raw! stands in for the termios configuration that
      # PosixSerialDriver does in the tests further down.
      def build_channel(ring_bytes = nil)
        master, slave = open_pty
        slave.raw!
        @channel = BufferedIO::StreamChannel.adopt(slave.fileno, ring_bytes)
        [@channel, master]
      end

      describe "adopt" do
        it "adopts a tty descriptor" do
          channel, _master = build_channel
          expect(channel.connected?).to be true
          expect(channel.tty?).to be true
          expect(channel.ring_bytes).to eql BufferedIO::StreamChannel::DEFAULT_RING_BYTES
        end

        it "still adopts a socket as a non tty channel" do
          # The M1 socket path must not be weakened by teaching adopt about ttys
          server = TCPServer.new('127.0.0.1', 0)
          client = TCPSocket.new('127.0.0.1', server.addr[1])
          accepted = server.accept
          begin
            @channel = BufferedIO::StreamChannel.adopt(accepted.fileno)
            expect(@channel.tty?).to be false
            client.write('tcp still works')
            expect(@channel.read(2, 100)).to eql 'tcp still works'
          ensure
            Cosmos.close_socket(accepted)
            Cosmos.close_socket(client)
            Cosmos.close_socket(server)
          end
        end

        it "refuses a descriptor that is neither a socket nor a tty" do
          file = File.open(File::NULL, 'r')
          begin
            expect { BufferedIO::StreamChannel.adopt(file.fileno) }.to raise_error(ArgumentError)
          ensure
            file.close
          end
        end

        it "duplicates the descriptor so Ruby can close its own copy" do
          channel, master = build_channel
          master.write('still here')
          expect(wait_until { channel.buffered_bytes > 0 }).to be true
          @ptys[0][1].close
          expect(channel.read(1, 100)).to eql 'still here'
        end

        it "defaults to back pressure, not to dropping" do
          # A byte stream feeds framing protocols. See doc/buffered_io_design.md.
          channel, _master = build_channel
          expect(channel.overflow_policy).to eql :backpressure
        end
      end

      describe "read" do
        it "delivers bytes written to the other end of the link" do
          channel, master = build_channel
          master.write("\x01\x02\x03\x04")
          expect(channel.read(2, 100)).to eql "\x01\x02\x03\x04"
          expect(channel.bytes_read).to eql 4
        end

        it "preserves ordering across a large transfer" do
          channel, master = build_channel
          records = 2048
          writer = Thread.new do
            records.times { |index| master.write([index].pack('N')) }
          end
          received = ''.force_encoding('ASCII-8BIT')
          while received.bytesize < (records * 4)
            chunk = channel.read(10, 1024 * 1024)
            break if chunk.nil?
            received << chunk
          end
          writer.join(10)
          expect(received.bytesize).to eql(records * 4)
          expect(received.unpack('N*')).to eql (0...records).to_a
          expect(channel.drop_count).to eql 0
        end

        it "returns nil on timeout" do
          channel, _master = build_channel
          start = Time.now.sys
          expect(channel.read(0.1)).to be_nil
          expect(Time.now.sys - start).to be < 2.0
        end

        it "carries the receive time with the bytes" do
          channel, master = build_channel
          before = Time.now.sys.to_f
          master.write('stamped')
          data, time = channel.read_with_time(2, 100)
          expect(data).to eql 'stamped'
          expect(time).to be >= (before - 1.0)
          expect(time).to be <= (Time.now.sys.to_f + 1.0)
        end

        it "is interrupted by disconnect from another thread" do
          # shutdown(2) is a no-op on a tty and closing the fd under a parked
          # reader is a use after free race, so the self-pipe wakeup is the
          # only thing that can end this read. This example is what proves it.
          channel, _master = build_channel
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
          channel, _master = build_channel
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
          channel, master = build_channel
          counter = 0
          spinner = Thread.new { 200.times { counter += 1; sleep 0.001 } }
          sleep 0.05
          master.write('go')
          expect(channel.read(2, 100)).to eql 'go'
          expect(counter).to be > 0
          spinner.kill
          spinner.join(2)
        end

        it "raises IOError once disconnected" do
          channel, _master = build_channel
          channel.disconnect(0)
          expect { channel.read(1) }.to raise_error(IOError)
        end
      end

      describe "overflow" do
        # The smallest ring the channel will build: one read chunk. Asking for
        # less is rounded up, which is why every example here uses it.
        SMALL_RING = 65536

        it "never drops under back pressure" do
          # A full ring simply stops the reader. Nothing we buffered is lost;
          # the back pressure lands where it does today (the tty buffer, and
          # RTS/CTS if it is wired), which is what keeps framing intact.
          channel, master = build_channel(SMALL_RING)
          expect(channel.ring_bytes).to eql SMALL_RING
          total = 8 * SMALL_RING
          writer = Thread.new { 8.times { master.write('A' * SMALL_RING) } }
          received = 0
          while received < total
            chunk = channel.read(10, SMALL_RING)
            break if chunk.nil?
            received += chunk.bytesize
          end
          writer.join(10)
          expect(received).to eql total
          expect(channel.drop_count).to eql 0
        end

        it "counts the stalls that back pressure causes" do
          channel, master = build_channel(SMALL_RING)
          # Nobody reads, so the reader fills the ring and then parks
          writer = Thread.new { 4.times { master.write('B' * SMALL_RING) } }
          expect(wait_until(5) { channel.stall_count > 0 }).to be true
          expect(channel.drop_count).to eql 0
          expect(channel.buffered_bytes).to eql SMALL_RING
          # Drain so the blocked pty writer can finish
          channel.read(1, SMALL_RING) while channel.buffered_bytes > 0
          writer.kill unless writer.join(5)
        end

        it "drops the oldest bytes and counts them when asked to" do
          channel, master = build_channel(SMALL_RING)
          channel.overflow_policy = :drop_oldest
          expect(channel.overflow_policy).to eql :drop_oldest
          # The reader never stops under a drop policy, so these never block
          16.times { master.write('C' * SMALL_RING) }
          expect(wait_until(5) { channel.drop_count > 0 }).to be true
          expect(channel.buffered_bytes).to be <= SMALL_RING
        end

        it "drops the newest bytes when asked to" do
          channel, master = build_channel(SMALL_RING)
          channel.overflow_policy = :drop_newest
          expect(channel.overflow_policy).to eql :drop_newest
          16.times { master.write('D' * SMALL_RING) }
          expect(wait_until(5) { channel.drop_count > 0 }).to be true
          expect(channel.buffered_bytes).to eql SMALL_RING
        end
      end

      describe "write" do
        it "sends through the writer thread" do
          channel, master = build_channel
          channel.write('command')
          expect(channel.flush(2)).to be true
          expect(master.readpartial(100)).to eql 'command'
          expect(channel.bytes_written).to eql 7
        end

        it "preserves ordering" do
          channel, master = build_channel
          100.times { |index| channel.write('%04d' % index) }
          expect(channel.flush(5)).to be true
          received = ''
          received << master.readpartial(4096) while received.length < 400
          expect(received).to eql((0...100).map { |index| '%04d' % index }.join)
        end

        # The WRITE queue, not the read ring. Under the default :block policy a
        # writer waits for space; under :raise it gets OverflowError instead,
        # so a tool that must never sit on a full queue can say so. This is the
        # tty's own path through that C++ code, and the one where a full queue
        # is most likely: a tty output buffer is a few kilobytes, so a master
        # nobody reads backs the writer thread up almost immediately.
        it "raises when the write queue overflows with the raise policy" do
          channel, _master = build_channel # nothing ever reads the master
          channel.write_policy = :raise
          channel.write_high_water = 4096
          expect(channel.write_policy).to eql :raise
          expect {
            10000.times { channel.write('s' * 4096) }
          }.to raise_error(BufferedIO::OverflowError)
        end
      end

      describe "process teardown" do
        it "does not hang at exit with a reader parked in the kernel" do
          # The VM teardown end proc has to stop the C++ threads. If the
          # self-pipe wakeup were broken this child would hang forever.
          script = <<-RUBY
            $LOAD_PATH.unshift(#{File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'lib')).inspect})
            require 'cosmos/io/buffered_io'
            require 'pty'
            require 'io/console'
            master, slave = PTY.open
            slave.raw!
            channel = Cosmos::BufferedIO::StreamChannel.adopt(slave.fileno)
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

    describe BufferedSerialStream do
      include PtyHelpers

      before(:each) do
        @ptys = []
        @stream = nil
      end

      after(:each) do
        begin
          @stream.disconnect if @stream
        rescue Exception
        end
        close_ptys
      end

      # The production path: PosixSerialDriver opens the pty slave by name and
      # does all of the termios work, then the channel adopts the fd.
      def build_stream(read_timeout = 2.0, options = {})
        master, slave = open_pty
        @stream = BufferedSerialStream.new(slave.path, slave.path, 9600, :NONE, 1,
                                           10.0, read_timeout, :NONE, 8, [], options)
        [@stream, master]
      end

      describe "buffering by default" do
        it "adopts the port the stock driver configured" do
          stream, _master = build_stream
          expect(stream.buffered?).to be true
          expect(stream.read_channel).to be_a BufferedIO::StreamChannel
          expect(stream.read_channel.tty?).to be true
          expect(stream.connected?).to be true
          expect(stream.buffered_stats[:buffered]).to be true
        end

        it "shares one channel when the read and write ports are the same" do
          stream, _master = build_stream
          expect(stream.write_channel).to be stream.read_channel
        end

        it "uses a separate channel per port when they differ" do
          write_master, write_slave = open_pty
          read_master, read_slave = open_pty
          @stream = BufferedSerialStream.new(write_slave.path, read_slave.path, 9600,
                                             :NONE, 1, 10.0, 2.0)
          expect(@stream.read_channel).to_not be_nil
          expect(@stream.write_channel).to_not be_nil
          expect(@stream.write_channel).to_not be @stream.read_channel
          # Nothing reads the write port's ring, so it must not back pressure
          expect(@stream.write_channel.overflow_policy).to eql :drop_oldest
          expect(@stream.read_channel.overflow_policy).to eql :backpressure

          read_master.write('telemetry')
          expect(@stream.read).to eql 'telemetry'
          @stream.write('command')
          expect(@stream.flush(2)).to be true
          expect(write_master.readpartial(100)).to eql 'command'
        end

        it "reads bytes written to the other end of the link" do
          stream, master = build_stream
          master.write("\x01\x02\x03\x04")
          expect(stream.read).to eql "\x01\x02\x03\x04"
          expect(stream.buffered_stats[:bytes_read]).to eql 4
        end

        it "delivers everything when Ruby is late to the read" do
          stream, master = build_stream
          256.times { |index| master.write([index].pack('N')) }
          sleep 0.3 # the C++ reader drains the tty while Ruby does nothing
          received = ''.force_encoding('ASCII-8BIT')
          while received.bytesize < (256 * 4)
            chunk = stream.read
            break if chunk.nil? or chunk.length == 0
            received << chunk
          end
          expect(received.unpack('N*')).to eql (0...256).to_a
          expect(stream.buffered_stats[:drop_count]).to eql 0
        end

        it "writes through the writer thread" do
          stream, master = build_stream
          stream.write('to the port')
          expect(stream.flush(2)).to be true
          expect(master.readpartial(100)).to eql 'to the port'
        end

        it "stamps the receive time without the GVL" do
          stream, master = build_stream
          before = Time.now.sys.to_f
          master.write('stamped')
          stream.read
          expect(stream.last_read_time).to be_a Time
          expect(stream.last_read_time_f).to be >= (before - 1.0)
          expect(stream.last_read_time_f).to be <= (Time.now.sys.to_f + 1.0)
        end
      end

      describe "stock semantics" do
        it "raises Timeout::Error on a read timeout exactly like PosixSerialDriver" do
          stock_master, stock_slave = open_pty
          stock = SerialStream.new(stock_slave.path, stock_slave.path, 9600, :NONE, 1, 10.0, 0.1)
          begin
            expect { stock.read }.to raise_error(Timeout::Error)
          ensure
            stock.disconnect
          end
          expect(stock_master).to_not be_nil

          stream, _master = build_stream(0.1)
          expect(stream.read_channel).to_not be_nil
          expect { stream.read }.to raise_error(Timeout::Error)
        end

        it "returns an empty string from read_nonblock when nothing is waiting" do
          stream, _master = build_stream
          expect(stream.read_nonblock).to eql ''
        end

        it "raises when reading a write only stream" do
          master, slave = open_pty
          expect(master).to_not be_nil
          @stream = BufferedSerialStream.new(slave.path, nil, 9600, :NONE, 1, 10.0, 2.0)
          expect { @stream.read }.to raise_error("Attempt to read from write only stream")
        end

        it "raises when writing a read only stream" do
          master, slave = open_pty
          expect(master).to_not be_nil
          @stream = BufferedSerialStream.new(nil, slave.path, 9600, :NONE, 1, 10.0, 2.0)
          expect { @stream.write('x') }.to raise_error("Attempt to write to read only stream")
        end

        it "is disconnected after disconnect and stays that way" do
          stream, _master = build_stream
          expect(stream.connected?).to be true
          stream.disconnect
          expect(stream.connected?).to be false
          expect { stream.disconnect }.to_not raise_error
          expect(stream.connected?).to be false
        end
      end

      describe "read thread lifecycle" do
        # The stock answer here is Timeout::Error, not an empty read and not
        # IOError, and it is worth spelling out why because it differs from
        # every other transport: PosixSerialDriver#read parks in IO.fast_select,
        # closing the port makes select(2) fail EBADF, fast_select maps every
        # SystemCallError to nil, and a nil select result is what
        # PosixSerialDriver reports as Timeout::Error. The companion example
        # below runs the identical scenario through the stock SerialStream so
        # this is asserted against the real thing rather than against a belief
        # about it.
        it "unblocks a parked read when another thread disconnects, the way the stock stream does" do
          stream, _master = build_stream(nil) # nil read timeout - blocks forever
          error = nil
          thread = Thread.new do
            begin
              stream.read
            rescue Exception => raised
              error = raised
            end
          end
          sleep 0.3
          expect(thread.alive?).to be true
          stream.disconnect
          expect(thread.join(5)).to_not be_nil
          expect(error).to be_a Timeout::Error
          expect(stream.connected?).to be false
        end

        it "matches the stock SerialStream when a parked read is disconnected" do
          master, slave = open_pty
          stock = SerialStream.new(slave.path, slave.path, 9600, :NONE, 1,
                                   10.0, nil, :NONE, 8, [])
          error = nil
          thread = Thread.new do
            begin
              stock.read
            rescue Exception => raised
              error = raised
            end
          end
          sleep 0.3
          expect(thread.alive?).to be true
          stock.disconnect
          expect(thread.join(5)).to_not be_nil
          # Same class the buffered example above asserts. If this ever changes,
          # the buffered path has to change with it.
          expect(error).to be_a Timeout::Error
          master.close rescue nil
        end

        it "is unblocked by Cosmos.kill_thread" do
          allow(Logger).to receive(:warn)
          stream, _master = build_stream(nil)
          thread = Thread.new do
            begin
              stream.read
            rescue Exception
            end
          end
          sleep 0.3
          expect(thread.alive?).to be true
          Cosmos.kill_thread(nil, thread)
          expect(thread.alive?).to be false
        end
      end

      describe "options" do
        it "sizes the ring" do
          stream, _master = build_stream(2.0, :ring_bytes => 128 * 1024)
          expect(stream.read_channel.ring_bytes).to eql(128 * 1024)
        end

        it "selects an overflow policy" do
          stream, _master = build_stream(2.0, :overflow_policy => :drop_oldest)
          expect(stream.read_channel.overflow_policy).to eql :drop_oldest
        end
      end

      describe "fallbacks" do
        it "uses the stock driver when the port is not a real POSIX tty" do
          # Exactly what spec/streams/serial_stream_spec.rb does: never probe a
          # double with an unexpected message, just fall back.
          driver = double("driver")
          expect(driver).to receive(:read).and_return('stock')
          expect(SerialDriver).to receive(:new).and_return(driver)
          stream = BufferedSerialStream.new('COM1', 'COM1', 9600, :NONE, 1, nil, nil)
          expect(stream.buffered?).to be false
          expect(stream.read_channel).to be_nil
          expect(stream.buffered_stats[:buffered]).to be false
          expect(stream.read).to eql 'stock'
        end

        it "uses the stock driver with COSMOS_NO_BUFFERED_IO" do
          master, slave = open_pty
          begin
            ENV['COSMOS_NO_BUFFERED_IO'] = '1'
            @stream = BufferedSerialStream.new(slave.path, slave.path, 9600, :NONE, 1, 10.0, 2.0)
            expect(@stream.buffered?).to be false
            expect(@stream.read_channel).to be_nil
          ensure
            ENV.delete('COSMOS_NO_BUFFERED_IO')
          end
          master.write('stock path')
          expect(@stream.read).to eql 'stock path'
          @stream.write('back')
          expect(master.readpartial(100)).to eql 'back'
        end
      end

      describe "resource churn" do
        it "does not leak descriptors or memory across 100 connect/disconnect cycles" do
          master, slave = open_pty
          expect(master).to_not be_nil
          # Warm up so the first cycle's lazy allocations are not counted
          3.times do
            stream = BufferedSerialStream.new(slave.path, slave.path, 9600, :NONE, 1, 10.0, 0.1)
            stream.disconnect
          end
          GC.start
          before_fds = Dir.glob('/dev/fd/*').size
          before_rss = `ps -o rss= -p #{Process.pid}`.to_i

          100.times do
            stream = BufferedSerialStream.new(slave.path, slave.path, 9600, :NONE, 1, 10.0, 0.1)
            expect(stream.read_channel).to_not be_nil
            stream.disconnect
          end
          GC.start
          after_fds = Dir.glob('/dev/fd/*').size
          after_rss = `ps -o rss= -p #{Process.pid}`.to_i

          # Each cycle opens a tty, dups it into the channel and creates a wake
          # pipe. If any of those were not released this would climb by 400.
          expect(after_fds - before_fds).to be <= 4
          # Each live channel holds a 16 MiB ring. 100 leaked rings would be
          # 1.6 GB; released rings keep this flat (KiB from ps).
          expect(after_rss - before_rss).to be < 64 * 1024
        end
      end
    end

  else

  # Not silence: a spec file that simply vanishes when its requirements are
  # missing makes the run look green for code nobody ran. Serial needs a real
  # tty as well as the extension, so it may be skipped for a reason of its own.
  BufferedSpecs.skipped_group('BufferedSerialStream',
                              PTY_AVAILABLE ? nil : 'no PTY support on this platform')

  end # RUBY_ENGINE == 'ruby' and PTY and BufferedIO.available?
end
