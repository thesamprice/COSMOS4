# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

# The GVL hog benchmark for the buffered C++ I/O backends.
#
# A forked sender blasts sequenced, timestamped records over loopback TCP at
# line rate while this process runs a Ruby thread that hogs the GVL in a tight
# loop (decom, logging, GUI painting and script execution all look like this to
# an interface thread). The receiver is either the stock TcpipSocketStream or
# the BufferedTcpipSocketStream.
#
# Reported per run:
#   MB/s        - throughput actually consumed by Ruby
#   gaps        - missing records. TCP must never gap: the stream channels
#                 default to :backpressure, not to a drop policy.
#   kernel Q    - high water mark of the *kernel* socket receive queue
#                 (SO_NREAD / FIONREAD) sampled by the reader. This is the
#                 queue that silently drops datagrams for UDP and overruns the
#                 tty buffer for serial; on TCP it is sender back-pressure and
#                 latency. Buffered keeps it at zero until the ring fills.
#   ring high   - buffered only: backlog absorbed into the visible C++ ring
#   drops       - buffered only: counted, never silent
#   recv skew   - error in the receive time the interface would stamp on the
#                 data: stock can only call Time.now once it wins the GVL,
#                 while the buffered channel carries the kernel receive time
#                 with the bytes.
#   gvl wait    - percentage of the reader's wall time spent waiting to be
#                 handed the GVL. Only reported when the optional gvltools gem
#                 is available (gem install gvltools); it is what proves the
#                 bottleneck is scheduling and not I/O.
#
# Usage:
#   env COSMOS_USERPATH=$(pwd)/demo bundle exec ruby test/benchmarks/buffered_io_bench.rb
#
# Runs in well under a minute.

require 'socket'

# Optional: real GVL instrumentation built on Ruby's internal thread event
# hooks (RUBY_INTERNAL_THREAD_EVENT_READY / RESUMED).
begin
  require 'gvltools'
  GVLTools::LocalTimer.enable
  GVL_TOOLS = GVLTools::LocalTimer.enabled?
rescue LoadError
  GVL_TOOLS = false
end
$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'lib')))
require 'cosmos'
require 'cosmos/streams/tcpip_socket_stream'
require 'cosmos/streams/buffered_tcpip_socket_stream'

module Cosmos
  class BufferedIoBench
    RECORD_SIZE = 1024
    READ_TIMEOUT = 5.0
    MEGABYTE = 1024.0 * 1024.0
    # macOS: SO_NREAD. Linux: FIONREAD via ioctl.
    SO_NREAD = 0x1020
    FIONREAD = 0x541B

    # Payload that fits inside the default 16 MiB ring, and one that does not
    SCENARIOS = [
      ['burst 8 MiB', 8192],
      ['sustained 32 MiB', 32768]
    ]

    def initialize
      @results = []
    end

    def run
      puts "Buffered I/O GVL hog benchmark"
      puts "  ruby        #{RUBY_VERSION} (#{RUBY_PLATFORM})"
      puts "  extension   #{BufferedIO.extension_loaded? ? 'loaded' : 'NOT LOADED'}"
      puts "  record      #{RECORD_SIZE} bytes (4 byte sequence + 8 byte send time)"
      puts ""

      SCENARIOS.each do |name, records|
        [false, true].each do |hog|
          [:stock, :buffered].each do |backend|
            @results << measure(name, records, backend, hog)
          end
        end
      end
      report
    end

    private

    def measure(scenario, records, backend, hog)
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      pid = fork do
        server.close
        blast(port, records)
        exit!(0)
      end
      socket = server.accept
      server.close

      stream = if backend == :buffered
                 BufferedTcpipSocketStream.new(nil, socket, nil, READ_TIMEOUT)
               else
                 TcpipSocketStream.new(nil, socket, nil, READ_TIMEOUT)
               end
      stream.connect

      hog_running = true
      hog_thread = nil
      if hog
        # Pure Ruby tight loop: never yields the GVL voluntarily
        hog_thread = Thread.new { hog_running = hog_running while hog_running }
        sleep 0.05
      end

      expected = 0
      gaps = 0
      # Parsed with a cursor rather than String#slice!, which is quadratic and
      # would measure the benchmark's own parser instead of the backend
      buffer = ''.force_encoding('ASCII-8BIT')
      cursor = 0
      total_bytes = 0
      max_kernel = 0
      reads = 0
      # Two different errors, kept apart on purpose (the same split
      # SerialDropBench uses, and for the same reason):
      #   head - the error of the timestamp the chunk actually carries, taken
      #          against the FIRST record in that chunk. This is the apples to
      #          apples number and the one to quote: stock stamps Time.now once
      #          it wins the GVL, the buffered channel carries the kernel
      #          receive time of that first byte. Nothing about chunk size
      #          enters into it.
      #   abs  - mean |error| charged to every record. One chunk carries one
      #          timestamp, so a record 60 KiB into a 64 KiB chunk is stamped
      #          with the arrival time of the chunk's first byte and looks
      #          early by however long the chunk took to arrive. Charging that
      #          to every record - which is what the single skew figure did -
      #          scales the reported error with the read size rather than with
      #          the backend, and it could go negative, which a "skew" plainly
      #          cannot. It is an artifact of per chunk stamping, so it is
      #          reported separately instead of mixed into the headline.
      head_sum = 0.0
      head_max = 0.0
      head_count = 0
      abs_sum = 0.0
      abs_max = 0.0
      abs_count = 0
      deadline = Time.now.sys + 60.0
      GVLTools::LocalTimer.reset if GVL_TOOLS
      gvl_start = GVL_TOOLS ? GVLTools::LocalTimer.monotonic_time : 0
      start = Time.now.sys

      begin
        while expected < records and Time.now.sys < deadline
          queued = kernel_queued(socket)
          max_kernel = queued if queued and queued > max_kernel

          data = stream.read
          reads += 1
          break if data.nil? or data.length == 0
          # The time this data would be stamped with: the buffered channel
          # carries the kernel receive time, the stock stream can only ask the
          # clock now that Ruby finally got the GVL.
          stamped = if backend == :buffered and stream.last_read_time_f
                      stream.last_read_time_f
                    else
                      Time.now.sys.to_f
                    end
          total_bytes += data.length
          buffer << data
          head = true

          while (buffer.bytesize - cursor) >= RECORD_SIZE
            sequence = buffer.byteslice(cursor, 4).unpack1('N')
            sent = buffer.byteslice(cursor + 4, 8).unpack1('G')
            cursor += RECORD_SIZE
            if sequence != expected
              # Only forward jumps are missing records. A sequence below what
              # was expected is a reorder, and adding a negative to a gap count
              # silently cancels out real losses.
              gaps += (sequence - expected) if sequence > expected
              expected = sequence
            end
            expected += 1
            error = stamped - sent
            if head
              head = false
              head_count += 1
              head_sum += error
              head_max = error if error > head_max
            end
            magnitude = error.abs
            abs_sum += magnitude
            abs_max = magnitude if magnitude > abs_max
            abs_count += 1
          end
          if cursor > 0 and cursor == buffer.bytesize
            buffer = ''.force_encoding('ASCII-8BIT')
            cursor = 0
          end
        end
      rescue EOFError, Timeout::Error
        # Sender finished or stalled - report what we got
      end
      elapsed = Time.now.sys - start
      gvl_wait = GVL_TOOLS ? (GVLTools::LocalTimer.monotonic_time - gvl_start) / 1_000_000_000.0 : nil

      stats = stream.respond_to?(:buffered_stats) ? stream.buffered_stats : {}
      hog_running = false
      if hog_thread
        hog_thread.join(2)
        hog_thread.kill if hog_thread.alive?
      end
      stream.disconnect
      begin
        Process.kill('TERM', pid)
      rescue Exception
      end
      begin
        Process.wait(pid)
      rescue Exception
      end

      {
        :scenario => scenario,
        :backend => backend,
        :hog => hog,
        :elapsed => elapsed,
        :bytes => total_bytes,
        :records => expected,
        :gaps => gaps,
        :max_kernel => max_kernel,
        :ring_high_water => stats[:high_water] || 0,
        :drops => stats[:drop_count] || 0,
        :head_mean => head_count > 0 ? (head_sum / head_count) : 0.0,
        :head_max => head_max,
        :abs_mean => abs_count > 0 ? (abs_sum / abs_count) : 0.0,
        :abs_max => abs_max,
        :gvl_wait => gvl_wait,
        :reads => reads
      }
    end

    # Child process: connect and write sequenced, timestamped records at line rate
    def blast(port, records)
      socket = TCPSocket.new('127.0.0.1', port)
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      filler = 'A' * (RECORD_SIZE - 12)
      batch = 64
      buffer = ''.force_encoding('ASCII-8BIT')
      records.times do |sequence|
        buffer << [sequence].pack('N') << [Time.now.to_f].pack('G') << filler
        if ((sequence + 1) % batch) == 0
          socket.write(buffer)
          buffer = ''.force_encoding('ASCII-8BIT')
        end
      end
      socket.write(buffer) if buffer.length > 0
      socket.flush
      sleep 1 # let the receiver drain before the FIN
      socket.close
    rescue Exception
      # The receiver went away - nothing to do
    end

    # Bytes sitting in the kernel receive queue right now
    def kernel_queued(socket)
      if RUBY_PLATFORM =~ /darwin/
        socket.getsockopt(Socket::SOL_SOCKET, SO_NREAD).int
      else
        buffer = [0].pack('L')
        socket.ioctl(FIONREAD, buffer)
        buffer.unpack1('L')
      end
    rescue Exception
      nil
    end

    def report
      header = "%-17s %-9s %-4s %8s %8s %6s %12s %11s %7s %9s %9s %7s %9s"
      puts header % ['scenario', 'backend', 'hog', 'seconds', 'MB/s', 'gaps',
                     'kernel Q', 'ring high', 'drops', 'head ms', 'head max',
                     'abs ms', 'reads', 'gvl wait']
      puts '-' * 150
      @results.each do |result|
        megabytes = result[:bytes] / MEGABYTE
        rate = result[:elapsed] > 0 ? megabytes / result[:elapsed] : 0.0
        gvl = result[:gvl_wait] ? ('%.0f%%' % (100.0 * result[:gvl_wait] / result[:elapsed])) : 'n/a'
        puts header % [result[:scenario], result[:backend], result[:hog] ? 'yes' : 'no',
                       '%.2f' % result[:elapsed], '%.1f' % rate, result[:gaps],
                       result[:max_kernel], result[:ring_high_water], result[:drops],
                       '%.1f' % (result[:head_mean] * 1000.0),
                       '%.1f' % (result[:head_max] * 1000.0),
                       '%.1f' % (result[:abs_mean] * 1000.0), result[:reads], gvl]
      end
      puts ''
      puts "  head ms - error of the timestamp the chunk carries, measured"
      puts "            against the first record in it. The honest comparison"
      puts "            and the one to quote: no chunk size enters into it."
      puts "  abs ms  - mean |error| charged to every record. One chunk carries"
      puts "            one timestamp, so later records in a big chunk look"
      puts "            early by however long the chunk took to arrive - an"
      puts "            artifact of per chunk stamping, not of the backend."
      puts ''

      SCENARIOS.each do |name, _records|
        stock = @results.find { |r| r[:scenario] == name and r[:hog] and r[:backend] == :stock }
        buffered = @results.find { |r| r[:scenario] == name and r[:hog] and r[:backend] == :buffered }
        next unless stock and buffered
        puts "#{name}, GVL hog running:"
        puts "  kernel receive queue high water: stock #{stock[:max_kernel]} bytes vs "\
             "buffered #{buffered[:max_kernel]} bytes"
        puts "    (this is what silently drops for UDP and overruns the tty for serial)"
        puts "  C++ ring absorbed #{buffered[:ring_high_water]} bytes, "\
             "#{buffered[:drops]} dropped (counted, never silent)"
        puts "  sequence gaps: stock #{stock[:gaps]}, buffered #{buffered[:gaps]}"
        puts "  receive time error (chunk head): stock mean "\
             "#{'%.1f' % (stock[:head_mean] * 1000)} ms / "\
             "max #{'%.1f' % (stock[:head_max] * 1000)} ms vs buffered mean "\
             "#{'%.1f' % (buffered[:head_mean] * 1000)} ms / max "\
             "#{'%.1f' % (buffered[:head_max] * 1000)} ms"
        if stock[:gvl_wait] and buffered[:gvl_wait]
          puts "  reader time spent waiting for the GVL: stock "\
               "#{'%.0f' % (100.0 * stock[:gvl_wait] / stock[:elapsed])}% of wall vs buffered "\
               "#{'%.0f' % (100.0 * buffered[:gvl_wait] / buffered[:elapsed])}% "\
               "(#{stock[:reads]} vs #{buffered[:reads]} reads)"
        end
        puts "  throughput: stock #{'%.1f' % (stock[:bytes] / MEGABYTE / stock[:elapsed])} MB/s vs "\
             "buffered #{'%.1f' % (buffered[:bytes] / MEGABYTE / buffered[:elapsed])} MB/s"
        puts ''
      end
    end
  end
end

Cosmos::BufferedIoBench.new.run
