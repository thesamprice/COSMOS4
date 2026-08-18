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
          expect { PosixSerialDriver.new(@port, 9600) }.to raise_error(/locked by another process or interface/)
          driver.close
        end

        it "raises when the port is held by another application" do
          other = File.open(@port, File::RDWR | File::NONBLOCK)
          other.flock(File::LOCK_EX | File::LOCK_NB)
          begin
            expect { PosixSerialDriver.new(@port, 9600) }.to raise_error(/locked by another process or interface/)
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
          expect { SerialStream.new(@port, @port, 9600, :NONE, 1, 10.0, nil) }.to raise_error(/locked by another process or interface/)
          stream.disconnect
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
