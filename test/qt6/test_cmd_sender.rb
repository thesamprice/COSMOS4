require_relative 'helper'

require 'cosmos/tools/cmd_sender/cmd_sender'

options = default_tool_options
options.title = 'Command Sender'
options.production = false
options.packet = nil

cs = Cosmos::CmdSender.new(options)
pump(40, 0.05)

check('constructed', cs.is_a?(Cosmos::CmdSender))
check('visible', cs.visible?)
check('titled', cs.windowTitle == 'Command Sender')

target_select = cs.instance_variable_get(:@target_select)
cmd_select = cs.instance_variable_get(:@cmd_select)
cmd_params = cs.instance_variable_get(:@cmd_params)
targets = (0...target_select.count).map { |i| target_select.itemText(i) }
check("target combo populated (#{targets.length})", targets.include?('INST'))

# Switch target/command the way the combo box activated() handlers do and
# confirm the parameter table is rebuilt for the new command
target_select.setCurrentText('INST')
cs.update_commands
cs.update_cmd_params
pump(10)
commands = (0...cmd_select.count).map { |i| cmd_select.itemText(i) }
check("command combo repopulated (#{commands.length})", commands.include?('COLLECT'))

cmd_select.setCurrentText('COLLECT')
cs.update_cmd_params
pump(20)
check('description updated',
      cs.instance_variable_get(:@description).text.include?('collect'))

table = cmd_params.instance_variable_get(:@table)
check('parameter table built', table.is_a?(Qt::TableWidget))
check("parameter table sized (#{table.rowCount}x#{table.columnCount})",
      table.rowCount == 4 && table.columnCount == 5)
names = (0...table.rowCount).map { |r| table.item(r, 0).text }
check("parameter names #{names.inspect}",
      names == ['TYPE:', 'DURATION:', 'OPCODE:', 'TEMP:'])
check('defaults populated', table.item(1, 1).text == '1.0')

# Editing a state parameter must fire itemChanged and back-fill the raw
# state value column (this exercises the item delegate + signal plumbing)
table.item(0, 1).setText('NORMAL')
pump(10)
check("state value back-filled (#{table.item(0, 2).text})",
      table.item(0, 2).text == '0')

script = cs.view_as_script[0]
check("view_as_script: #{script}",
      script == 'cmd("INST COLLECT with TYPE NORMAL, DURATION 1.0, OPCODE 171, TEMP 0.0")')

# Command history pane
input = cs.instance_variable_get(:@input)
check('history widget', input.is_a?(Cosmos::CmdSenderTextEdit))
input.append(script)
pump(5)
check('history holds the command', input.toPlainText.include?('INST COLLECT'))

screenshot(cs, '/tmp/cosmos_cmd_sender_qt6.png')

cs.close
pump(20)
puts 'TEST_CMD_SENDER OK'
