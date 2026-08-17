require_relative 'helper'

require 'cosmos/tools/packet_viewer/packet_viewer'

options = default_tool_options
options.title = 'Packet Viewer'
options.auto_size = false
options.packet = nil
options.rate = 1.0

pv = Cosmos::PacketViewer.new(options)
pump(30, 0.05)
check('constructed', pv.is_a?(Cosmos::PacketViewer))
check('visible', pv.visible?)
screenshot(pv, '/tmp/cosmos_packet_viewer_qt6.png')
pv.close
pump(30)
puts 'TEST_PACKET_VIEWER OK'
