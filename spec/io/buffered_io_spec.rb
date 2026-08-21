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
require 'cosmos/interfaces/udp_interface'
require 'cosmos/streams/buffered_tcpip_socket_stream'
require 'socket'

module Cosmos

  # This file runs in BOTH modes on purpose: the module's own behavior - what
  # it logs and which configurations it accepts - must not depend on whether
  # the C++ extension was built or on the COSMOS_NO_BUFFERED_IO opt-out.
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
  end
end
