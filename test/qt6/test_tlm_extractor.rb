require_relative 'helper'

require 'cosmos/tools/tlm_extractor/tlm_extractor'

# ---------------------------------------------------------------------------
# Main window. TlmExtractor.run() fills these in from the command line; the
# tool reads options.config_file inside the Splash block and loads it into a
# TlmExtractorConfig.
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Telemetry Extractor'
options.width = 700
options.height = 425
options.auto_size = false
options.restore_size = false
options.dart = false          # log file mode, not the DART database
options.config_file = File.join(Cosmos::USERPATH, 'config', 'tools',
                                'tlm_extractor', 'tlm_extractor.txt')

te = Cosmos::TlmExtractor.new(options)
pump(60, 0.05)

check('constructed', te.is_a?(Cosmos::TlmExtractor))
check('visible', te.visible?)
check('titled', te.windowTitle == 'Telemetry Extractor')

config    = te.instance_variable_get(:@tlm_extractor_config)
processor = te.instance_variable_get(:@tlm_extractor_processor)
item_list = te.instance_variable_get(:@config_item_list)
check('config built', config.is_a?(Cosmos::TlmExtractorConfig))
check('processor built', processor.is_a?(Cosmos::TlmExtractorProcessor))
check('item list is the MyListWidget subclass',
      item_list.is_a?(Cosmos::TlmExtractor::MyListWidget))

# The demo config's first line is `<%= render "_adcs_time.txt" %>`, so the two
# time items only appear if ConfigParser ran the ERB pass over the file.
EXPECTED_ITEMS = [
  'ITEM INST ADCS TIMESECONDS',
  'ITEM INST ADCS TIMEFORMATTED',
  'ITEM INST ADCS Q1 RAW',
  'ITEM INST ADCS Q1',
  'ITEM INST ADCS Q1 FORMATTED',
  'ITEM INST ADCS Q1 WITH_UNITS',
  'ITEM INST ADCS VELX RAW',
  'ITEM INST ADCS VELX',
  'ITEM INST ADCS VELX FORMATTED',
  'ITEM INST ADCS VELX WITH_UNITS',
  'ITEM INST ADCS CCSDSSEQFLAGS RAW',
  'ITEM INST ADCS CCSDSSEQFLAGS',
  'ITEM INST ADCS CCSDSSEQFLAGS FORMATTED',
  'ITEM INST ADCS CCSDSSEQFLAGS WITH_UNITS'
]
listed = (0...item_list.count).map { |i| item_list.item(i).text }
check("config file loaded #{listed.length} items into the list",
      listed == EXPECTED_ITEMS)
check('ERB render pulled in the _adcs_time.txt partial',
      listed[0, 2] == ['ITEM INST ADCS TIMESECONDS',
                       'ITEM INST ADCS TIMEFORMATTED'])
check('telemetry chooser and search box populated',
      te.instance_variable_get(:@telemetry_chooser).target_name.to_s.length > 0 &&
      te.instance_variable_get(:@search_box).is_a?(Qt::LineEdit))

screenshot(te, '/tmp/cosmos_tlm_extractor_qt6.png')

# ---------------------------------------------------------------------------
# The item list is a MyListWidget, which overrides keyPressEvent to emit its
# own `enterKeyPressed(int)` signal on Return/Enter. Send a real key event so
# the whole chain runs: Qt dispatch -> Ruby override -> emit -> the connected
# item_list_editor(), which opens a modal "Edit Item" dialog. helper.rb's
# modal closer answers it with done(0) (Rejected), so the list is unchanged.
# ---------------------------------------------------------------------------
modals_before = MODALS_SEEN.length
item_list.setCurrentRow(2)
item_list.item(2).setSelected(true)
check('selected_items sees the selection', item_list.selected_items == [2])

Qt::Application.sendEvent(item_list,
                          Qt::KeyEvent.new(Qt::Event::KeyPress,
                                           Qt::Key_Return, Qt::NoModifier))
pump(30, 0.05)
check("enterKeyPressed(int) opened the item editor #{MODALS_SEEN.last.inspect}",
      MODALS_SEEN.length > modals_before)
check('rejecting the editor left the list alone', item_list.count == 14)

# ---------------------------------------------------------------------------
# Extraction. Seed the log into the PacketLogFrame's list the way its Browse
# button does, point the output at a temp file, then press Process. `process`
# is protected, so send() stands in for the Process button's clicked() slot.
# It runs the work on a ProgressDialog worker thread; helper.rb clicks Done
# once the dialog enables it, which is what lets execute() return.
# ---------------------------------------------------------------------------
log_file = tlm_log_file

plf = te.instance_variable_get(:@packet_log_frame)
plf.instance_variable_get(:@filenames).addItem(log_file)
output = File.join(Dir.tmpdir, 'cosmos_tlm_extractor_qt6.txt')
File.delete(output) if File.exist?(output)
plf.output_filename = output
pump(10)
check('log file queued in the packet log frame', plf.filenames == [log_file])

te.send(:process)
pump(20)

check('output file written', File.exist?(output) && File.size(output) > 0)
lines = File.readlines(output).map(&:chomp)
check("input filename echoed into the output #{lines[0].inspect}",
      lines[0] == log_file)

EXPECTED_COLUMNS = ['TARGET', 'PACKET', 'TIMESECONDS', 'TIMEFORMATTED',
                    'Q1 (RAW)', 'Q1', 'Q1 (FORMATTED)', 'Q1 (WITH_UNITS)',
                    'VELX (RAW)', 'VELX', 'VELX (FORMATTED)',
                    'VELX (WITH_UNITS)', 'CCSDSSEQFLAGS (RAW)',
                    'CCSDSSEQFLAGS', 'CCSDSSEQFLAGS (FORMATTED)',
                    'CCSDSSEQFLAGS (WITH_UNITS)']
columns = lines[2].split("\t")
check("header names one column per config item #{columns.inspect}",
      columns == EXPECTED_COLUMNS)

rows = lines[3..-1].map { |line| line.split("\t") }
check("extracted #{rows.length} data rows", rows.length > 2000)
check('every row is the INST ADCS packet the config asked for',
      rows.all? { |r| r[0] == 'INST' && r[1] == 'ADCS' })
check('every row has a value in every column',
      rows.all? { |r| r.length == EXPECTED_COLUMNS.length })

# Value types have to actually differ from each other, otherwise the config's
# RAW/CONVERTED/FORMATTED/WITH_UNITS requests were all read the same way.
first = rows[0]
check("VELX FORMATTED is the fixed-point rendering of VELX #{first[9]} -> #{first[10]}",
      first[10] == ('%.6g' % first[9].to_f) || first[10].to_f.round(4) == first[9].to_f.round(4))
check("VELX WITH_UNITS carries the units #{first[11].inspect}",
      first[11].end_with?(' MPS'))
check("CCSDSSEQFLAGS RAW is the number and CONVERTED is the state " \
      "#{first[12].inspect} -> #{first[13].inspect}",
      first[12] == '3' && first[13] == 'NOGROUP')
check("Q1 RAW and CONVERTED agree for an unconverted float #{first[4]}",
      first[4].to_f == first[5].to_f && first[4].to_f.abs > 0.0)

times = rows.map { |r| r[2].to_f }
check('rows are in time order', times.each_cons(2).all? { |a, b| b >= a })
check("output spans the whole log (#{(times[-1] - times[0]).round(1)}s)",
      (times[-1] - times[0]) > 200.0)
check("TIMEFORMATTED matches TIMESECONDS #{first[3].inspect}",
      first[3] == Time.at(first[2].to_f).sys.formatted)

screenshot(te, '/tmp/cosmos_tlm_extractor_run_qt6.png')

# ---------------------------------------------------------------------------
# A second run through the Mode menu. Downsample and Matlab header are pulled
# off the widgets by sync_gui_to_config, so a changed output proves the menu
# state reaches TlmExtractorConfig rather than the defaults being reused.
# ---------------------------------------------------------------------------
te.instance_variable_get(:@matlab_header_check).setChecked(true)
te.instance_variable_get(:@downsample_entry).value = 30.0
downsampled = File.join(Dir.tmpdir, 'cosmos_tlm_extractor_qt6_downsampled.txt')
File.delete(downsampled) if File.exist?(downsampled)
plf.output_filename = downsampled
pump(10)

te.send(:process)
pump(20)

check('downsampled output written', File.exist?(downsampled))
check('Matlab header reached the config',
      config.matlab_header == true && config.downsample_seconds == 30.0)
ds_lines = File.readlines(downsampled).map(&:chomp)
check("Matlab header commented out the filename line #{ds_lines[0][0, 3].inspect}",
      ds_lines[0].start_with?('%'))
ds_rows = ds_lines[3..-1].map { |line| line.split("\t") }
check("30s downsample cut #{rows.length} rows to #{ds_rows.length}",
      ds_rows.length > 2 && ds_rows.length < rows.length / 10)
ds_times = ds_rows.map { |r| r[2].to_f }
check('downsampled rows are at least 30s apart',
      ds_times.each_cons(2).all? { |a, b| (b - a) >= 30.0 })
check('downsampled rows still carry the same columns',
      ds_rows.all? { |r| r.length == EXPECTED_COLUMNS.length && r[1] == 'ADCS' })

# ---------------------------------------------------------------------------
# Item list editing. Delete/Backspace is the other half of MyListWidget's
# keyPressEvent override, and the search box's Add Item button is how a user
# puts an item back.
# ---------------------------------------------------------------------------
item_list.clearSelection
item_list.item(13).setSelected(true)
item_list.setCurrentRow(13)
Qt::Application.sendEvent(item_list,
                          Qt::KeyEvent.new(Qt::Event::KeyPress,
                                           Qt::Key_Delete, Qt::NoModifier))
pump(10)
check("Delete removed the selected item (#{item_list.count})",
      item_list.count == 13)

te.instance_variable_get(:@search_box).setText('INST HEALTH_STATUS TEMP1')
te.instance_variable_get(:@search_add_item_button).click
pump(10)
check("Add Item appended the searched item #{item_list.item(item_list.count - 1).text.inspect}",
      item_list.count == 14 &&
      item_list.item(13).text == 'ITEM INST HEALTH_STATUS TEMP1')

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
File.delete(output) if File.exist?(output)
File.delete(downsampled) if File.exist?(downsampled)
te.close
pump(20)
puts 'TEST_TLM_EXTRACTOR OK'
