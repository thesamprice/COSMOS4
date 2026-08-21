# encoding: ascii-8bit

# Copyright 2017 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'cosmos/interfaces/interface'

module Cosmos
  # Base class for interfaces that act read and write from a stream
  class StreamInterface < Interface
    attr_accessor :stream

    def initialize(protocol_type = nil, protocol_args = [])
      super()
      @stream = nil
      @protocol_type = ConfigParser::handle_nil(protocol_type)
      @protocol_args = protocol_args
      if @protocol_type
        protocol_class_name = protocol_type.to_s.capitalize << 'Protocol'
        klass = Cosmos.require_class(protocol_class_name.class_name_to_filename)
        add_protocol(klass, protocol_args, :READ_WRITE)
      end
    end

    def connect
      super()
      @stream.connect if @stream
    end

    def connected?
      if @stream
        @stream.connected?
      else
        false
      end
    end

    def disconnect
      @stream.disconnect if @stream
      super()
    end

    def read_interface
      begin
        data = @stream.read
      rescue Timeout::Error
        Logger.instance.error "#{@name}: Timeout waiting for data to be read"
        data = nil
      end
      return nil if data.nil? or data.length <= 0
      read_interface_base(data)
      # read_interface_base stamps @read_raw_data_time with Time.now, which is
      # when this Ruby thread got scheduled - not when the data arrived. Under
      # load those differ by however long the GVL was held elsewhere, and that
      # error lands straight in the packet's received_time. A buffered stream
      # knows the real answer: the C++ reader thread stamped the first byte of
      # this chunk the instant the kernel handed it over, without the GVL. Use
      # it when it is there, leave the stock timestamp alone when it is not
      # (stock stream, unbuffered build, or a channel that was just released).
      stream = @stream
      if stream.respond_to?(:last_read_time_f)
        received_time = stream.last_read_time_f
        @read_raw_data_time = Time.at(received_time).sys if received_time
      end
      data
    end

    def write_interface(data)
      write_interface_base(data)
      @stream.write(data)
    end
  end
end
