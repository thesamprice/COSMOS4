require_relative 'helper'

require 'cosmos/tools/table_manager/table_manager'
require 'fileutils'

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Table Manager'
options.width = 800
options.height = 600
options.auto_size = false
options.no_tables = false

tm = Cosmos::TableManager.new(options)
pump(30, 0.05)

check('constructed', tm.is_a?(Cosmos::TableManager))
check('visible', tm.visible?)
check('titled', tm.windowTitle == 'Table Manager')
check('registered as the singleton', Cosmos::TableManager.instance.equal?(tm))
check('core built', tm.core.is_a?(Cosmos::TableManagerCore))
check('tabbook built', tm.tabbook.is_a?(Qt::TabWidget))
menus = (0...tm.menuBar.actions.length).map { |i| tm.menuBar.actions[i].text }
check("menus #{menus.inspect}", menus == ['&File', '&Table', '&Help'])

# ---------------------------------------------------------------------------
# Create a new binary from a demo table definition. ConfigTables_def.txt pulls
# in three definitions via TABLEFILE, covering a ONE_DIMENSIONAL table with
# states/hidden/uneditable items, a 200 row TWO_DIMENSIONAL table, and a table
# whose items render as checkboxes.
# ---------------------------------------------------------------------------
DEF_DIR = File.join(Cosmos::USERPATH, 'config', 'tools', 'table_manager')
OUT_DIR = File.join(Cosmos::System.paths['TABLES'], 'qt6_test')
FileUtils.rm_rf(OUT_DIR)
FileUtils.mkdir_p(OUT_DIR)

def_path = File.join(DEF_DIR, 'ConfigTables_def.txt')
bin_path = tm.core.file_new(def_path, OUT_DIR)

check("created #{File.basename(bin_path)}", File.file?(bin_path))
expected_length = tm.core.config.tables.values.map(&:length).reduce(:+)
check("binary is the definition length (#{File.size(bin_path)} == #{expected_length})",
      File.size(bin_path) == expected_length)
# file_save also drops a CSV report next to the binary
csv_path = File.join(OUT_DIR, 'ConfigTables.csv')
check('report written alongside the binary', File.file?(csv_path))

# ---------------------------------------------------------------------------
# Open it back and check the GUI the definition built
# ---------------------------------------------------------------------------
tm.file_open(bin_path, def_path)
pump(30, 0.05)

check('binary filename shown', tm.instance_variable_get(:@table_bin_label).text == bin_path)
check('definition filename shown', tm.instance_variable_get(:@table_def_label).text == def_path)

tab_names = (0...tm.tabbook.count).map { |i| tm.tabbook.tabText(i) }
check("tabs #{tab_names.inspect}",
      tab_names == ['MC CONFIGURATION', 'TLM MONITORING', 'PPS SELECTION'])

mc = tm.tabbook.tab('MC CONFIGURATION')
tlm = tm.tabbook.tab('TLM MONITORING')
pps = tm.tabbook.tab('PPS SELECTION')

# A ONE_DIMENSIONAL table is one "Value" column with an item per row. The two
# HIDDEN pad items in the definition must not get rows.
check("MC Configuration is #{mc.rowCount}x#{mc.columnCount}",
      mc.rowCount == 14 && mc.columnCount == 1)
check('hidden items are not displayed',
      tm.core.config.table('MC CONFIGURATION').sorted_items.length == 16)
mc_rows = (0...mc.rowCount).map { |r| mc.verticalHeaderItem(r).text }
check("MC Configuration row headers #{mc_rows.first.inspect}..#{mc_rows.last.inspect}",
      mc_rows.first == 'SCRUB REGION 1 START ADDR' && mc_rows.last == 'BINARY')
check('single Value column', mc.horizontalHeaderItem(0).text == 'Value')

def row_of(gui_table, name)
  (0...gui_table.rowCount).find { |r| gui_table.verticalHeaderItem(r).text == name }
end

# Defaults come from the definition, formatted through each item's
# FORMAT_STRING / states / data type
mc_values = Hash[mc_rows.each_with_index.map { |name, r| [name, mc.item(r, 0).text] }]
check("FORMAT_STRING applied (#{mc_values['SCRUB REGION 1 END ADDR']})",
      mc_values['SCRUB REGION 1 END ADDR'] == '0x3FFFFFF')
check("plain decimal item (#{mc_values['SCRUB REGION 2 THROTTLE COUNT']})",
      mc_values['SCRUB REGION 2 THROTTLE COUNT'] == '6000')
check("state item shows its state name (#{mc_values['MEMORY SCRUBBING']})",
      mc_values['MEMORY SCRUBBING'] == 'ENABLE')
check("binary item shown as hex (#{mc_values['BINARY']})",
      mc_values['BINARY'] == '0xDEADBEEF')

# TWO_DIMENSIONAL tables put the items across the columns and repeat them for
# each of the definition's rows
check("TLM Monitoring is #{tlm.rowCount}x#{tlm.columnCount}",
      tlm.rowCount == 200 && tlm.columnCount == 9)
tlm_cols = (0...tlm.columnCount).map { |c| tlm.horizontalHeaderItem(c).text }
check("TLM Monitoring columns #{tlm_cols.inspect}",
      tlm_cols == ['THRESHOLD', 'OFFSET', 'DATA SIZE', 'BIT MASK', 'PERSISTENCE',
                   'TYPE', 'ACTION', 'GROUP', 'SIGNED'])
check('TLM Monitoring rows are numbered from 1',
      tlm.verticalHeaderItem(0).text == '1' && tlm.verticalHeaderItem(199).text == '200')
check('TLM Monitoring row 1 defaults',
      (0...tlm.columnCount).map { |c| tlm.item(0, c).text } ==
      ['0', '0', 'BITS', '0', '0', 'LESS_THAN', 'NO_ACTION_REQUIRED',
       'ALL_MODES', 'NOT_APPLICABLE'])
check('the last row is populated too',
      tlm.item(199, 5).text == 'LESS_THAN')

# Items whose only states are CHECKED/UNCHECKED render as checkboxes rather
# than text, and UNEDITABLE drops the selectable/enabled flags.
check("PPS Selection is #{pps.rowCount}x#{pps.columnCount}",
      pps.rowCount == 2 && pps.columnCount == 1)
primary = pps.item(row_of(pps, 'PRIMARY PPS'), 0)
redundant = pps.item(row_of(pps, 'REDUNDANT PPS'), 0)
check("checkbox item carries no text (#{primary.text.inspect})", primary.text == '')
check('checkbox item defaults to checked', primary.checkState == Qt::Checked)
check("editable checkbox flags (#{primary.flags})",
      primary.flags == (Qt::ItemIsSelectable | Qt::ItemIsEnabled |
                        Qt::ItemIsUserCheckable | Qt::ItemIsTristate))
check("UNEDITABLE checkbox flags (#{redundant.flags})",
      redundant.flags == (Qt::ItemIsUserCheckable | Qt::ItemIsTristate))
mc_editable = mc.item(row_of(mc, 'SCRUB REGION 1 START ADDR'), 0)
check("editable text flags (#{mc_editable.flags})",
      mc_editable.flags == (Qt::ItemIsSelectable | Qt::ItemIsEnabled | Qt::ItemIsEditable))

screenshot(tm, '/tmp/cosmos_table_manager_qt6.png')

# ---------------------------------------------------------------------------
# ComboBoxItemDelegate turns any editable cell whose item has states into a
# combobox listing those states
# ---------------------------------------------------------------------------
tm.tabbook.setCurrentIndex(0)
pump(5)
check('current table follows the tab', tm.current_table_name == 'MC CONFIGURATION')

scrub_row = row_of(mc, 'MEMORY SCRUBBING')
mc.openPersistentEditor(mc.item(scrub_row, 0))
pump(10)
editor = mc.cellWidget(scrub_row, 0)
check("state cell editor is #{editor.class}", editor.is_a?(Qt::ComboBox))
check("combobox lists the states (#{(0...editor.count).map { |i| editor.itemText(i) }.join(',')})",
      (0...editor.count).map { |i| editor.itemText(i) } == ['DISABLE', 'ENABLE'])
check('combobox starts on the current value', editor.currentText == 'ENABLE')
mc.closePersistentEditor(mc.item(scrub_row, 0))
pump(5)

# A plain item has no states, so the delegate falls through to super
plain_row = row_of(mc, 'SCRUB REGION 2 THROTTLE COUNT')
mc.openPersistentEditor(mc.item(plain_row, 0))
pump(10)
check('plain cell does not get a combobox',
      !mc.cellWidget(plain_row, 0).is_a?(Qt::ComboBox))
mc.closePersistentEditor(mc.item(plain_row, 0))
pump(5)

# ---------------------------------------------------------------------------
# cellEntered puts the hovered item's description in the status bar. The
# lookup differs per table type: a row header name for ONE_DIMENSIONAL, a
# column header name plus the row number for TWO_DIMENSIONAL.
# ---------------------------------------------------------------------------
tm.send(:mouse_over, row_of(mc, 'DUMP PACKET THROTTLE (SEC)'), 0)
pump(3)
check("status bar shows the 1D description (#{tm.statusBar.currentMessage.inspect})",
      tm.statusBar.currentMessage ==
      'Number of seconds to wait between dumping large packets')

tm.tabbook.setCurrentIndex(1)
pump(5)
check('current table follows the tab', tm.current_table_name == 'TLM MONITORING')
tm.send(:mouse_over, 4, 0)
pump(3)
check("status bar shows the 2D description (#{tm.statusBar.currentMessage.inspect})",
      tm.statusBar.currentMessage ==
      'Telemetry item threshold at which point persistance is incremented')
tm.tabbook.setCurrentIndex(0)
pump(5)

# ---------------------------------------------------------------------------
# Edit cells, save, and re-open to prove the edits reached the binary
# ---------------------------------------------------------------------------
check('window title is unmarked before editing', tm.windowTitle == 'Table Manager')

type_col = tlm_cols.index('TYPE')
mc.item(plain_row, 0).setText('1234')
tlm.item(3, type_col).setText('GREATER_THAN')
pps.item(row_of(pps, 'PRIMARY PPS'), 0).setCheckState(Qt::Unchecked)
pump(10)
check('editing marks the window modified', tm.windowTitle == 'Table Manager *')

original_bytes = File.binread(bin_path)
tm.file_save
pump(30, 0.05)
check('saving clears the modified marker', tm.windowTitle == 'Table Manager')
saved_bytes = File.binread(bin_path)
check('binary changed on disk', saved_bytes != original_bytes)
check('binary kept its definition length', saved_bytes.length == expected_length)

tm.file_close
pump(10)
check('closing empties the tab book', tm.tabbook.count == 0)
check('closing clears the filename labels',
      tm.instance_variable_get(:@table_bin_label).text == '')

tm.file_open(bin_path, def_path)
pump(30, 0.05)
mc = tm.tabbook.tab('MC CONFIGURATION')
tlm = tm.tabbook.tab('TLM MONITORING')
pps = tm.tabbook.tab('PPS SELECTION')
check('re-opening rebuilds exactly three tabs', tm.tabbook.count == 3)
check("edited decimal persisted (#{mc.item(plain_row, 0).text})",
      mc.item(plain_row, 0).text == '1234')
check("edited 2D state persisted (#{tlm.item(3, type_col).text})",
      tlm.item(3, type_col).text == 'GREATER_THAN')
check('unedited 2D neighbour untouched', tlm.item(2, type_col).text == 'LESS_THAN')
check('cleared checkbox persisted',
      pps.item(row_of(pps, 'PRIMARY PPS'), 0).checkState == Qt::Unchecked)
# The underlying packet, not just the widget, holds the new values
check('binary holds the new value',
      tm.core.config.table('MC CONFIGURATION').read('SCRUB REGION 2 THROTTLE COUNT') == 1234)
check('binary holds the cleared checkbox',
      tm.core.config.table('PPS SELECTION').read('PRIMARY PPS') == 'UNCHECKED')

screenshot(tm, '/tmp/cosmos_table_manager_qt6_open.png')

# ---------------------------------------------------------------------------
# Check / default / hex / report. Each of these puts up a modal dialog that
# the helper's modal closer dismisses.
# ---------------------------------------------------------------------------
check('file_check passes on the saved file', tm.file_check(false) == true)
check('core reports every table in range',
      tm.core.file_check == 'All parameters are within their constraints.')
check('table_check finds nothing wrong in MC Configuration',
      tm.core.table_check('MC CONFIGURATION').empty?)

hex = tm.core.file_hex
check("file hex dump covers the whole file (#{hex.lines.last.chomp})",
      hex.include?("Total Bytes Read: #{expected_length}"))
tm.send(:display_hex, :table)
pump(20)
tm.send(:display_hex, :file)
pump(20)
check('hex dumps opened and closed',
      MODALS_SEEN.count('Cosmos::HexDumpDialog') == 2)

tm.file_report
pump(20)
report = File.read(csv_path)
check('report names every table',
      report.include?('MC CONFIGURATION') && report.include?('TLM MONITORING') &&
      report.include?('PPS SELECTION'))
check('report holds the edited value', report.include?('SCRUB REGION 2 THROTTLE COUNT, 1234,'))
check('report has the two dimensional column headers',
      report.include?('Item, THRESHOLD, OFFSET, DATA SIZE'))

# Revert to the definition defaults and confirm the edit is gone
tm.table_default
pump(20)
mc = tm.tabbook.tab('MC CONFIGURATION')
check("table_default restored the default (#{mc.item(plain_row, 0).text})",
      mc.item(plain_row, 0).text == '6000')
check('table_default marks the window modified', tm.windowTitle == 'Table Manager *')
check('other tables are untouched by table_default',
      tm.tabbook.tab('TLM MONITORING').item(3, type_col).text == 'GREATER_THAN')

# Leave the window unmodified so closeEvent does not ask to discard changes
tm.file_save
pump(30, 0.05)
check('final save leaves the window unmarked', tm.windowTitle == 'Table Manager')

# ---------------------------------------------------------------------------
# Right-click context menu. context_menu() ends in Qt::Menu#exec, which used
# to be a blocking C++ nested loop -- undismissable headless and holding the
# GVL while it ran. It is now the Ruby-driven popup() loop in qt6.rb, so a
# headless run can both survive it and drive it.
# ---------------------------------------------------------------------------
mc = tm.tabbook.tab('MC CONFIGURATION')
point = mc.visualItemRect(mc.item(plain_row, 0)).center
check('the context menu point lands on an item', !mc.itemAt(point).nil?)

# Unattended: the helper's popup arm closes the menu, so exec returns nil and
# context_menu comes back instead of hanging.
before_popups = POPUPS_SEEN.length
started = Time.now
tm.send(:context_menu, point)
elapsed = Time.now - started
check("unattended context menu closes itself (#{elapsed.round(2)}s)", elapsed < 5)
check('the popup arm saw the menu', POPUPS_SEEN.length == before_popups + 1)
check('a dismissed menu changes nothing', mc.item(plain_row, 0).text == '6000')

# Opt-in: claim the menu through POPUP_HANDLERS and fire one of its actions
mc.item(plain_row, 0).setText('4242')
pump(10)
check("cell edited before driving the menu (#{mc.item(plain_row, 0).text})",
      mc.item(plain_row, 0).text == '4242')

titles = nil
POPUP_HANDLERS << lambda do |menu|
  titles = menu.actions.map { |action| action.text }
  chosen = menu.actions.find { |action| action.text == 'Default' }
  chosen.trigger if chosen
  menu.close
  true
end
begin
  tm.send(:context_menu, point)
ensure
  POPUP_HANDLERS.clear
end
check("context menu offers #{titles.inspect}", titles == ['Details', 'Default'])
pump(10)
check("the Default action restored the default (#{mc.item(plain_row, 0).text})",
      mc.item(plain_row, 0).text == '6000')
check('the Default action reached the packet',
      tm.core.config.table('MC CONFIGURATION').read('SCRUB REGION 2 THROTTLE COUNT') == 6000)

tm.file_save
pump(30, 0.05)
check('context menu work leaves the window unmarked', tm.windowTitle == 'Table Manager')

tm.close
pump(20)
puts 'TEST_TABLE_MANAGER OK'
