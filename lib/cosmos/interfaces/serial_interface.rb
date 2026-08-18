# encoding: ascii-8bit

# Copyright 2017 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'cosmos/interfaces/stream_interface'
require 'cosmos/io/buffered_io'
require 'cosmos/streams/serial_stream'
require 'cosmos/streams/buffered_serial_stream'

module Cosmos
  # Provides a base class for interfaces that use serial ports
  #
  # Serial is the transport where GVL starvation costs data. The tty input
  # buffer is typically 16 KiB: while another Ruby thread holds the GVL this
  # interface's thread is not scheduled, the UART keeps shifting bytes in, and
  # the driver throws away whatever no longer fits - silently, uncounted, in
  # the middle of a frame. By default this interface therefore reads through a
  # {BufferedSerialStream}, whose C++ reader thread never touches a Ruby API
  # and parks the bytes in a 16 MiB user space ring. Ruby still opens the port
  # and performs every bit of the termios configuration.
  #
  # Buffering is skipped - silently, logged once - when the extension is not
  # built, when COSMOS_NO_BUFFERED_IO is set, when the interface is configured
  # with OPTION BUFFERED FALSE, or when the port is anything other than a real
  # POSIX tty (Windows, JRuby, a mocked driver).
  class SerialInterface < StreamInterface
    # Creates a serial interface which uses the specified stream protocol.
    #
    # @param write_port_name [String] The name of the serial port to write
    # @param read_port_name [String] The name of the serial port to read
    # @param baud_rate [Integer] The serial port baud rate
    # @param parity [Symbol] The parity which is normally :NONE.
    #   Must be one of :NONE, :EVEN, or :ODD.
    # @param stop_bits [Integer] The number of stop bits which is normally 1.
    # @param write_timeout [Integer] The number of seconds to attempt the write
    #   before aborting
    # @param read_timeout [Integer] The number of seconds to attempt to read
    #   data from the serial port before aborting
    # @param protocol_type [String] Combined with 'Protocol' to resolve
    #   to a COSMOS protocol class
    # @param protocol_args [Array] Arguments to pass to the protocol constructor
    def initialize(write_port_name,
                   read_port_name,
                   baud_rate,
                   parity,
                   stop_bits,
                   write_timeout,
                   read_timeout,
                   protocol_type = nil,
                   *protocol_args)
      super(protocol_type, protocol_args)

      @write_port_name = ConfigParser.handle_nil(write_port_name)
      @read_port_name = ConfigParser.handle_nil(read_port_name)
      @baud_rate = baud_rate
      @parity = parity.to_s.intern
      @stop_bits = stop_bits
      @write_timeout = write_timeout
      @read_timeout = read_timeout
      @write_allowed = false unless @write_port_name
      @write_raw_allowed = false unless @write_port_name
      @read_allowed = false unless @read_port_name
      @flow_control = :NONE
      @data_bits = 8
      @struct = []
      # nil means "use the buffered backend if it is available" (the default).
      # OPTION BUFFERED FALSE or COSMOS_NO_BUFFERED_IO force the stock stream.
      @buffered = nil
      @buffered_options = {}
    end

    # Creates a new {BufferedSerialStream} (the default) or {SerialStream}
    # using the parameters passed in the constructor
    def connect
      @stream = build_stream()
      super()
    end

    # @return [Boolean] Whether this interface reads and writes through the
    #   buffered C++ backend
    def buffered?
      return false if @buffered == false
      BufferedIO.available?
    end

    # Supported Options
    # FLOW_CONTROL - Flow control method NONE or RTSCTS. Defaults to NONE
    # DATA_BITS - How many data bits to use
    # STRUCT - Directly set fields in the Win32 DCB or POSIX termios structure
    # BUFFERED - FALSE disables the buffered C++ backend for this interface
    # BUFFERED_RING_BYTES - Size of the C++ read ring (default 16 MiB)
    # BUFFERED_OVERFLOW - backpressure (default), drop_oldest or drop_newest.
    #   See doc/buffered_io_design.md for why a byte stream defaults to back
    #   pressure while UDP defaults to dropping.
    def set_option(option_name, option_values)
      super(option_name, option_values)
      case option_name.to_s.upcase
      when 'FLOW_CONTROL'
        @flow_control = option_values[0]
      when 'DATA_BITS'
        @data_bits = option_values[0].to_i
      when 'STRUCT'
        @struct << option_values
      when 'BUFFERED'
        @buffered = ConfigParser.handle_true_false(option_values[0].to_s)
      when 'BUFFERED_RING_BYTES'
        @buffered_options[:ring_bytes] = Integer(option_values[0])
      when 'BUFFERED_OVERFLOW'
        @buffered_options[:overflow_policy] = option_values[0].to_s.downcase.to_sym
      end
    end

    protected

    def build_stream
      if buffered?
        BufferedSerialStream.new(
          @write_port_name,
          @read_port_name,
          @baud_rate,
          @parity,
          @stop_bits,
          @write_timeout,
          @read_timeout,
          @flow_control,
          @data_bits,
          @struct,
          @buffered_options
        )
      else
        # Automatic, logged once: the extension is not available on this
        # platform so the original pure Ruby stream is used unchanged.
        BufferedIO.log_fallback(@name) if @buffered.nil? and !BufferedIO.extension_loaded?
        SerialStream.new(
          @write_port_name,
          @read_port_name,
          @baud_rate,
          @parity,
          @stop_bits,
          @write_timeout,
          @read_timeout,
          @flow_control,
          @data_bits,
          @struct
        )
      end
    end
  end
end
