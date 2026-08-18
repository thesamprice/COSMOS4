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
require 'cosmos/io/udp_sockets'

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
      skew_sum = 0.0
      skew_max = 0.0
      skew_count = 0
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

          while (buffer.bytesize - cursor) >= RECORD_SIZE
            sequence = buffer.byteslice(cursor, 4).unpack1('N')
            sent = buffer.byteslice(cursor + 4, 8).unpack1('G')
            cursor += RECORD_SIZE
            if sequence != expected
              gaps += (sequence - expected)
              expected = sequence
            end
            expected += 1
            skew = stamped - sent
            skew_sum += skew
            skew_max = skew if skew > skew_max
            skew_count += 1
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
        :skew_mean => skew_count > 0 ? (skew_sum / skew_count) : 0.0,
        :skew_max => skew_max,
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
                     'kernel Q', 'ring high', 'drops', 'skew ms', 'skew max',
                     'reads', 'gvl wait']
      puts '-' * 140
      @results.each do |result|
        megabytes = result[:bytes] / MEGABYTE
        rate = result[:elapsed] > 0 ? megabytes / result[:elapsed] : 0.0
        gvl = result[:gvl_wait] ? ('%.0f%%' % (100.0 * result[:gvl_wait] / result[:elapsed])) : 'n/a'
        puts header % [result[:scenario], result[:backend], result[:hog] ? 'yes' : 'no',
                       '%.2f' % result[:elapsed], '%.1f' % rate, result[:gaps],
                       result[:max_kernel], result[:ring_high_water], result[:drops],
                       '%.1f' % (result[:skew_mean] * 1000.0),
                       '%.1f' % (result[:skew_max] * 1000.0), result[:reads], gvl]
      end
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
        puts "  receive time error: stock mean #{'%.1f' % (stock[:skew_mean] * 1000)} ms / "\
             "max #{'%.1f' % (stock[:skew_max] * 1000)} ms vs buffered mean "\
             "#{'%.1f' % (buffered[:skew_mean] * 1000)} ms / max "\
             "#{'%.1f' % (buffered[:skew_max] * 1000)} ms"
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
    def kernel_drops
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
                     'lost', 'loss %', 'kernel drop', 'ring drop', 'ring high',
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
      puts "lost = datagrams that reached this host and were never delivered to Ruby"
      puts "       (sequence gaps minus the sends that never left the sending process)"

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
        puts "  telemetry lost: stock #{stock[:lost]} "\
             "(#{'%.1f' % (100.0 * stock[:lost] / stock[:sent])}% of the stream, dropped silently) "\
             "vs buffered #{buffered[:lost]}"
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
end

case (ARGV[0] || 'all')
when 'tcp'
  Cosmos::BufferedIoBench.new.run
when 'udp'
  Cosmos::UdpDropBench.new.run
else
  Cosmos::BufferedIoBench.new.run
  puts ''
  Cosmos::UdpDropBench.new.run
end
