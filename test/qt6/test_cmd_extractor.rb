require_relative 'helper'

require 'cosmos/tools/cmd_extractor/cmd_extractor'
require 'cosmos/packet_logs/packet_log_writer'

# ---------------------------------------------------------------------------
# Log fixture. The demo ships a zero byte outputs/logs/*_cmd.bin -- nothing
# ever sent commands to it -- so build a command log with the same writer the
# CmdTlmServer uses and extract that instead.
# ---------------------------------------------------------------------------
LOG_DIR = File.join(Dir.tmpdir, 'cosmos_cmd_extractor_qt6')
FileUtils.rm_rf(LOG_DIR)
FileUtils.mkdir_p(LOG_DIR)

BASE_TIME = Time.utc(2026, 8, 16, 23, 0, 0)
writer = Cosmos::PacketLogWriter.new(:CMD, nil, true, nil, 2_000_000_000,
                                     LOG_DIR, false)
3.times do |i|
  collect = Cosmos::System.commands.packet('INST', 'COLLECT')
  collect.restore_defaults
  collect.write('TYPE', i)          # 0 => NORMAL, 1 => SPECIAL, 2 => no state
  collect.write('DURATION', 1.5 + i)
  collect.received_time = BASE_TIME + i
  writer.write(collect)
end
abort_cmd = Cosmos::System.commands.packet('INST', 'ABORT')
abort_cmd.restore_defaults
abort_cmd.received_time = BASE_TIME + 10
writer.write(abort_cmd)
writer.shutdown

log_file = Dir[File.join(LOG_DIR, '*_cmd.bin')].sort.last
raise 'PacketLogWriter produced no command log' unless log_file
check("command log fixture written (#{File.size(log_file)} bytes)",
      File.size(log_file) > 0)

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Command Extractor'
options.width = 700
options.height = 425

ce = Cosmos::CmdExtractor.new(options)
pump(60, 0.05)

check('constructed', ce.is_a?(Cosmos::CmdExtractor))
check('visible', ce.visible?)
check('titled', ce.windowTitle == 'Command Extractor')

plf = ce.instance_variable_get(:@packet_log_frame)
check('packet log frame built', plf.is_a?(Cosmos::PacketLogFrame))
check('log file data source selected by default',
      ce.instance_variable_get(:@log_file_radio).isChecked)
check('mode menu actions are checkable and start off',
      [:@csv_output, :@skip_ignored, :@include_raw].all? do |name|
        action = ce.instance_variable_get(name)
        action.isCheckable && !action.isChecked
      end)

screenshot(ce, '/tmp/cosmos_cmd_extractor_qt6.png')

# ---------------------------------------------------------------------------
# Extraction. Seed the log the way the Browse button does; change_callback
# then derives the output filename from it, which is what the tool does for a
# real user. `process_data` is protected, so send() stands in for the Process
# Data button's clicked() slot. helper.rb clicks the ProgressDialog's Done
# button once the worker enables it, which is what lets execute() return.
# ---------------------------------------------------------------------------
plf.instance_variable_get(:@filenames).addItem(log_file)
ce.send(:change_callback, :INPUT_FILES)
pump(10)
check("output filename derived from the log #{File.basename(plf.output_filename)}",
      plf.output_filename.end_with?('.txt') &&
      plf.output_filename.start_with?(log_file[0..-5]))
output = plf.output_filename
File.delete(output) if File.exist?(output)

ce.send(:process_data)
pump(20)

check('output file written', File.exist?(output) && File.size(output) > 0)
text = File.read(output)

check('log filename banner written', text.include?(log_file))
check("all four commands extracted (#{text.scan(/^INST /).length})",
      text.scan(/^INST COLLECT$/).length == 3 &&
      text.scan(/^INST ABORT$/).length == 1)
# PacketLogWriter stamps a SYSTEM META packet at the top of every log file, so
# the extract carries five packets even though four commands were written.
check('SYSTEM META leads the extract',
      text.index('SYSTEM META') == text.index(/^SYSTEM META$/) &&
      text.index('SYSTEM META') < text.index('INST COLLECT'))
check('SYSTEM META decommutated too', text.include?('COSMOS_VERSION: '))
check('commands come out in log order',
      text.index('INST ABORT') > text.rindex('INST COLLECT'))
check('packet and received times written',
      text.include?('PACKET_TIMEFORMATTED: 2026/08/16') &&
      text.include?('RECEIVED_TIMEFORMATTED: 2026/08/16'))

# The parameters have to be decommutated out of the binary, not just dumped.
check('the three written DURATION values came back',
      text.include?('DURATION: 1.5') && text.include?('DURATION: 2.5') &&
      text.include?('DURATION: 3.5'))
check('TYPE rendered through its states (0 => NORMAL, 1 => SPECIAL)',
      text.include?('TYPE: NORMAL') && text.include?('TYPE: SPECIAL'))
check('a value with no state falls back to the number (2)',
      text.include?('TYPE: 2'))
check('WITH_UNITS formatting applied to TEMP', text.include?('TEMP: 0.0 C'))
check('OPCODE rendered with its 0x format', text.include?('OPCODE: 0xAB'))
check('CCSDS header items included by default', text.include?('CCSDSAPID: 999'))
check('raw data withheld while Include Raw Data is off',
      !text.include?('RAW PACKET DATA'))

screenshot(ce, '/tmp/cosmos_cmd_extractor_run_qt6.png')

# ---------------------------------------------------------------------------
# Mode menu: Skip Ignored Items drops the target's IGNORE_ITEM list, Include
# Raw Data appends the hex dump. Both are read off the actions at the top of
# process_data, so a changed output proves the menu state is being used.
# ---------------------------------------------------------------------------
ce.instance_variable_get(:@skip_ignored).setChecked(true)
ce.instance_variable_get(:@include_raw).setChecked(true)
filtered = File.join(LOG_DIR, 'filtered.txt')
plf.output_filename = filtered
pump(10)

ce.send(:process_data)
pump(20)

check('filtered output written', File.exist?(filtered))
filtered_text = File.read(filtered)
ignored = Cosmos::System.targets['INST'].ignored_items
check("target declares ignored items #{ignored.length}", ignored.include?('CCSDSAPID'))
# RECEIVED_TIMEFORMATTED is also on the ignore list but CmdExtractor prints it
# itself, above the formatted packet body, so only the header items the body
# carries can disappear.
body_ignored = ignored.grep(/^CCSDS/)
check("Skip Ignored Items dropped the ignored header items #{body_ignored.inspect}",
      body_ignored.length == 7 &&
      body_ignored.none? { |name| filtered_text.include?("#{name}: ") })
check('non-ignored parameters survived the filter',
      filtered_text.include?('TYPE: NORMAL') &&
      filtered_text.include?('DURATION: 1.5') &&
      filtered_text.include?('PKTID: 1'))
check("Include Raw Data appended the hex dump (#{filtered_text.scan(/RAW PACKET DATA/).length})",
      filtered_text.scan(/RAW PACKET DATA/).length == 5)

# ---------------------------------------------------------------------------
# CSV output is a different writer entirely: one row per command instead of a
# block, and toggling it re-derives the output filename extension.
# ---------------------------------------------------------------------------
ce.instance_variable_get(:@skip_ignored).setChecked(false)
ce.instance_variable_get(:@include_raw).setChecked(false)
ce.instance_variable_get(:@csv_output).setChecked(true)
ce.send(:change_callback, :INPUT_FILES)
pump(10)
csv_output = plf.output_filename
check("CSV mode re-derived the output extension #{File.extname(csv_output)}",
      csv_output.end_with?('.csv'))
File.delete(csv_output) if File.exist?(csv_output)

ce.send(:process_data)
pump(20)

check('CSV output written', File.exist?(csv_output))
csv_lines = File.readlines(csv_output).map(&:chomp).reject(&:empty?)
check("CSV filename row #{csv_lines[0][0, 9].inspect}",
      csv_lines[0] == "Filename,#{log_file}")
check("CSV header row #{csv_lines[1].inspect}",
      csv_lines[1] == 'PACKET_TIMEFORMATTED,Target,Packet,Parameters')
csv_rows = csv_lines[2..-1]
check("one CSV row per packet (#{csv_rows.length})", csv_rows.length == 5)
fields = csv_rows[1].split(',')
check("first command row is the first COLLECT #{fields[0, 3].inspect}",
      fields[0] == '2026/08/16 19:00:00.000' && fields[1] == 'INST' &&
      fields[2] == 'COLLECT')
check('CSV row carries name,value pairs for the parameters',
      csv_rows[1].include?('TYPE,NORMAL') && csv_rows[1].include?('DURATION,1.5'))
check('last CSV row is the ABORT', csv_rows[-1].split(',')[2] == 'ABORT')

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
ce.close
pump(20)
FileUtils.rm_rf(LOG_DIR)
puts 'TEST_CMD_EXTRACTOR OK'
