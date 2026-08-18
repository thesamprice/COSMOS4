# encoding: ascii-8bit

# Copyright 2026 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

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
  end
end
