# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'timeout' # For Timeout::Error

module Cosmos
  # Loader and feature switch for the buffered C++ I/O backends. The extension
  # moves the device reads and writes onto C++ threads that never touch a Ruby
  # API so the OS buffers are drained even while another Ruby thread holds the
  # GVL.
  #
  # Buffered I/O is the default. It is skipped when:
  #   * the extension is not built for this platform (automatic, logged once)
  #   * COSMOS_NO_BUFFERED_IO is set in the environment
  #   * an interface is configured with OPTION BUFFERED false
  #
  # In every one of those cases the original pure Ruby paths are used unchanged.
  module BufferedIO
    # Legal ring sizes, mirroring the bounds the C++ adopt enforces (see
    # MIN_RING_BYTES and friends in ext/cosmos/ext/buffered_io/buffered_io.cpp).
    # They are duplicated here rather than read off the extension so that a
    # configuration file is validated identically whether or not the extension
    # is built or COSMOS_NO_BUFFERED_IO is set - an OPTION line that would be
    # refused on one machine must be refused on all of them.
    #
    # Below the floor a ring cannot hold a single read chunk; above the ceiling
    # a typo (one extra group of zeros) reserves address space no deployment
    # wants and fails somewhere much less obvious.
    MIN_RING_BYTES = 4096
    MAX_RING_BYTES = 1024 * 1024 * 1024
    MIN_RING_DATAGRAMS = 16
    MAX_RING_DATAGRAMS = 1_048_576

    @extension_loaded = false
    @extension_error = nil
    # Interface (or stream class) name => already logged. Keyed per name rather
    # than module-global on purpose: a server with one unadoptable interface
    # among ten must not silence the message for the other nine, and the reason
    # is rarely the same for two different interfaces.
    @fallback_logged = {}

    if RUBY_ENGINE == 'ruby' and !ENV['COSMOS_NO_EXT']
      begin
        require 'cosmos/ext/buffered_io'
        @extension_loaded = true
      rescue LoadError => load_error
        @extension_error = load_error
      end
    else
      @extension_error = RuntimeError.new("C extensions disabled")
    end

    # @return [Boolean] Whether the C++ extension was successfully loaded
    def self.extension_loaded?
      @extension_loaded
    end

    # @return [Exception|nil] Why the extension could not be loaded
    def self.extension_error
      @extension_error
    end

    # @return [Boolean] Whether buffered I/O was disabled by the environment
    def self.disabled_by_env?
      value = ENV['COSMOS_NO_BUFFERED_IO']
      return false if value.nil? or value.empty?
      !%w(0 false FALSE no NO).include?(value)
    end

    # @return [Boolean] Whether buffered I/O can be used
    def self.available?
      extension_loaded? and !disabled_by_env?
    end

    # Log (once per name) why the stock pure Ruby path is being used. The
    # fallback is always automatic - this only makes it visible.
    #
    # The reason is supplied by the caller because there are two very different
    # ones and saying the wrong one sends the operator hunting for a build
    # problem that does not exist: the extension really is missing, or the
    # extension loaded fine and this particular descriptor could not be adopted
    # (a test double, a socket that went away between accept and adopt, a
    # Win32SerialDriver). Only the first is a "buffered I/O extension
    # unavailable" message.
    #
    # @param who [String] Name of the interface or stream falling back
    # @param reason [String|nil] Why the stock path is in use. nil means the
    #   extension itself is unavailable, and the load error is filled in.
    def self.log_fallback(who, reason = nil)
      return if disabled_by_env?
      key = who.to_s
      return if @fallback_logged[key]
      @fallback_logged[key] = true
      reason ||= "buffered I/O extension unavailable "\
                 "(#{@extension_error ? @extension_error.message : 'unknown'})"
      message = "#{key}: #{reason} - using the stock Ruby stream"
      if defined?(Cosmos::Logger)
        Cosmos::Logger.info(message)
      else
        STDOUT.puts message
      end
    end

    # @return [Boolean] Whether a fallback has already been logged for this name
    def self.fallback_logged?(who)
      !!@fallback_logged[who.to_s]
    end

    # Reset the memoized fallback log (used by tests)
    def self.reset_fallback_log
      @fallback_logged = {}
    end

    # The canonical zeroed statistics hash. Every buffered stream and interface
    # returns this shape (a transport may add keys of its own - UDP adds
    # :buffered_datagrams) so the CmdTlmServer can read the same counters off
    # any interface without knowing which transport is underneath, and so a
    # stock, unbuffered interface answers with zeros rather than nil.
    #
    #   :buffered            - whether a C++ channel is actually in use
    #   :drop_count          - bytes (datagrams for UDP) the ring threw away.
    #                          Always zero under the default :backpressure
    #                          policy for the byte streams.
    #   :stall_count         - times the reader stopped reading the device
    #                          because the ring was full. The early warning
    #                          that Ruby is not draining; always zero for UDP,
    #                          which cannot back pressure.
    #   :buffered_bytes      - backlog sitting in the ring right now
    #   :high_water          - largest backlog ever held
    #   :ring_bytes          - configured ring size
    #   :pending_write_bytes - queued for the writer thread
    #
    # @return [Hash] A fresh hash - callers mutate it
    def self.empty_stats
      {
        :buffered => false,
        :bytes_read => 0,
        :bytes_written => 0,
        :drop_count => 0,
        :stall_count => 0,
        :buffered_bytes => 0,
        :high_water => 0,
        :ring_bytes => 0,
        :pending_write_bytes => 0
      }
    end

    # The bookkeeping shared by everything that owns a pair of C++ channels:
    # the byte stream transports below, and {UdpInterface}, which holds its
    # {DatagramChannel}s itself because UDP has no stream object to put them
    # in. Only the parts that do not care which kind of channel it is.
    module ChannelHolder
      # @return [StreamChannel|DatagramChannel|nil] Channel draining the read
      #   descriptor
      attr_reader :read_channel
      # @return [StreamChannel|DatagramChannel|nil] Channel filling the write
      #   descriptor
      attr_reader :write_channel

      # @return [Time|nil] Time the first byte of the last chunk (the last
      #   datagram, for UDP) handed to Ruby was received by the C++ reader
      #   thread. This is a kernel handoff time taken without the GVL, so
      #   unlike Time.now in a starved Ruby thread it is not skewed by
      #   scheduling.
      def last_read_time
        @last_read_time_f ? Time.at(@last_read_time_f).sys : nil
      end

      # @return [Float|nil] {#last_read_time} as seconds since the epoch
      def last_read_time_f
        @last_read_time_f
      end

      protected

      # @return [Array] Unique live channels. Read and write are the same
      #   channel whenever one descriptor serves both directions.
      def channels
        [@read_channel, @write_channel].compact.uniq { |channel| channel.object_id }
      end

      # Stop the channels. Called both to disconnect and to give up on the
      # buffered path, so it must tolerate a channel that is already gone.
      #
      # @param flush_timeout [Float] Seconds to let queued writes drain
      def release_channels(flush_timeout = 0)
        channels.each do |channel|
          begin
            channel.disconnect(flush_timeout)
          rescue Exception
            # Nothing useful to do if the channel is already gone
          end
        end
        @read_channel = nil
        @write_channel = nil
        # The kernel receive time belongs to data that arrived on the channels
        # just released. Keeping it would let {#last_read_time} answer with a
        # timestamp from before the disconnect, which reads as "data arrived
        # recently" on a link that has been down for an hour.
        @last_read_time_f = nil
      end
    end

    # The plumbing every buffered byte stream needs, in one place instead of a
    # copy per transport. Options, statistics, the read / write / flush path,
    # connected?, disconnect and the "fall back on any failure" adoption
    # skeleton all live here; a transport mixin ({BufferedSocketStream},
    # {BufferedSerialTransport}) supplies only what is genuinely different:
    #
    #   #adopt_channels               - probe the descriptors and create the
    #                                   C++ channels. The real difference: a
    #                                   socket is probed with remote_address, a
    #                                   serial port by digging the tty out of
    #                                   its {PosixSerialDriver}.
    #   #buffered_readable? / #buffered_writable?
    #                                 - which sides of the transport exist
    #   #buffered_read_errors         - errors meaning the descriptor went away
    #   #buffered_nonblock_read_bytes - cap on one read_nonblock, nil for the
    #                                   C++ default
    #   #buffered_write_lock          - how writers are serialized, if the
    #                                   stock stream serializes them
    #
    # Included (through one of those mixins) into a {Stream} subclass this
    # replaces only the transport: Ruby still opens, connects and closes the
    # device, while a {StreamChannel} adopts the descriptor and does the
    # reading and writing from threads that never take the GVL. Every return
    # value, exception and timeout matches the stock stream, so protocols and
    # interfaces see no difference, and if a channel cannot be created the
    # stock Ruby implementation is used unchanged.
    module Transport
      include ChannelHolder

      # Bytes of user space ring buffer per read channel
      DEFAULT_RING_BYTES = 16 * 1024 * 1024
      # Bytes one read returns at most. Deliberately the same 64 KiB the stock
      # Ruby streams read, because a BURST protocol turns whatever one read
      # returns into one packet: returning the entire ring instead would change
      # the packet sizes an existing configuration has always produced. Raise it
      # with BUFFERED_READ_CHUNK to drain a large backlog in fewer reads.
      DEFAULT_READ_CHUNK_BYTES = 65536
      # Ring for a channel that only ever writes
      WRITE_ONLY_RING_BYTES = 65536
      # Seconds to let queued writes drain during disconnect
      DEFAULT_FLUSH_TIMEOUT = 1.0

      # Configure the buffered layer. Called from the including class's
      # constructor.
      #
      # @param options [Hash] :ring_bytes, :read_chunk_bytes, :write_high_water,
      #   :write_policy (:block or :raise), :overflow_policy (:backpressure,
      #   :drop_oldest or :drop_newest), :flush_timeout
      def setup_buffered_options(options = {})
        options ||= {}
        # A zero or negative size is treated as "use the default" rather than
        # being passed through to a channel that would refuse it. The interface
        # option parser rejects these at config load; this is the defense for
        # anything that constructs a stream directly.
        @ring_bytes = options[:ring_bytes].to_i
        @ring_bytes = DEFAULT_RING_BYTES if @ring_bytes <= 0
        # Bytes returned by one read. Defaults to the same 64 KiB the stock
        # streams read so framing (BURST especially) is unchanged; see
        # DEFAULT_READ_CHUNK_BYTES.
        @read_chunk_bytes = options[:read_chunk_bytes].to_i
        @read_chunk_bytes = DEFAULT_READ_CHUNK_BYTES if @read_chunk_bytes <= 0
        @write_high_water = options[:write_high_water]
        @write_policy = options[:write_policy] || :block
        # See doc/buffered_io_design.md: the byte streams default to back
        # pressure, not to a drop policy. TCP is lossless today and must stay
        # lossless, dropping bytes out of the middle of a serial byte stream
        # desynchronizes framing, and back pressure is what keeps RTS/CTS flow
        # control working. Drop policies are for the transport the kernel
        # already drops (UDP), and remain available per interface.
        @overflow_policy = options[:overflow_policy] || :backpressure
        @flush_timeout = options[:flush_timeout] || DEFAULT_FLUSH_TIMEOUT
        @read_channel = nil
        @write_channel = nil
        @last_read_time_f = nil
      end

      # @return [Boolean] Whether this stream is actually running through the
      #   buffered C++ backend
      def buffered?
        !!(@read_channel or @write_channel)
      end

      # @return [Boolean] Whether the stream is connected
      def connected?
        return false unless super()
        live = channels
        return true if live.empty?
        live.each { |channel| return false if channel.stopped? }
        true
      end

      # @return [Hash] Buffered channel statistics for the CmdTlmServer counters
      #   (see BufferedIO.empty_stats). :drop_count stays zero under the default
      #   :backpressure policy - the byte streams are lossless and must stay
      #   lossless - so :stall_count is the counter that says Ruby is falling
      #   behind and the device buffer is next in line.
      def buffered_stats
        # Snapshot both channels: disconnect nils them from another thread (see
        # the note on #read), and a stats call is exactly the sort of thing the
        # CmdTlmServer does while an interface is going down.
        read_channel = @read_channel
        write_channel = @write_channel
        stats = BufferedIO.empty_stats
        return stats unless read_channel or write_channel
        stats[:buffered] = true
        if read_channel
          stats[:bytes_read] = read_channel.bytes_read
          stats[:drop_count] = read_channel.drop_count
          # StreamChannel gains its stall counter with the serial milestone;
          # until then the zero from empty_stats stands.
          stats[:stall_count] = read_channel.stall_count if read_channel.respond_to?(:stall_count)
          stats[:buffered_bytes] = read_channel.buffered_bytes
          stats[:high_water] = read_channel.high_water
          stats[:ring_bytes] = read_channel.ring_bytes
        end
        if write_channel
          stats[:bytes_written] = write_channel.bytes_written
          stats[:pending_write_bytes] = write_channel.pending_write_bytes
        end
        stats
      end

      # (see Stream#read)
      #
      # The channel is snapshotted into a local before it is used. Testing
      # @read_channel and then dereferencing it is a NoMethodError waiting to
      # happen: {#disconnect} runs on another thread (InterfaceThread#stop while
      # this thread is parked in a read) and sets it to nil in between. A
      # snapshot cannot go nil underneath us, and a channel that has been
      # stopped rather than dropped raises IOError, which the rescue below
      # already turns into the stock empty read.
      def read
        raise "Attempt to read from write only stream" unless buffered_readable?
        channel = @read_channel
        return super() unless channel

        begin
          result = channel.read_with_time(@read_timeout, @read_chunk_bytes)
          # The stock streams raise Timeout::Error when a read times out
          raise Timeout::Error, "Read Timeout" if result.nil?
          data, @last_read_time_f = result
          data
        rescue EOFError
          # The other end went away cleanly. The stock streams raise this too.
          raise
        rescue *buffered_read_errors
          # The descriptor went away underneath us, or another thread
          # disconnected the channel. The stock streams end up answering an
          # empty read here, which is how {StreamInterface#read_interface} is
          # told to shut the interface down.
          ''
        end
      end

      # (see Stream#read_nonblock)
      def read_nonblock
        # No write only guard: without a read side there is no read channel
        # either, so the stock stream below answers exactly as it always has.
        channel = @read_channel
        return super() unless channel

        begin
          result = channel.read_with_time(0, buffered_nonblock_read_bytes)
          # Nothing waiting. The stock streams answer '' rather than blocking.
          return '' if result.nil?
          data, @last_read_time_f = result
          data
        rescue EOFError
          raise
        rescue *buffered_read_errors
          ''
        end
      end

      # (see Stream#write)
      def write(data)
        raise "Attempt to write to read only stream" unless buffered_writable?
        channel = @write_channel
        return super(data) unless channel

        # The C++ writer thread owns the syscall - this only queues, in order.
        buffered_write_lock do
          result = channel.write(data, @write_timeout)
          # The stock streams raise Timeout::Error the same way
          raise Timeout::Error, "Write Timeout" if result == false
        end
        nil
      end

      # Wait for all queued writes to reach the kernel
      #
      # @param timeout [Float|nil] Seconds to wait, nil to wait forever
      # @return [Boolean] Whether everything was written
      def flush(timeout = nil)
        channel = @write_channel
        return true unless channel
        channel.flush(timeout)
      end

      # Stop the channels then let the stock implementation close the device
      def disconnect
        release_channels(@flush_timeout)
        super()
      end

      protected

      # Hand the connected descriptors to the C++ channels. Any failure at all
      # falls back to the stock Ruby implementation - a buffering problem must
      # never be able to break a device that plain Ruby can serve.
      def adopt_buffered_channels
        return unless BufferedIO.available?
        return if @read_channel or @write_channel

        begin
          adopt_channels()
          channels.each do |channel|
            channel.write_policy = @write_policy if @write_policy
            channel.write_high_water = @write_high_water if @write_high_water
          end
        rescue Exception => error
          # Never let the buffered path break a device Ruby can serve. The
          # extension is loaded (we got past BufferedIO.available?), so the
          # reason is this descriptor, not a missing build.
          BufferedIO.log_fallback(self.class.name,
                                  "buffered channel could not be created "\
                                  "(#{error.class}: #{error.message})")
          Logger.warn("#{self.class.name}: #{error.class}: #{error.message}") if defined?(Logger)
          release_channels(0)
        end
      end

      # Create @read_channel and @write_channel from the transport's
      # descriptors, applying whatever overflow policy that transport wants.
      # Everything a transport does differently lives here.
      def adopt_channels
        raise NotImplementedError, "#{self.class.name} must implement adopt_channels"
      end

      # @return [Boolean] Whether this transport has a read side
      def buffered_readable?
        raise NotImplementedError, "#{self.class.name} must implement buffered_readable?"
      end

      # @return [Boolean] Whether this transport has a write side
      def buffered_writable?
        raise NotImplementedError, "#{self.class.name} must implement buffered_writable?"
      end

      # @return [Array<Class>] Errors from a buffered read that the stock stream
      #   for this transport would have turned into an empty read rather than
      #   propagated. Empty by default: a transport only lists an error here
      #   when its own stock implementation swallows it.
      #
      #   IOError is deliberately NOT in this list. It is what a disconnected
      #   channel raises, and whether that should surface is a per transport
      #   question: {TcpipSocketStream} rescues a dead socket and answers '',
      #   while {SerialStream} lets a mid read close raise straight out. Putting
      #   IOError here would have quietly changed the serial contract.
      def buffered_read_errors
        []
      end

      # @return [Integer|nil] Cap on the bytes one {#read_nonblock} returns.
      #   nil leaves the C++ default (StreamChannel::READ_CHUNK_BYTES) in
      #   place.
      def buffered_nonblock_read_bytes
        nil
      end

      # Serialize buffered writes the way the stock stream serializes its own.
      # Only queuing happens inside, so this is never held across a syscall.
      def buffered_write_lock
        yield
      end
    end

    # The BUFFERED* interface options, in one place instead of a copy per
    # interface. Included into an {Interface} subclass it supplies:
    #
    #   #initialize_buffered_options - the ivars, with per transport defaults
    #   #buffered?                   - whether the C++ backend would be used
    #   #set_option                  - BUFFERED plus the BUFFERED_* options the
    #                                  interface declares legal
    #   #log_buffered_fallback       - the logged once "the extension is not
    #                                  here, using the stock Ruby path" message
    #
    # The module sits between the interface and {Interface} in the ancestor
    # chain, so an interface with options of its own parses them after calling
    # super, exactly as it did when this code was inline. Building the stream
    # or adopting the sockets stays with the interface: only the option
    # plumbing is shared.
    module InterfaceOptions
      # BUFFERED_* option name => the @buffered_options key it sets. An
      # interface only accepts the keys it declares in #buffered_option_keys,
      # which is what makes BUFFERED_RING_DATAGRAMS a UDP only option.
      OPTION_KEYS = {
        'BUFFERED_RING_DATAGRAMS' => :ring_datagrams,
        'BUFFERED_RING_BYTES' => :ring_bytes,
        'BUFFERED_READ_CHUNK' => :read_chunk_bytes,
        'BUFFERED_WRITE_HIGH_WATER' => :write_high_water,
        'BUFFERED_OVERFLOW' => :overflow_policy
      }.freeze

      # The BUFFERED_* options every buffered interface accepts
      DEFAULT_OPTION_KEYS = [:ring_bytes, :read_chunk_bytes, :write_high_water,
                             :overflow_policy].freeze

      # Inclusive [minimum, maximum] for each integer option. ring_bytes and
      # ring_datagrams match the bounds the C++ adopt enforces; the other two
      # only have to be positive, and share the ring ceiling so a typo cannot
      # ask for something absurd.
      INTEGER_LIMITS = {
        :ring_bytes => [MIN_RING_BYTES, MAX_RING_BYTES],
        :ring_datagrams => [MIN_RING_DATAGRAMS, MAX_RING_DATAGRAMS],
        :read_chunk_bytes => [1, MAX_RING_BYTES],
        :write_high_water => [1, MAX_RING_BYTES]
      }.freeze

      # Called from the interface's constructor.
      #
      # @param defaults [Hash] Buffered options this transport wants set before
      #   any OPTION is parsed. Empty means "whatever the stream defaults to".
      def initialize_buffered_options(defaults = {})
        # nil means "use the buffered backend if it is available" (the default).
        # OPTION BUFFERED FALSE or COSMOS_NO_BUFFERED_IO force the stock path.
        @buffered = nil
        @buffered_options = defaults
      end

      # @return [Boolean] Whether this interface reads and writes through the
      #   buffered C++ backend
      def buffered?
        return false if @buffered == false
        BufferedIO.available?
      end

      # @return [Array<Symbol>] Which {OPTION_KEYS} this interface accepts.
      #   Overridden by the interface that takes more than the common set (UDP,
      #   which has a datagram ring to size as well as a byte ring).
      def buffered_option_keys
        DEFAULT_OPTION_KEYS
      end

      # @return [Array<Symbol>] Overflow policies that are legal for this
      #   transport. Overridden by {UdpInterface}, which cannot back pressure:
      #   refusing to read a UDP socket does not make UDP lossless, it only
      #   moves the loss into SO_RCVBUF where nothing can count it.
      def buffered_overflow_policies
        [:backpressure, :drop_oldest, :drop_newest]
      end

      # Supported Options
      # BUFFERED - FALSE disables the buffered C++ backend for this interface
      # BUFFERED_RING_BYTES - Size of the C++ read ring
      # BUFFERED_READ_CHUNK - Bytes one read returns at most
      # BUFFERED_WRITE_HIGH_WATER - Bytes allowed to queue for the writer thread
      # BUFFERED_OVERFLOW - backpressure, drop_oldest or drop_newest. The
      #   default belongs to the transport, not to this module; see
      #   doc/buffered_io_design.md for why the byte streams default to back
      #   pressure while UDP defaults to dropping.
      # (see Interface#set_option)
      #
      # Every value is validated here, at config parse time, and a bad one
      # raises. Silently ignoring it - which is what Integer() blowing up in the
      # middle of a config load or a mistyped policy quietly reverting to the
      # default amounted to - hides the mistake until the day the ring behaves
      # nothing like the operator asked for.
      #
      # @param option_name (see Interface#set_option)
      # @param option_values (see Interface#set_option)
      # @raise [ArgumentError] The value is not legal for this option
      def set_option(option_name, option_values)
        super(option_name, option_values)
        name = option_name.to_s.upcase
        if name == 'BUFFERED'
          value = option_values[0].to_s
          result = ConfigParser.handle_true_false(value)
          # handle_true_false passes anything it does not recognize straight
          # through, so 'no' and '0' would land here as truthy strings and read
          # as "buffered on" - the opposite of what was written.
          unless result == true or result == false
            raise ArgumentError, "#{name} must be TRUE or FALSE, not '#{value}'"
          end
          @buffered = result
          return
        end
        key = OPTION_KEYS[name]
        # An option this transport has no use for is ignored, exactly as an
        # unknown option always has been
        return unless key and buffered_option_keys.include?(key)
        @buffered_options[key] = if key == :overflow_policy
                                   buffered_overflow_value(name, option_values[0])
                                 else
                                   buffered_integer_value(name, key, option_values[0])
                                 end
      end

      protected

      # @return [Integer] The validated value for an integer BUFFERED_* option
      # @raise [ArgumentError] Not an integer, or outside the legal range
      def buffered_integer_value(name, key, value)
        begin
          number = Integer(value.to_s.strip)
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{name} must be an integer, not '#{value}'"
        end
        minimum, maximum = INTEGER_LIMITS[key]
        unless number >= minimum and number <= maximum
          raise ArgumentError,
                "#{name} must be between #{minimum} and #{maximum}, not #{number}"
        end
        number
      end

      # @return [Symbol] The validated overflow policy
      # @raise [ArgumentError] Not a policy this transport supports
      def buffered_overflow_value(name, value)
        policy = value.to_s.strip.downcase.to_sym
        legal = buffered_overflow_policies
        unless legal.include?(policy)
          raise ArgumentError,
                "#{name} must be one of #{legal.join(', ')}, not '#{value}'"
        end
        policy
      end

      # Automatic, logged once: the extension is not available on this platform
      # so the original pure Ruby path is used unchanged.
      def log_buffered_fallback
        BufferedIO.log_fallback(@name) if @buffered.nil? and !BufferedIO.extension_loaded?
      end
    end
  end
end
