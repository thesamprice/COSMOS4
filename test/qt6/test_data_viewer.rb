require_relative 'helper'

require 'cosmos/tools/data_viewer/data_viewer'

LOG_FILE = tlm_log_file

# handle_open_log_file asks for the files through a modal PacketLogDialog.
# helper.rb's modal closer would answer it Rejected and the playback would
# never run, so stand in for the user picking the log: seed the dialog's
# embedded PacketLogFrame the way its Browse button does and accept. The tool
# then runs its real playback loop -- reader, component routing, progress
# dialog and all -- against the demo log.
module Cosmos
  class PacketLogDialog
    def exec
      @packet_log_frame.instance_variable_get(:@filenames).addItem(LOG_FILE)
      Qt::Dialog::Accepted
    end
  end
end

# ---------------------------------------------------------------------------
# Main window. DataViewer requires a config file; the demo's builds four
# components directly and pulls two more out of the INST target.
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Data Viewer'
options.width = 550
options.height = 500
options.start = false     # don't dial the CmdTlmServer
options.replay = false
options.config_file = 'data_viewer.txt'

dv = Cosmos::DataViewer.new(options)
pump(60, 0.05)

check('constructed', dv.is_a?(Cosmos::DataViewer))
check('visible', dv.visible?)
check('titled', dv.windowTitle == 'Data Viewer')

components = dv.instance_variable_get(:@components)
tab_book   = dv.instance_variable_get(:@tab_book)
mapping    = dv.instance_variable_get(:@packet_to_components_mapping)

EXPECTED_COMPONENTS = [
  ['Health Status',       Cosmos::DumpComponent],
  ['ADCS',                Cosmos::DataViewerComponent],
  ['Other Packets',       Cosmos::DataViewerComponent],
  ['Operators',           Cosmos::TextComponent],
  ['INST Health Status',  Cosmos::InstDumpComponent],
  ['INST2 Health Status', Cosmos::InstDumpComponent]
]
check("config built #{components.length} components " \
      "#{components.map(&:tab_name).inspect}",
      components.map { |c| [c.tab_name, c.class] } == EXPECTED_COMPONENTS)
check('the last two came from the TARGET_COMPONENT lines',
      components[4].is_a?(Cosmos::InstDumpComponent) &&
      components[5].is_a?(Cosmos::InstDumpComponent))
check("one tab per component (#{tab_book.count})",
      tab_book.count == EXPECTED_COMPONENTS.length &&
      (0...tab_book.count).map { |i| tab_book.tabText(i) } ==
        EXPECTED_COMPONENTS.map(&:first))
check('AUTO_START parsed out of the config',
      dv.instance_variable_get(:@auto_start) == true)

# The PACKET lines under each COMPONENT build the routing table the playback
# loop and the realtime thread both index into.
check("INST HEALTH_STATUS fans out to two components " \
      "#{mapping['INST HEALTH_STATUS'].map(&:tab_name).inspect}",
      mapping['INST HEALTH_STATUS'].map(&:tab_name) ==
        ['Health Status', 'INST Health Status'])
check('INST ADCS routes to the ADCS component',
      mapping['INST ADCS'].map(&:tab_name) == ['ADCS'])
check('the Other Packets component claimed both of its packets',
      mapping['INST PARAMS'].map(&:tab_name) == ['Other Packets'] &&
      mapping['INST IMAGE'].map(&:tab_name) == ['Other Packets'] &&
      components[2].packets == [['INST', 'PARAMS'], ['INST', 'IMAGE']])
check('SYSTEM META routes to the text component',
      mapping['SYSTEM META'].map(&:tab_name) == ['Operators'])
check('every component starts empty',
      components.all? { |c| c.text.toPlainText.empty? })

screenshot(dv, '/tmp/cosmos_data_viewer_qt6.png')

# ---------------------------------------------------------------------------
# Log playback. handle_open_log_file stops realtime collection, resets the
# components, then reads the log and hands each packet to the components
# registered for it. The rendered text only reaches the widgets when the
# 100ms timer fires update_gui, so pump afterwards.
# ---------------------------------------------------------------------------
dv.send(:handle_open_log_file)
pump(80, 0.05)

check("window title names the log being viewed",
      dv.windowTitle == "Data Viewer : #{LOG_FILE}")

rendered = components.map { |c| [c.tab_name, c.text.toPlainText] }.to_h
rendered.each { |name, text| say "  #{name}: #{text.length} chars" }

check('every component fed by the log rendered text',
      EXPECTED_COMPONENTS[0, 5].all? { |name, _| !rendered[name].empty? })
# SYSTEM META is written once per log file, so the Operators component gets a
# single line while the packet dumps run to tens of thousands of characters.
check('the repeating packets produced bulk text',
      ['Health Status', 'ADCS', 'Other Packets',
       'INST Health Status'].all? { |name| rendered[name].length > 10_000 })
# INST2 is configured but never appears in the demo log, so its component has
# to stay empty rather than pick up another target's packets.
check('the component for a packet absent from the log stayed empty',
      rendered['INST2 Health Status'].empty?)

check('DumpComponent banners name the packet it was given',
      rendered['Health Status'].include?('* INST HEALTH_STATUS') &&
      rendered['Health Status'].include?('* Received Count:'))
check('DumpComponent rendered the raw buffer as hex',
      rendered['Health Status'] =~ /^[0-9A-F]{8}: ([0-9A-F]{2} ){8}/)
check('the INST target component dumped the same packet',
      rendered['INST Health Status'].include?('* INST HEALTH_STATUS') &&
      rendered['INST Health Status'] =~ /^[0-9A-F]{8}: /)

# The plain DataViewerComponent formats the packet with units instead of
# dumping it, so its text carries decommutated item names and values.
check('DataViewerComponent formatted INST ADCS with its item names',
      rendered['ADCS'].include?('* INST ADCS') &&
      rendered['ADCS'].include?('POSPROGRESS: ') &&
      rendered['ADCS'].include?('STAR1ID: '))
# INST IMAGE carries a 16KB block item, and one of them formats to more than
# the 1000 blocks a component keeps, so the Other Packets tab holds the tail
# of a single IMAGE packet with its banner already scrolled off. Reaching the
# 0x3FF0 offset is the proof that the block item was routed and formatted.
check('the Other Packets component rendered the INST IMAGE block item',
      rendered['Other Packets'] =~ /^  [0-9A-F]{8}: ([0-9A-F]{2} ){8}/ &&
      rendered['Other Packets'].include?('  00003FF0: '))

# TextComponent reads a single item and prefixes the received time.
check("TextComponent showed the SYSTEM META item it was configured with " \
      "#{rendered['Operators'].lines.first.to_s.chomp.inspect}",
      rendered['Operators'] =~
        %r{^\d{4}/\d\d/\d\d \d\d:\d\d:\d\d\.\d+ Unspecified$})

check('packet counts are bounded by the components maxBlockCount',
      components.all? { |c| c.text.blockCount <= 1000 })

tab_book.setCurrentIndex(1) # ADCS, the most readable of the six
pump(20)
screenshot(dv, '/tmp/cosmos_data_viewer_run_qt6.png')

# ---------------------------------------------------------------------------
# Reset is what the tool runs before loading another log; it has to clear
# every component, not just the visible one.
# ---------------------------------------------------------------------------
dv.send(:handle_reset)
pump(20)
check('reset cleared every component',
      components.all? { |c| c.text.toPlainText.empty? })

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
dv.close
pump(20)
puts 'TEST_DATA_VIEWER OK'
