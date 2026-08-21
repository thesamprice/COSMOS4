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
require 'fcntl'

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
require 'cosmos/streams/serial_stream'
require 'cosmos/streams/buffered_serial_stream'
require 'cosmos/io/udp_sockets'
begin
  require 'pty'
  PTY_AVAILABLE = true
rescue LoadError
  PTY_AVAILABLE = false
end

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

  # The drop proof.
  #
  # TCP cannot lose data - the sender is flow controlled, so the M1 benchmark
  # above measures latency and receive time skew. UDP has no flow control at
  # all: when the receiving Ruby thread is not scheduled, SO_RCVBUF fills and
  # the kernel throws datagrams away without telling anybody. That is the
  # failure this whole extension exists to fix, and sequence gaps are how it
  # shows up in real telemetry.
  #
  # A forked blaster sends N sequenced, timestamped datagrams over loopback
  # while this process runs a Ruby thread that hogs the GVL. SO_RCVBUF on the
  # receiver is shrunk so the stock backend loses deterministically rather than
  # depending on how fast the machine happens to be.
  #
  # Reported per run:
  #   gaps        - missing sequence numbers. The headline. Stock: kernel drops.
  #                 Buffered: zero, unless the C++ ring itself overflowed, and
  #                 then only as many as drop_count says.
  #   kernel drop - "dropped due to full socket buffers" delta from
  #                 netstat -s -p udp. Silent loss, made visible.
  #   ring drop   - buffered only: datagrams the C++ ring dropped. Counted,
  #                 queryable, never silent.
  #   recv skew   - error in the receive time the interface would stamp on the
  #                 datagram. The buffered channel carries the time the kernel
  #                 handed the datagram over; stock can only call Time.now once
  #                 Ruby finally wins the GVL.
  class UdpDropBench
    DATAGRAM_SIZE = 1024
    READ_TIMEOUT = 2.0
    # Small enough that a GVL starved Ruby reader cannot keep up. This is the
    # queue that silently drops - the whole point of the exercise.
    RECEIVE_BUFFER_BYTES = 64 * 1024

    # name, datagrams, C++ ring size in datagrams, offered rate per second.
    #
    # The rate is paced rather than "as fast as the loop goes" so both backends
    # face an identical offered load: the difference in gaps is then purely the
    # receiver's ability to drain, not how the sender happened to be scheduled.
    # The first scenario is sized to fit entirely in the ring (buffered should
    # gap zero); the second deliberately does not, so the loss shows up in
    # drop_count where it can be seen.
    SCENARIOS = [
      ['50k @ 25k/s', 50_000, 65_536, 25_000],
      ['50k @ 25k/s, 512 ring', 50_000, 512, 25_000]
    ]

    def initialize
      @results = []
    end

    def run
      puts "UDP drop benchmark (the milestone 2 headline)"
      puts "  ruby         #{RUBY_VERSION} (#{RUBY_PLATFORM})"
      puts "  extension    #{BufferedIO.extension_loaded? ? 'loaded' : 'NOT LOADED'}"
      puts "  datagram     #{DATAGRAM_SIZE} bytes (4 byte sequence + 8 byte send time)"
      puts "  SO_RCVBUF    #{RECEIVE_BUFFER_BYTES} bytes on the receiver"
      puts ""

      SCENARIOS.each do |name, datagrams, ring, rate|
        [false, true].each do |hog|
          [:stock, :buffered].each do |backend|
            @results << measure(name, datagrams, ring, rate, backend, hog)
          end
        end
      end
      report
    end

    private

    # Kernel counter for datagrams thrown away because a socket queue was full
    # The kernel's own count of datagrams it threw away because the receive
    # buffer was full. This is the loss that is otherwise completely invisible
    # - no error, no exception, nothing in the application at all.
    #
    # Parsed out of `netstat -s -p udp`, whose wording is BSD/macOS specific.
    # Linux reports the same thing in a different format entirely ("packet
    # receive errors" from netstat -su, or RcvbufErrors in /proc/net/snmp), so
    # the match simply fails there and every caller reports 'n/a' rather than a
    # wrong number. The gap count next to it is the platform independent
    # measure and carries the argument on its own.
    def kernel_drops
      return nil unless RUBY_PLATFORM =~ /darwin|bsd/
      output = `netstat -s -p udp 2>/dev/null`
      match = output[/(\d+) dropped due to full socket buffers/, 1]
      match ? match.to_i : nil
    rescue Exception
      nil
    end

    def measure(scenario, datagrams, ring, rate, backend, hog)
      socket = UDPSocket.new
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, RECEIVE_BUFFER_BYTES)
      socket.bind('127.0.0.1', 0)
      port = socket.addr[1]

      channel = nil
      if backend == :buffered
        # Exactly what UdpInterface#connect does: hand the bound descriptor to
        # the C++ reader thread, which never touches a Ruby API.
        channel = BufferedIO::DatagramChannel.adopt(socket.fileno, ring, 256 * 1024 * 1024)
      end

      hog_running = true
      hog_thread = nil
      if hog
        # Pure Ruby tight loop: never yields the GVL voluntarily. Started
        # before the blaster so the entire transfer happens under starvation.
        hog_thread = Thread.new { hog_running = hog_running while hog_running }
        sleep 0.05
      end

      # The child reports how many datagrams it actually got onto the wire, so
      # a local ENOBUFS is never miscounted as receiver side loss.
      report_read, report_write = IO.pipe
      pid = fork do
        socket.close
        report_read.close
        blast(port, datagrams, rate, report_write)
        exit!(0)
      end
      report_write.close

      expected = 0
      highest = -1
      gaps = 0
      received = 0
      skew_sum = 0.0
      skew_max = 0.0
      coalesced = 0
      drops_before = kernel_drops
      deadline = Time.now.sys + 45.0
      GVLTools::LocalTimer.reset if GVL_TOOLS
      gvl_start = GVL_TOOLS ? GVLTools::LocalTimer.monotonic_time : 0
      start = Time.now.sys

      begin
        while highest < (datagrams - 1) and Time.now.sys < deadline
          if channel
            result = channel.read_with_time(READ_TIMEOUT)
            break if result.nil?
            data, stamped = result
          else
            begin
              data = socket_read(socket, READ_TIMEOUT)
            rescue Timeout::Error
              break
            end
            break if data.nil?
            # Stock can only ask the clock now that Ruby finally got the GVL
            stamped = Time.now.sys.to_f
          end
          # One read must return exactly one datagram, never two glued together
          coalesced += 1 if data.length != DATAGRAM_SIZE
          received += 1

          sequence = data.byteslice(0, 4).unpack1('N')
          sent = data.byteslice(4, 8).unpack1('G')
          if sequence != expected
            gaps += (sequence - expected) if sequence > expected
            expected = sequence
          end
          expected += 1
          highest = sequence if sequence > highest

          skew = stamped - sent
          skew_sum += skew
          skew_max = skew if skew > skew_max
        end
      rescue EOFError, IOError
        # Sender finished or the channel went away - report what we got
      end
      elapsed = Time.now.sys - start
      gvl_wait = GVL_TOOLS ? (GVLTools::LocalTimer.monotonic_time - gvl_start) / 1_000_000_000.0 : nil

      # Anything never delivered at all counts as lost, not just interior gaps
      gaps += (datagrams - 1 - highest) if highest < (datagrams - 1)
      ring_drops = channel ? channel.drop_count : 0
      ring_high = channel ? channel.high_water : 0

      hog_running = false
      if hog_thread
        hog_thread.join(2)
        hog_thread.kill if hog_thread.alive?
      end
      # Read the counters only once the hog has stopped fighting us for the GVL
      drops_after = kernel_drops
      kernel_delta = (drops_before and drops_after) ? (drops_after - drops_before) : nil
      send_drops = begin
        value = report_read.read(16)
        report_read.close
        (value and value.strip.length > 0) ? value.strip.to_i : nil
      rescue Exception
        nil
      end
      channel.disconnect(0) if channel
      Cosmos.close_socket(socket)
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
        :sent => datagrams,
        :send_drops => send_drops,
        # Loss the receiver is actually responsible for: everything missing
        # except what never left the sending host.
        :lost => gaps - (send_drops || 0),
        :received => received,
        :gaps => gaps,
        :coalesced => coalesced,
        :kernel_drops => kernel_delta,
        :ring_drops => ring_drops,
        :ring_high => ring_high,
        :skew_mean => received > 0 ? (skew_sum / received) : 0.0,
        :skew_max => skew_max,
        :gvl_wait => gvl_wait
      }
    end

    # The stock read path: exactly what UdpReadSocket#read does.
    def socket_read(socket, timeout)
      begin
        data, _ = socket.recvfrom_nonblock(65536)
      rescue Errno::EAGAIN, Errno::EWOULDBLOCK
        result = IO.fast_select([socket], nil, nil, timeout)
        if result
          retry
        else
          raise Timeout::Error, "Read Timeout"
        end
      end
      data
    end

    # Child process: send sequenced, timestamped datagrams at a paced rate.
    #
    # Deliberately does NOT retry on ENOBUFS. A real telemetry source does not
    # flow control on our receive queue - it keeps transmitting and the packet
    # is simply gone. Retrying would turn UDP into a flow controlled transport
    # and quietly convert receiver starvation into sender back-pressure, which
    # is the one thing this benchmark must not do. Sends that never made it
    # onto the wire are counted and reported back so they are never charged to
    # the receiver.
    def blast(port, datagrams, rate, report)
      socket = UDPSocket.new
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 4 * 1024 * 1024)
      socket.connect('127.0.0.1', port)
      filler = 'A' * (DATAGRAM_SIZE - 12)
      interval = 1.0 / rate.to_f
      next_send = Time.now.to_f
      send_drops = 0
      datagrams.times do |sequence|
        now = Time.now.to_f
        sleep(next_send - now) if (next_send - now) > 0.0005
        next_send += interval
        payload = [sequence].pack('N') << [Time.now.to_f].pack('G') << filler
        begin
          socket.send(payload, 0)
        rescue Errno::ENOBUFS, Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::EMSGSIZE
          send_drops += 1
        end
      end
      sleep 1 # let the receiver drain
      socket.close
      begin
        report.write(send_drops.to_s)
        report.close
      rescue Exception
      end
    rescue Exception
      # The receiver went away - nothing to do
    end

    def report
      header = "%-21s %-9s %-4s %8s %9s %10s %8s %7s %11s %10s %10s %9s %9s %9s"
      puts header % ['scenario', 'backend', 'hog', 'seconds', 'received', 'send drop',
                     'lost', 'loss %wire', 'kernel drop', 'ring drop', 'ring high',
                     'skew ms', 'skew max', 'gvl wait']
      puts '-' * 165
      @results.each do |result|
        # Charged against what actually made it onto the wire
        wire = result[:sent] - (result[:send_drops] || 0)
        loss = wire > 0 ? (100.0 * result[:lost] / wire) : 0.0
        gvl = result[:gvl_wait] ? ('%.0f%%' % (100.0 * result[:gvl_wait] / result[:elapsed])) : 'n/a'
        puts header % [result[:scenario], result[:backend], result[:hog] ? 'yes' : 'no',
                       '%.2f' % result[:elapsed], result[:received],
                       result[:send_drops].nil? ? 'n/a' : result[:send_drops],
                       result[:lost], '%.2f' % loss,
                       result[:kernel_drops].nil? ? 'n/a' : result[:kernel_drops],
                       result[:backend] == :buffered ? result[:ring_drops] : '-',
                       result[:backend] == :buffered ? result[:ring_high] : '-',
                       '%.1f' % (result[:skew_mean] * 1000.0),
                       '%.1f' % (result[:skew_max] * 1000.0), gvl]
      end
      puts ''
      puts "lost       = datagrams that reached this host and were never delivered to"
      puts "             Ruby (sequence gaps minus the sends that never left the sending"
      puts "             process)."
      puts "loss %wire = lost as a share of what actually reached the wire, i.e. offered"
      puts "             minus send drops. ONE denominator, used everywhere below too:"
      puts "             a datagram the sender never managed to send is not something"
      puts "             the receiver lost, and charging it as such flatters or damns"
      puts "             whichever backend happened to back the sender up."

      coalesced = @results.select { |r| r[:coalesced] > 0 }
      if coalesced.empty?
        puts "Datagram boundaries: every read returned exactly one datagram in every run."
      else
        puts "WARNING: coalesced reads detected: #{coalesced.map { |r| [r[:backend], r[:coalesced]] }.inspect}"
      end
      puts ''

      SCENARIOS.each do |name, datagrams, _ring, _rate|
        stock = @results.find { |r| r[:scenario] == name and r[:hog] and r[:backend] == :stock }
        buffered = @results.find { |r| r[:scenario] == name and r[:hog] and r[:backend] == :buffered }
        next unless stock and buffered
        puts "#{name}, GVL hog running (#{datagrams} datagrams offered):"
        # Same denominator as the loss %wire column above: what reached the
        # wire, not what was offered.
        stock_wire = stock[:sent] - (stock[:send_drops] || 0)
        buffered_wire = buffered[:sent] - (buffered[:send_drops] || 0)
        puts "  telemetry lost: stock #{stock[:lost]} "\
             "(#{'%.1f' % (stock_wire > 0 ? 100.0 * stock[:lost] / stock_wire : 0.0)}% of what "\
             "reached the wire, dropped silently) vs buffered #{buffered[:lost]} "\
             "(#{'%.1f' % (buffered_wire > 0 ? 100.0 * buffered[:lost] / buffered_wire : 0.0)}%)"
        if stock[:kernel_drops] and buffered[:kernel_drops]
          puts "  kernel 'dropped due to full socket buffers': stock #{stock[:kernel_drops]} vs "\
               "buffered #{buffered[:kernel_drops]}"
        end
        puts "  C++ ring high water #{buffered[:ring_high]} datagrams, "\
             "#{buffered[:ring_drops]} dropped (counted and queryable, never silent)"
        puts "  receive time error: stock mean #{'%.1f' % (stock[:skew_mean] * 1000)} ms / "\
             "max #{'%.1f' % (stock[:skew_max] * 1000)} ms vs buffered mean "\
             "#{'%.1f' % (buffered[:skew_mean] * 1000)} ms / max "\
             "#{'%.1f' % (buffered[:skew_max] * 1000)} ms"
        if stock[:gvl_wait] and buffered[:gvl_wait]
          puts "  reader time spent waiting for the GVL: stock "\
               "#{'%.0f' % (100.0 * stock[:gvl_wait] / stock[:elapsed])}% of wall vs buffered "\
               "#{'%.0f' % (100.0 * buffered[:gvl_wait] / buffered[:elapsed])}%"
        end
        puts ''
      end
    end
  end
  # The milestone 3 (serial) benchmark.
  #
  # A forked blaster sends sequenced, timestamped records into the master side
  # of a pty while this process reads the slave through the real serial stack -
  # PosixSerialDriver opens and configures the port, then either the stock
  # SerialStream or the BufferedSerialStream reads it - with a Ruby thread
  # hogging the GVL.
  #
  # WHAT A PTY CAN AND CANNOT PROVE
  #
  # It cannot reproduce a real UART receive overrun. A pty is a kernel pipe
  # with flow control: when the receiver is not draining, the buffer fills and
  # the *writer* is told to wait (EAGAIN / blocking write). A UART has no such
  # channel back to the sender - the far end keeps transmitting, the receive
  # FIFO and the tty input buffer overrun, and bytes are dropped in the
  # driver, silently and uncounted. So the loss numbers below are an
  # *emulation*: the blaster writes non blocking and, when the pty refuses the
  # record, drops it and moves on rather than waiting. That is the analogue of
  # the bytes a real UART would have lost, and it is deliberately charged to
  # the sender so nothing is misattributed to the receiver.
  #
  # What the pty proves outright, no emulation involved:
  #   * tty Q      - how full the receiver's tty input buffer gets (FIONREAD on
  #                  the port). On a real UART that queue overrunning IS the
  #                  data loss. Stock, under a GVL hog, pins it at the buffer
  #                  size; buffered keeps it near zero because a C++ thread is
  #                  draining it.
  #   * recv skew  - error in the receive time the interface stamps on the
  #                  data. Stock can only call Time.now once Ruby wins the GVL
  #                  (a scheduler quantum late, or worse); the buffered channel
  #                  carries the kernel receive time with the bytes.
  #   * gaps       - records the receiver never saw, minus the sender drops.
  #   * throughput under starvation.
  class SerialDropBench
    RECORD_SIZE = 1024
    READ_TIMEOUT = 2.0
    MEGABYTE = 1024.0 * 1024.0
    # FIONREAD: bytes waiting in the tty input queue. This is the queue a real
    # UART overruns.
    FIONREAD = (RUBY_PLATFORM =~ /darwin/) ? 0x4004667f : 0x541B
    # A pty input buffer is 1024 bytes on macOS, so anything at or above this
    # means the queue is full - which on a real UART means bytes are being
    # dropped on the floor.
    #
    # This figure is macOS-pty specific. Linux ptys and real serial drivers
    # have their own (typically 4 KiB of usable space out of a 16 KiB N_TTY
    # buffer), so the derived column is labelled "tty >=1000 B" rather than
    # "tty full": on another platform the same number means "the queue got at
    # least this deep", which is still the interesting comparison between the
    # two backends, without claiming to know where that platform's cliff is.
    TTY_BUFFER_FULL = 1000

    # name, records, offered records per second
    SCENARIOS = [
      ['20k @ 10k/s', 20_000, 10_000],
      ['20k @ 40k/s', 20_000, 40_000]
    ]

    def initialize
      @results = []
    end

    def run
      unless PTY_AVAILABLE
        puts "Serial benchmark skipped: no pty support on this platform"
        return
      end
      puts "Serial GVL hog benchmark (the milestone 3 headline)"
      puts "  ruby        #{RUBY_VERSION} (#{RUBY_PLATFORM})"
      puts "  extension   #{BufferedIO.extension_loaded? ? 'loaded' : 'NOT LOADED'}"
      puts "  record      #{RECORD_SIZE} bytes (4 byte sequence + 8 byte send time)"
      puts "  link        openpty loopback, receiver uses the stock PosixSerialDriver"
      puts ""

      SCENARIOS.each do |name, records, rate|
        [false, true].each do |hog|
          [:stock, :buffered].each do |backend|
            @results << measure(name, records, rate, backend, hog)
          end
        end
      end
      report
    end

    private

    def measure(scenario, records, rate, backend, hog)
      STDERR.puts "  running #{scenario} #{backend} hog=#{hog ? 'yes' : 'no'}"
      master, slave = PTY.open
      # Build the stream first: PosixSerialDriver puts the port into raw mode,
      # and a cooked tty would mangle binary records (and echo them back).
      stream = if backend == :buffered
                 BufferedSerialStream.new(slave.path, slave.path, 9600, :NONE, 1,
                                          10.0, READ_TIMEOUT)
               else
                 SerialStream.new(slave.path, slave.path, 9600, :NONE, 1, 10.0,
                                  READ_TIMEOUT)
               end

      hog_running = true
      hog_thread = nil
      if hog
        # Pure Ruby tight loop: never yields the GVL voluntarily
        hog_thread = Thread.new { hog_running = hog_running while hog_running }
        sleep 0.05
      end

      # The child reports how many records it could not put on the "wire", so a
      # sender side drop is never charged to the receiver.
      report_read, report_write = IO.pipe
      pid = fork do
        report_read.close
        blast(master, records, rate, report_write)
        exit!(0)
      end
      report_write.close

      expected = 0
      highest = -1
      gaps = 0
      received = 0
      total_bytes = 0
      max_tty = 0
      tty_samples = 0
      tty_full = 0
      reads = 0
      # Two different errors, kept apart on purpose:
      #   head - the error of the timestamp the chunk actually carries, taken
      #          against the first record in that chunk. This is the apples to
      #          apples number: stock stamps Time.now once it wins the GVL, the
      #          buffered channel carries the kernel receive time of that first
      #          byte. Nothing about chunk size enters into it.
      #   abs  - mean |error| charged to every record. A chunk carries one
      #          timestamp, so records further into a big chunk are stamped
      #          early by however long the chunk took to arrive. It is an
      #          artifact of per chunk stamping, not of the backend, and it is
      #          reported separately rather than mixed into the headline.
      head_sum = 0.0
      head_max = 0.0
      head_count = 0
      abs_sum = 0.0
      abs_max = 0.0
      buffer = ''.force_encoding('ASCII-8BIT')
      cursor = 0
      deadline = Time.now.sys + 30.0
      GVLTools::LocalTimer.reset if GVL_TOOLS
      gvl_start = GVL_TOOLS ? GVLTools::LocalTimer.monotonic_time : 0
      start = Time.now.sys

      begin
        while highest < (records - 1) and Time.now.sys < deadline
          queued = tty_queued(slave)
          if queued
            tty_samples += 1
            tty_full += 1 if queued >= TTY_BUFFER_FULL
            max_tty = queued if queued > max_tty
          end

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
              gaps += (sequence - expected) if sequence > expected
              expected = sequence
            end
            expected += 1
            highest = sequence if sequence > highest
            received += 1
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
          end
          if cursor > 0 and cursor == buffer.bytesize
            buffer = ''.force_encoding('ASCII-8BIT')
            cursor = 0
          end
        end
      rescue EOFError, Timeout::Error, IOError
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
      # Never block on the child: if the receiver gave up early the blaster can
      # still be parked against a pty nobody is draining, which is exactly the
      # situation the report is describing.
      send_drops = nil
      not_offered = nil
      begin
        if IO.select([report_read], nil, nil, 5.0)
          value = report_read.read_nonblock(64) rescue nil
          if value and value.strip.length > 0
            fields = value.strip.split(',')
            send_drops = fields[0].to_i
            not_offered = fields[2].to_i
          end
        end
      rescue Exception
      end
      begin
        report_read.close
      rescue Exception
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
      master.close rescue nil
      slave.close rescue nil

      # What the link actually carried. Anything the blaster never got onto the
      # pty is not the receiver's fault and is never charged to it.
      offered = records - (send_drops || 0) - (not_offered || 0)
      {
        :scenario => scenario,
        :backend => backend,
        :hog => hog,
        :elapsed => elapsed,
        :sent => records,
        :send_drops => send_drops,
        :not_offered => not_offered,
        :offered => offered,
        :lost => (send_drops.nil? ? nil : (offered - received)),
        :received => received,
        :bytes => total_bytes,
        :gaps => gaps,
        :max_tty => max_tty,
        :tty_samples => tty_samples,
        :tty_full => tty_full,
        :ring_high => stats[:high_water] || 0,
        :ring_drops => stats[:drop_count] || 0,
        :stalls => stats[:stall_count] || 0,
        :head_mean => head_count > 0 ? (head_sum / head_count) : 0.0,
        :head_max => head_max,
        :abs_mean => received > 0 ? (abs_sum / received) : 0.0,
        :abs_max => abs_max,
        :reads => reads,
        :gvl_wait => gvl_wait
      }
    end

    # Child process: push sequenced, timestamped records into the pty master at
    # a paced rate, non blocking.
    #
    # A record the pty will not accept is DROPPED, not retried. Retrying would
    # turn the link into a flow controlled transport and quietly convert
    # receiver starvation into sender back-pressure - which is exactly what a
    # real UART does not do. A partially accepted record is finished, because a
    # torn record is a benchmark artifact rather than a transport behavior.
    def blast(master, records, rate, report)
      master.sync = true
      flags = master.fcntl(Fcntl::F_GETFL, 0)
      master.fcntl(Fcntl::F_SETFL, flags | File::NONBLOCK)
      filler = 'A' * (RECORD_SIZE - 12)
      interval = 1.0 / rate.to_f
      next_send = Time.now.to_f
      drops = 0
      partials = 0
      abandoned = 0
      # A real transmitter is not allowed to run arbitrarily late, so neither
      # is this one. Past the budget the rest of the records are abandoned and
      # reported as never offered - they are not the receiver's loss.
      give_up_at = Time.now.to_f + (records / rate.to_f) + 10.0
      records.times do |sequence|
        if Time.now.to_f > give_up_at
          abandoned = records - sequence
          break
        end
        now = Time.now.to_f
        sleep(next_send - now) if (next_send - now) > 0.0005
        next_send += interval
        payload = [sequence].pack('N') << [Time.now.to_f].pack('G') << filler
        begin
          written = master.write_nonblock(payload)
          if written < payload.bytesize
            # A torn record would be a benchmark artifact rather than transport
            # behavior, so a partially accepted record is finished - but only
            # within the budget. Past it the run is over.
            partials += 1
            remaining = payload.byteslice(written..-1)
            while remaining.bytesize > 0
              begin
                count = master.write_nonblock(remaining)
                remaining = remaining.byteslice(count..-1)
              rescue IO::WaitWritable, Errno::EAGAIN, Errno::EWOULDBLOCK
                IO.select(nil, [master], nil, 1)
                if Time.now.to_f > give_up_at
                  abandoned = records - sequence
                  remaining = ''
                  break
                end
              end
            end
            break if abandoned > 0
          end
        rescue IO::WaitWritable, Errno::EAGAIN, Errno::EWOULDBLOCK
          # The analogue of a UART overrun: this record never reaches the
          # receiver and the sender does not care.
          drops += 1
        end
      end
      # Reported before the drain sleep: everything that was going to be
      # offered has been offered by now, and the receiver must never have to
      # wait on this pipe.
      begin
        report.write("#{drops},#{partials},#{abandoned}")
        report.close
      rescue Exception
      end
      sleep 1 # let the receiver drain
    rescue Exception
      # The receiver went away - nothing to do
    end

    # Bytes waiting in the tty input queue right now. On a real serial port
    # this queue overflowing is the data loss.
    def tty_queued(handle)
      buffer = [0].pack('L')
      handle.ioctl(FIONREAD, buffer)
      buffer.unpack1('L')
    rescue Exception
      nil
    end

    def drain_rate(result)
      result[:elapsed] > 0 ? (result[:received] / result[:elapsed]) : 0.0
    end

    def tty_full_percent(result)
      return 0.0 if result[:tty_samples].to_i == 0
      100.0 * result[:tty_full] / result[:tty_samples]
    end

    def report
      header = "%-14s %-9s %-4s %8s %9s %9s %9s %8s %7s %8s %10s %10s %7s %8s %8s %8s"
      puts header % ['scenario', 'backend', 'hog', 'seconds', 'received', 'rec/s',
                     'not offer', 'senddrop', 'lost', 'tty>=1000', 'ring drop',
                     'ring high', 'stalls', 'head ms', 'head max', 'gvl wait']
      puts '-' * 175
      @results.each do |result|
        gvl = result[:gvl_wait] ? ('%.0f%%' % (100.0 * result[:gvl_wait] / result[:elapsed])) : 'n/a'
        puts header % [result[:scenario], result[:backend], result[:hog] ? 'yes' : 'no',
                       '%.2f' % result[:elapsed], result[:received],
                       '%.0f' % drain_rate(result),
                       result[:not_offered].nil? ? 'n/a' : result[:not_offered],
                       result[:send_drops].nil? ? 'n/a' : result[:send_drops],
                       result[:lost].nil? ? 'n/a' : result[:lost],
                       '%.0f%%' % tty_full_percent(result),
                       result[:backend] == :buffered ? result[:ring_drops] : '-',
                       result[:backend] == :buffered ? result[:ring_high] : '-',
                       result[:backend] == :buffered ? result[:stalls] : '-',
                       '%.1f' % (result[:head_mean] * 1000.0),
                       '%.1f' % (result[:head_max] * 1000.0), gvl]
      end
      puts ''
      puts "rec/s     = records the Ruby side actually drained per second. This is the"
      puts "            number that decides what baud rate a port can be run at."
      puts "not offer = records the blaster abandoned because the pty would not take them"
      puts "            inside its time budget. A pty back-pressures; a UART does not, so"
      puts "            these are NOT receiver loss and are never charged as such."
      puts "senddrop  = records the pty refused outright (EAGAIN). The closest a pty gets"
      puts "            to a UART overrun, and still charged to the sender."
      puts "lost      = offered - received: loss the receiver really is responsible for."
      puts "tty>=1000 = share of samples where the receiver's tty input queue held at"
      puts "            least TTY_BUFFER_FULL bytes. On macOS a pty buffer IS 1024 bytes,"
      puts "            so that is exactly \"full\"; elsewhere read it as \"got this deep\"."
      puts "            On a real UART every byte arriving while it is full is gone, but on"
      puts "            a pty (1 KB buffer, sender at line rate) both backends sit at the"
      puts "            ceiling; what differs is how often it gets emptied - see rec/s."
      puts "head ms   = error of the timestamp the chunk carries, against the first record"
      puts "            in that chunk. Stock cannot sample the clock until it wins the GVL."
      puts ''

      SCENARIOS.each do |name, records, rate|
        stock = @results.find { |r| r[:scenario] == name and r[:hog] and r[:backend] == :stock }
        buffered = @results.find { |r| r[:scenario] == name and r[:hog] and r[:backend] == :buffered }
        next unless stock and buffered
        stock_rate = drain_rate(stock)
        buffered_rate = drain_rate(buffered)
        puts "#{name}, GVL hog running (#{records} records offered at #{rate}/s):"
        puts "  drain rate: stock #{'%.0f' % stock_rate} records/s "\
             "(#{'%.1f' % (stock_rate * RECORD_SIZE / 1024.0)} KB/s) vs buffered "\
             "#{'%.0f' % buffered_rate} records/s "\
             "(#{'%.0f' % (buffered_rate * RECORD_SIZE / 1024.0)} KB/s) - "\
             "#{'%.0f' % (stock_rate > 0 ? buffered_rate / stock_rate : 0)}x"
        puts "    A 115200 baud port delivers 11.5 KB/s and a 921600 baud port 92 KB/s."
        puts "    Stock, while another Ruby thread is busy, cannot keep up with either;"
        puts "    on real hardware everything it cannot take is dropped by the driver."
        puts "  the link refused #{stock[:send_drops].inspect} records from the sender and the "\
             "sender abandoned #{stock[:not_offered].inspect} more with stock, vs "\
             "#{buffered[:send_drops].inspect} / #{buffered[:not_offered].inspect} buffered"
        puts "    (on a UART those #{stock[:not_offered]} records would have been transmitted"\
             " anyway and lost in the driver)"
        puts "  tty input queue at or above #{TTY_BUFFER_FULL} bytes for "\
             "#{'%.0f%%' % tty_full_percent(stock)} of stock's "\
             "samples vs #{'%.0f%%' % tty_full_percent(buffered)} of buffered's - but this"
        puts "    one does not discriminate on a pty: the buffer is 1 KB and the sender is"
        puts "    at line rate, so it is full in both runs. The difference is how often it"
        puts "    is emptied, which is the drain rate above."
        puts "  C++ ring high water #{buffered[:ring_high]} bytes "\
             "(#{'%.1f' % (buffered[:ring_high] / 1024.0)} KB of backlog a 1 KB tty buffer "\
             "could never have held), #{buffered[:ring_drops]} dropped, "\
             "#{buffered[:stalls]} back-pressure stalls"
        puts "  receive time error (first record of each chunk): stock mean "\
             "#{'%.1f' % (stock[:head_mean] * 1000)} ms / max "\
             "#{'%.1f' % (stock[:head_max] * 1000)} ms vs buffered mean "\
             "#{'%.2f' % (buffered[:head_mean] * 1000)} ms / max "\
             "#{'%.2f' % (buffered[:head_max] * 1000)} ms"
        puts "    (this one the pty proves outright - no emulation involved)"
        puts "  mean |error| charged to every record in a chunk: stock "\
             "#{'%.1f' % (stock[:abs_mean] * 1000)} ms vs buffered "\
             "#{'%.1f' % (buffered[:abs_mean] * 1000)} ms - a chunk carries one timestamp,"
        puts "    so a big buffered chunk stamps its tail early. Artifact of per chunk"
        puts "    stamping, not of the backend."
        if stock[:gvl_wait] and buffered[:gvl_wait]
          puts "  reader time spent waiting for the GVL: stock "\
               "#{'%.0f' % (100.0 * stock[:gvl_wait] / stock[:elapsed])}% of wall vs buffered "\
               "#{'%.0f' % (100.0 * buffered[:gvl_wait] / buffered[:elapsed])}%"
        end
        puts "  throughput: stock #{'%.2f' % (stock[:bytes] / MEGABYTE / stock[:elapsed])} MB/s vs "\
             "buffered #{'%.2f' % (buffered[:bytes] / MEGABYTE / buffered[:elapsed])} MB/s"
        puts ''
      end
      puts "What a pty cannot show: a real UART with no flow control keeps transmitting"
      puts "while the receiver is starved, and the driver drops what does not fit. A pty"
      puts "instead refuses the write, so the loss shows up on the sending side as"
      puts "'not offer'/'senddrop' rather than as receiver loss. Read those columns as"
      puts "'what a UART would have destroyed'. The measurements that carry over to real"
      puts "hardware unchanged are 'rec/s' - how fast Ruby can drain a port, which is what"
      puts "decides the baud rate a port survives - and 'head ms', the accuracy of the"
      puts "receive time the interface stamps on the data."
    end
  end
end

case (ARGV[0] || 'all')
when 'tcp'
  Cosmos::BufferedIoBench.new.run
when 'udp'
  Cosmos::UdpDropBench.new.run
when 'serial'
  Cosmos::SerialDropBench.new.run
else
  Cosmos::BufferedIoBench.new.run
  puts ''
  Cosmos::UdpDropBench.new.run
  puts ''
  Cosmos::SerialDropBench.new.run
end
