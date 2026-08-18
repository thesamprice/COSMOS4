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
    @extension_loaded = false
    @extension_error = nil
    @fallback_logged = false

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

    # Log (once) why the stock pure Ruby path is being used. The fallback is
    # always automatic - this only makes it visible.
    #
    # @param who [String] Name of the interface or stream falling back
    def self.log_fallback(who)
      return if @fallback_logged or disabled_by_env?
      @fallback_logged = true
      message = "#{who}: buffered I/O extension unavailable "\
                "(#{@extension_error ? @extension_error.message : 'unknown'}) - "\
                "using the stock Ruby stream"
      if defined?(Cosmos::Logger)
        Cosmos::Logger.info(message)
      else
        STDOUT.puts message
      end
    end

    # Reset the memoized fallback log (used by tests)
    def self.reset_fallback_log
      @fallback_logged = false
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
        @ring_bytes = (options[:ring_bytes] || DEFAULT_RING_BYTES).to_i
        # Bytes returned by one read. A read only ever returns what is actually
        # buffered, so a large cap costs nothing when the device is keeping up
        # and lets a starved interface thread drain the whole backlog in a
        # single GVL acquisition instead of one 64 KiB slice per scheduler
        # round trip.
        @read_chunk_bytes = (options[:read_chunk_bytes] || @ring_bytes).to_i
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

      # @return [Hash] Buffered channel statistics for the CmdTlmServer counters
      #   (see BufferedIO.empty_stats). :drop_count stays zero under the default
      #   :backpressure policy - the byte streams are lossless and must stay
      #   lossless - so :stall_count is the counter that says Ruby is falling
      #   behind and the device buffer is next in line.
      def buffered_stats
        stats = BufferedIO.empty_stats
        return stats unless @read_channel or @write_channel
        stats[:buffered] = true
        if @read_channel
          stats[:bytes_read] = @read_channel.bytes_read
          stats[:drop_count] = @read_channel.drop_count
          stats[:stall_count] = @read_channel.stall_count
          stats[:buffered_bytes] = @read_channel.buffered_bytes
          stats[:high_water] = @read_channel.high_water
          stats[:ring_bytes] = @read_channel.ring_bytes
        end
        if @write_channel
          stats[:bytes_written] = @write_channel.bytes_written
          stats[:pending_write_bytes] = @write_channel.pending_write_bytes
        end
        stats
      end

      # (see Stream#read)
      def read
        raise "Attempt to read from write only stream" unless buffered_readable?
        return super() unless @read_channel

        begin
          result = @read_channel.read_with_time(@read_timeout, @read_chunk_bytes)
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
        return super() unless @read_channel

        begin
          result = @read_channel.read_with_time(0, buffered_nonblock_read_bytes)
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
        return super(data) unless @write_channel

        # The C++ writer thread owns the syscall - this only queues, in order.
        buffered_write_lock do
          result = @write_channel.write(data, @write_timeout)
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
        return true unless @write_channel
        @write_channel.flush(timeout)
      end

      # @return [Boolean] Whether the stream is connected
      def connected?
        return false unless super()
        return true unless @read_channel or @write_channel
        channels.each { |channel| return false if channel.stopped? }
        true
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
          # Never let the buffered path break a device Ruby can serve
          BufferedIO.log_fallback(self.class.name)
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

      # @return [Array<Class>] Errors from a buffered read that mean the
      #   descriptor is gone and an empty read is the stock answer. A
      #   disconnected channel raises IOError; transports whose stock stream
      #   swallows more than that say so.
      def buffered_read_errors
        [IOError]
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
        'BUFFERED_OVERFLOW' => :overflow_policy
      }.freeze

      # The BUFFERED_* options every buffered interface accepts
      DEFAULT_OPTION_KEYS = [:ring_bytes, :overflow_policy].freeze

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

      # Supported Options
      # BUFFERED - FALSE disables the buffered C++ backend for this interface
      # BUFFERED_RING_BYTES - Size of the C++ read ring
      # BUFFERED_OVERFLOW - backpressure, drop_oldest or drop_newest. The
      #   default belongs to the transport, not to this module; see
      #   doc/buffered_io_design.md for why the byte streams default to back
      #   pressure while UDP defaults to dropping.
      # (see Interface#set_option)
      #
      # @param option_name (see Interface#set_option)
      # @param option_values (see Interface#set_option)
      def set_option(option_name, option_values)
        super(option_name, option_values)
        name = option_name.to_s.upcase
        if name == 'BUFFERED'
          @buffered = ConfigParser.handle_true_false(option_values[0].to_s)
          return
        end
        key = OPTION_KEYS[name]
        # An option this transport has no use for is ignored, exactly as an
        # unknown option always has been
        return unless key and buffered_option_keys.include?(key)
        @buffered_options[key] = if key == :overflow_policy
                                   option_values[0].to_s.downcase.to_sym
                                 else
                                   Integer(option_values[0])
                                 end
      end

      protected

      # Automatic, logged once: the extension is not available on this platform
      # so the original pure Ruby path is used unchanged.
      def log_buffered_fallback
        BufferedIO.log_fallback(@name) if @buffered.nil? and !BufferedIO.extension_loaded?
      end
    end
  end
end
