# encoding: ascii-8bit

# Copyright 2014 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'cosmos/tools/cmd_tlm_server/connections'
require 'cosmos/io/buffered_io'

module Cosmos

  # Controls the interfaces as defined in the Command/Telemetry configuration
  # file. Interfaces provide the connection between the Command and Telemetry
  # Server and targets. They send command packets to and receive telemetry
  # packets from targets.
  class Interfaces < Connections

    # @param cmd_tlm_server_config [CmdTlmServerConfig] The configuration which
    #   defines all the routers
    # @param identified_packet_callback [#call(Packet)] Callback which is called
    #   when a packet has been  received from the interface and identified.
    def initialize(cmd_tlm_server_config, identified_packet_callback = nil)
      super(:INTERFACES, cmd_tlm_server_config)
      @identified_packet_callback = identified_packet_callback
    end

    # Get the targets of an interface
    #
    # @param interface_name [String] Interface to return target list
    # @return [Array<String>] All the targets mapped to this interface
    def targets(interface_name)
      interface = @config.interfaces[interface_name.upcase]
      raise "Unknown interface: #{interface_name}" unless interface
      interface.target_names
    end

    # Determines all targets in the system and maps them to the given interface
    #
    # @param interface_name [String] The interface to map all targets to
    def map_all_targets(interface_name)
      interface = @config.interfaces[interface_name.upcase]
      raise "Unknown interface: #{interface_name}" unless interface
      System.targets.each do |target_name, target|
        target.interface = interface
        interface.target_names << target_name
      end
    end

    # Maps a target to an interface and unmaps the target from its existing
    # interface if present.
    #
    # @param target_name [String] The name of the target to map
    # @param interface_name [String] The name of the interface to map the
    #   target to
    def map_target(target_name, interface_name)
      # Find the new interface
      new_interface = @config.interfaces[interface_name.upcase]
      raise "Unknown interface: #{interface_name}" unless new_interface

      # Find the target
      target = System.targets[target_name.upcase]
      raise "Unknown target: #{target_name}" unless target

      # Find the old interface
      old_interface = System.targets[target_name.upcase].interface

      # Remove target from old interface
      old_interface.target_names.delete(target_name.upcase) if old_interface

      # Add target to new interface
      new_interface.target_names << target_name.upcase unless new_interface.target_names.include? target_name.upcase

      # Update targets
      System.targets[target_name.upcase].interface = new_interface
    end

    # Recreate an interface with new initialization parameters
    #
    # @param interface_name [String] Name of the interface
    # @param params [Array] Array of parameters to pass to the interface
    #   constructor
    def recreate(interface_name, *params)
      interface = @config.interfaces[interface_name.upcase]
      raise "Unknown interface: #{interface_name}" unless interface

      # Build New Interface
      new_interface = interface.class.new(*params)
      interface.copy_to(new_interface)

      # Replace interface for targets
      System.targets.each do |target_name, target|
        target.interface = new_interface if target.interface == interface
      end

      # Replace interface for routers
      @config.routers.each do |router_name, router|
        if router.interfaces.include?(interface)
          router.interfaces.delete(interface)
          router.interfaces << new_interface
        end
      end

      # Replace interface in @interfaces array
      @config.interfaces[interface_name.upcase] = new_interface

      # Make sure there is no thread
      stop_thread(interface)

      return new_interface
    end

    # Get info about an interface by name
    #
    # The first eight elements are exactly what they have always been. A ninth
    # element was appended for the buffered C++ backends: a Hash of that
    # interface's buffered counters (see {#buffered_info}). Appending keeps
    # every existing caller working - the response is a superset of the old
    # one - and a Hash means future counters need no further API change.
    #
    # @return [Array<String, Numeric, Numeric, Numeric, Numeric, Numeric,
    #   Numeric, Numeric, Hash>] Array containing \[state, num_clients,
    #   write_queue_size, read_queue_size, bytes_written, bytes_read,
    #   write_count, read_count, buffered_info] for the interface
    def get_info(interface_name)
      interface = @config.interfaces[interface_name.upcase]
      raise "Unknown interface: #{interface_name}" unless interface

      return [state(interface_name),      interface.num_clients,
              interface.write_queue_size, interface.read_queue_size,
              interface.bytes_written,    interface.bytes_read,
              interface.write_count,      interface.read_count,
              buffered_info(interface)]
    end

    # Buffered C++ backend counters for an interface, with String keys so the
    # shape is the same whether the caller went through JSON-RPC or called the
    # API directly.
    #
    # 'drop_count' is data the ring threw away - always zero for the byte
    # streams under their default :backpressure policy, and for UDP the loss
    # that used to happen invisibly inside SO_RCVBUF. 'stall_count' is the
    # earlier warning: the reader had to stop reading the device because Ruby
    # was not draining the ring.
    #
    # An interface with no buffered backend (stock stream, extension not
    # built, OPTION BUFFERED FALSE, a router) reports 'buffered' => false and
    # zeros rather than nothing at all, so a display never has to special case
    # it.
    #
    # @param interface [Interface] The interface to interrogate
    # @return [Hash<String, Object>]
    def buffered_info(interface)
      stats = if interface.respond_to?(:buffered_stats)
                interface.buffered_stats
              else
                BufferedIO.empty_stats
              end
      info = {}
      stats.each { |key, value| info[key.to_s] = value }
      info
    rescue Exception
      # Statistics must never be able to break the status display
      {}
    end

    protected

    # Start an interface's packet reading thread
    def start_thread(interface)
      Logger.info "Creating thread for interface #{interface.name}"
      interface_thread = InterfaceThread.new(interface)
      interface_thread.identified_packet_callback = @identified_packet_callback
      interface_thread.start
    end

    # Stop an interface's packet reading thread
    def stop_thread(interface)
      if interface.thread
        Logger.info "Killing thread for interface #{interface.name}"
        to_stop = interface.thread
        interface.thread = nil
        to_stop.stop
      end
    end

  end # class Interfaces

end # module Cosmos
