# encoding: ascii-8bit

# Copyright 2026 thesamprice/COSMOS4
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

if RbConfig::CONFIG['target_os'] !~ /mswin|mingw|cygwin/i and RUBY_ENGINE == 'ruby'

  require 'spec_helper'
  require 'pty'
  require 'cosmos/io/posix_serial_driver'
  require 'cosmos/streams/serial_stream'

  module Cosmos

    describe PosixSerialDriver do
      describe "port locking" do
        before(:each) do
          @master, @slave = PTY.open
          @port = @slave.path
        end

        after(:each) do
          @master.close rescue nil
          @slave.close rescue nil
          ENV.delete('COSMOS_NO_SERIAL_LOCK')
        end

        # Two layers refuse a second open, and which one answers first is a
        # platform detail. On Linux TIOCEXCL makes open(2) itself fail with
        # EBUSY, so the driver never reaches its own flock check; on macOS a
        # pty does not enforce TIOCEXCL at all and the flock check is what
        # answers. Either is the port being locked.
        def expect_port_locked
          yield
          fail "expected the port to be locked, but the open succeeded"
        rescue Errno::EBUSY
          # TIOCEXCL, enforced by the kernel before flock was consulted
        rescue RuntimeError => error
          raise error unless error.message =~ /locked by another process or interface/
        end

        it "locks the port on open" do
          driver = PosixSerialDriver.new(@port, 9600)
          probe = File.open(@port, File::RDWR | File::NONBLOCK)
          begin
            expect(probe.flock(File::LOCK_EX | File::LOCK_NB)).to be false
          ensure
            probe.close
          end
          driver.close
        end

        it "raises when the port is already held by a driver" do
          driver = PosixSerialDriver.new(@port, 9600)
          expect_port_locked { PosixSerialDriver.new(@port, 9600) }
          driver.close
        end

        it "raises when the port is held by another application" do
          other = File.open(@port, File::RDWR | File::NONBLOCK)
          other.flock(File::LOCK_EX | File::LOCK_NB)
          begin
            expect_port_locked { PosixSerialDriver.new(@port, 9600) }
          ensure
            other.close
          end
        end

        it "releases the lock on close" do
          driver = PosixSerialDriver.new(@port, 9600)
          driver.close
          driver2 = PosixSerialDriver.new(@port, 9600)
          driver2.close
        end

        it "does not lock itself out when read and write name the same port" do
          # SerialStream shares one driver when the names match, so this must
          # open cleanly and a second stream on the same port must not.
          stream = SerialStream.new(@port, @port, 9600, :NONE, 1, 10.0, nil)
          expect_port_locked { SerialStream.new(@port, @port, 9600, :NONE, 1, 10.0, nil) }
          stream.disconnect
        end

        # A failure part way through configuration used to leave the port open
        # and locked with nothing holding a reference to it, so the retry the
        # operator makes next fails with "locked by another process" and blames
        # the wrong thing entirely. A bad STRUCT key is the realistic way in.
        it "releases the port when initialization fails" do
          expect {
            PosixSerialDriver.new(@port, 9600, :NONE, 1, 10.0, nil, :NONE, 8,
                                  [["iflag", "NOT_A_REAL_FLAG"]])
          }.to raise_error(NameError)

          # The port must be usable again immediately.
          probe = File.open(@port, File::RDWR | File::NONBLOCK)
          begin
            expect(probe.flock(File::LOCK_EX | File::LOCK_NB)).to eql 0
            probe.flock(File::LOCK_UN)
          ensure
            probe.close
          end
          driver = PosixSerialDriver.new(@port, 9600)
          driver.close
        end

        # The default is locked. This is the deliberate opt-out for a machine
        # that shares a tty with another application.
        it "takes no lock at all when COSMOS_NO_SERIAL_LOCK is set" do
          ENV['COSMOS_NO_SERIAL_LOCK'] = '1'
          first = PosixSerialDriver.new(@port, 9600)
          second = PosixSerialDriver.new(@port, 9600)
          begin
            probe = File.open(@port, File::RDWR | File::NONBLOCK)
            begin
              # Nothing took the flock, so an outside application can too.
              expect(probe.flock(File::LOCK_EX | File::LOCK_NB)).to eql 0
              probe.flock(File::LOCK_UN)
            ensure
              probe.close
            end
          ensure
            second.close
            first.close
          end
        end

        it "still allows the buffered channel's dup'd fd" do
          # The C++ channel adopts a dup(2) of the driver's fd; a dup shares
          # the open file description and therefore the flock.
          driver = PosixSerialDriver.new(@port, 9600)
          handle = driver.instance_variable_get(:@handle)
          duped = handle.dup
          begin
            expect(duped.flock(File::LOCK_EX | File::LOCK_NB)).to eql 0
          ensure
            duped.close
          end
          driver.close
        end
      end
    end
  end
end
