require_relative 'helper'

require 'cosmos/tools/cmd_sequence/cmd_sequence'

# Work in a scratch directory so the demo tree is not written to. file_export
# derives its default filename from @sequence_dir, so pointing that here also
# controls where the export dialog opens.
SEQ_DIR = File.join(Dir.tmpdir, 'cosmos_cmd_sequence_qt6')
FileUtils.rm_rf(SEQ_DIR)
FileUtils.mkdir_p(SEQ_DIR)

# The exporter prompts with QFileDialog.getSaveFileName pre-filled with a
# default name; accept it unchanged, which is the user pressing Save. (Qt's
# selectFile is a no-op while the visible dialog's line edit has focus, so
# taking the default is also the only stable way to drive it headless.)
CHOSEN_EXPORT = []
MODAL_HANDLERS << lambda do |modal|
  next false unless modal.is_a?(Qt::FileDialog)
  CHOSEN_EXPORT << modal.selectedFiles.first
  modal.accept
  true
end

# ---------------------------------------------------------------------------
# Helpers for reaching into the CmdParams table a SequenceItem builds. Each
# row is [packet_item, value_item, state_value_item]; for a parameter with
# states the value item holds the state *name* and the state value item the
# raw number, and editing either syncs the other through the table's
# itemChanged handler.
# ---------------------------------------------------------------------------
def param_row(item, name)
  cmd_params = item.instance_variable_get(:@cmd_params)
  cmd_params.instance_variable_get(:@param_widgets).find do |packet_item, _v, _s|
    packet_item.name == name
  end
end

def set_param(item, name, value)
  _packet_item, value_item, _state_value_item = param_row(item, name)
  value_item.setText(value.to_s)
end

# ---------------------------------------------------------------------------
# Main window. The demo's cmd_sequence.txt declares an EXPORTER, which is what
# puts the Export action in the File menu and gives file_export something to
# call.
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Command Sequence'
options.width = 800
options.height = 600
options.config_file = File.join(Cosmos::USERPATH,
                                'config/tools/cmd_sequence/cmd_sequence.txt')

cs = Cosmos::CmdSequence.new(options)
cs.resize(800, 600)
pump(80, 0.05)

check('constructed', cs.is_a?(Cosmos::CmdSequence))
check('visible', cs.visible?)
check('titled for an unsaved sequence',
      cs.windowTitle == 'Command Sequence : Untitled')
check('EXPORTER keyword built the exporter from the config file',
      cs.instance_variable_get(:@exporter).is_a?(Cosmos::CmdSequenceExporter))

sequence_list = cs.instance_variable_get(:@sequence_list)
target_select = cs.instance_variable_get(:@target_select)
cmd_select = cs.instance_variable_get(:@cmd_select)
check('sequence list built', sequence_list.is_a?(Cosmos::SequenceList))
check('sequence starts empty', sequence_list.empty?)
check('sequence starts unmodified', sequence_list.modified? == false)

targets = (0...target_select.count).map { |i| target_select.itemText(i) }
check("targets with non-hidden commands offered #{targets.inspect}",
      targets.include?('INST') && targets.include?('INST2') &&
      !targets.include?('UNKNOWN'))

target_select.setCurrentText('INST')
cs.send(:update_commands)
pump(10)
commands = (0...cmd_select.count).map { |i| cmd_select.itemText(i) }
visible_commands = Cosmos::System.commands.packets('INST')
                                .reject { |_name, packet| packet.hidden }.keys.sort
check("INST's #{visible_commands.length} non-hidden commands listed, sorted",
      commands == visible_commands && commands.include?('COLLECT') &&
      commands.include?('ABORT'))

# ---------------------------------------------------------------------------
# Add a command through the GUI path: the Add button reads the two combo
# boxes and hands them to SequenceList#add.
# ---------------------------------------------------------------------------
cmd_select.setCurrentText('COLLECT')
cs.send(:add_command)
pump(25)

check('sequence no longer empty', !sequence_list.empty?)
check("one item in the sequence (#{sequence_list.to_a.length})",
      sequence_list.to_a.length == 1)
collect = sequence_list.to_a[0]
check('the item is a SequenceItem', collect.is_a?(Cosmos::SequenceItem))
# SequenceList emits its Ruby-defined modified() signal on add, which
# CmdSequence has connected to update_title.
check("adding marked the sequence modified and starred the title (#{cs.windowTitle})",
      sequence_list.modified? && cs.windowTitle == 'Command Sequence : Untitled*')
check('a new item defaults to a zero relative delay', collect.time == '0.00')

# COLLECT's TYPE is a required state parameter, so CmdParams deliberately
# blanks it -- the user has to choose. Saving before that is an error.
type_item, type_value, type_state = param_row(collect, 'TYPE')
check('TYPE is declared required', type_item.required)
check('required state parameter starts blank in both columns',
      type_value.text == '' && type_state.text == '')
raised = begin
  collect.save
  nil
rescue => error
  error.message
end
check("saving with a blank required parameter is refused (#{raised})",
      raised == 'TYPE is required.')
# The non-required parameters keep their defaults.
check('non-required parameters defaulted',
      param_row(collect, 'DURATION')[1].text == '1.0' &&
      param_row(collect, 'OPCODE')[1].text == '0xAB')

# ---------------------------------------------------------------------------
# Choosing a state. Writing the state name into column 1 makes the table's
# itemChanged handler look the name up and write the raw value into column 2,
# then emit modified() -- which propagates CmdParams -> SequenceItem ->
# SequenceList -> CmdSequence, all Ruby-defined signals.
# ---------------------------------------------------------------------------
set_param(collect, 'TYPE', 'NORMAL')
pump(15)
check('choosing the NORMAL state filled in its raw value',
      type_value.text == 'NORMAL' && type_state.text == '0')
check('the item now renders a complete command string',
      collect.command_string ==
      'INST COLLECT with TYPE NORMAL, DURATION 1.0, OPCODE 171, TEMP 0.0')
check('the item saves as a COMMAND line',
      collect.save == 'COMMAND "0.00" "INST COLLECT with TYPE NORMAL, DURATION 1.0, OPCODE 171, TEMP 0.0"')

# INST declares STATE SPECIAL 1 HAZARDOUS, and set_cmd_name_info re-checks
# that on every change.
cmd_info = collect.instance_variable_get(:@cmd_info)
check('NORMAL is not flagged hazardous', cmd_info.text == '')
set_param(collect, 'TYPE', 'SPECIAL')
pump(15)
check('selecting the SPECIAL state raised the hazardous marker',
      type_state.text == '1' && cmd_info.text == '(Hazardous)')
set_param(collect, 'TYPE', 'NORMAL')
pump(15)
check('going back to NORMAL cleared the hazardous marker', cmd_info.text == '')

# ---------------------------------------------------------------------------
# A second command, with a relative delay typed into the time field.
# ---------------------------------------------------------------------------
cmd_select.setCurrentText('ABORT')
cs.send(:add_command)
pump(25)
check("two items in the sequence (#{sequence_list.to_a.length})",
      sequence_list.to_a.length == 2)
abort_item = sequence_list.to_a[1]
abort_item.instance_variable_get(:@time).setText('5.0')
pump(15)
check('the second item took the typed delay', abort_item.time == '5.0')
check('a command with no parameters saves bare',
      abort_item.save == 'COMMAND "5.0" "INST ABORT"')

# Expand/Collapse act on every item through SequenceList's Enumerable#map.
cs.instance_variable_get(:@expand_action).trigger
pump(10)
check('Expand All showed every item\'s parameters',
      sequence_list.all? { |item| item.instance_variable_get(:@parameters).visible? })
screenshot(cs, '/tmp/cosmos_cmd_sequence_qt6.png')

cs.instance_variable_get(:@collapse_action).trigger
pump(10)
check('Collapse All hid every item\'s parameters',
      sequence_list.none? { |item| item.instance_variable_get(:@parameters).visible? })
collect.expand
pump(10)

# ---------------------------------------------------------------------------
# Save through the tool. With @filename already set to a real path file_save
# writes straight out with no prompt, which is the Ctrl+S path once a
# sequence has a name.
# ---------------------------------------------------------------------------
sequence_file = File.join(SEQ_DIR, 'test_sequence.txt')
cs.instance_variable_set(:@filename, sequence_file)
check('modified before saving', sequence_list.modified?)
check('file_save reported success', cs.send(:file_save, false) == true)
pump(20)

check('sequence file written', File.exist?(sequence_file))
saved_text = File.read(sequence_file)
check("both commands written in order #{saved_text.lines.length} lines",
      saved_text.lines.map(&:chomp) == [
        'COMMAND "0.00" "INST COLLECT with TYPE NORMAL, DURATION 1.0, OPCODE 171, TEMP 0.0"',
        'COMMAND "5.0" "INST ABORT"'])
check('saving cleared the modified flag', sequence_list.modified? == false)
check("title dropped the modified star (#{cs.windowTitle})",
      cs.windowTitle == "Command Sequence : #{sequence_file}")

# ---------------------------------------------------------------------------
# Reload. SequenceList#open reparses the file with ConfigParser and rebuilds a
# SequenceItem per COMMAND line, looking each parameter back up by name, so a
# byte-identical re-save proves the whole round trip.
# ---------------------------------------------------------------------------
sequence_list.open(sequence_file)
pump(40, 0.05)

check("reload rebuilt both items (#{sequence_list.to_a.length})",
      sequence_list.to_a.length == 2)
check('a freshly opened sequence is not modified', sequence_list.modified? == false)
reloaded = sequence_list.map(&:save)
check('reloaded items save identically to what was written',
      reloaded == saved_text.lines.map(&:chomp))
# The state name has to survive as a name, not collapse to its raw number.
reloaded_type = param_row(sequence_list.to_a[0], 'TYPE')
check('the reloaded state parameter came back as its name',
      reloaded_type[1].text == 'NORMAL' && reloaded_type[2].text == '0')
check('the reloaded relative delay came back',
      sequence_list.to_a[1].time == '5.0')

resave = File.join(SEQ_DIR, 'resaved.txt')
sequence_list.save(resave)
check('re-saving after a reload is byte identical',
      File.read(resave) == saved_text)

# ---------------------------------------------------------------------------
# Export. The demo's CmdSequenceExporter packs the sequence into a single
# CCSDS command packet, prompting for the output path -- which is what the
# modal handler above accepts.
# ---------------------------------------------------------------------------
cs.instance_variable_set(:@sequence_dir, SEQ_DIR)
export_file = File.join(SEQ_DIR, 'test_sequence.bin')
cs.send(:file_export)
pump(50, 0.05)

check("export dialog was driven #{CHOSEN_EXPORT.inspect}",
      CHOSEN_EXPORT.length == 1 && CHOSEN_EXPORT[0] == export_file)
check('export wrote the binary', File.exist?(export_file))
binary = File.binread(export_file)

# 6 byte CCSDS header, then per item an 8 byte time stamp plus the command
# buffer: COLLECT is 16 bytes and ABORT is 12 (both include the 12 byte CCSDS
# command header the demo prepends).
collect_length = collect.command.buffer.length
abort_length = abort_item.command.buffer.length
expected_length = 6 + (8 + collect_length) + (8 + abort_length)
check("export is #{binary.length} bytes, the header plus both timed commands",
      binary.length == expected_length)
check('CCSDS APID 505 written as a command packet',
      binary[0, 2].unpack1('n') == 0x11F9)
check('packet marked standalone', binary[2, 2].unpack1('n') == 0xC000)
check('CCSDS length field is the data length minus one',
      binary[4, 2].unpack1('n') == (expected_length - 6) - 1)
# Neither delay parses as an absolute time, so both fall through to the
# relative branch: day 0 and the delay in milliseconds.
check('first item exported as a 0.00 second relative delay',
      binary[6, 4].unpack1('N') == 0 && binary[10, 4].unpack1('N') == 0)
check('second item exported as a 5000 ms relative delay',
      binary[6 + 8 + collect_length, 4].unpack1('N') == 0 &&
      binary[10 + 8 + collect_length, 4].unpack1('N') == 5000)
check('the COLLECT command buffer was embedded verbatim',
      binary[14, collect_length] == collect.command.buffer)

# ---------------------------------------------------------------------------
# File->New clears the sequence.
# ---------------------------------------------------------------------------
cs.send(:file_new)
pump(20)
check('File->New emptied the sequence', sequence_list.empty?)
check('File->New reset the title to Untitled',
      cs.windowTitle == 'Command Sequence : Untitled')

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
cs.close
pump(20)
FileUtils.rm_rf(SEQ_DIR)
puts 'TEST_CMD_SEQUENCE OK'
