require_relative 'helper'

require 'cosmos/tools/limits_monitor/limits_monitor'

options = default_tool_options
options.title = 'Limits Monitor'
options.auto_size = false
options.replay = false
options.config_file = nil

lm = Cosmos::LimitsMonitor.new(options)
pump(30, 0.05)

check('constructed', lm.is_a?(Cosmos::LimitsMonitor))
check('visible', lm.visible?)
check('titled', lm.windowTitle == 'Limits Monitor')

tabbook = lm.instance_variable_get(:@tabbook)
tabs = (0...tabbook.count).map { |i| tabbook.tabText(i) }
check("tabs #{tabs.inspect}", tabs == ['Limits', 'Log'])

state_field = lm.instance_variable_get(:@monitored_state_text_field)
check("state field starts Stale (#{state_field.text})", state_field.text == 'Stale')
check('replay flag hidden', !lm.instance_variable_get(:@replay_flag).visible?)

# Log tab: colored limits events land in the QPlainTextEdit
lm.update_log("ERROR: INST HEALTH_STATUS TEMP1 = 9.0 is RED_HIGH\n", :RED)
lm.update_log("WARN: INST HEALTH_STATUS TEMP2 = 3.0 is YELLOW_HIGH\n", :YELLOW)
lm.update_log("INFO: Packet INST MECH is STALE\n", :BLACK)
pump(10)
log_text = lm.instance_variable_get(:@log_output).toPlainText
check("log has 3 entries", log_text.split("\n").length == 3)
check('log content', log_text.include?('TEMP1 = 9.0 is RED_HIGH') &&
                     log_text.include?('INST MECH is STALE'))

# Without a CmdTlmServer the limits thread keeps calling reset(), which clears
# the item panel. Stop the threads so the items we add below stay put.
lm.instance_variable_set(:@cancel_thread, true)
lm.instance_variable_get(:@limits_sleeper).cancel
lm.instance_variable_get(:@value_sleeper).cancel
pump(20)

# Out of limits items and stale packets build real telemetry widgets
item_widget = lm.new_gui_item('INST', 'HEALTH_STATUS', 'TEMP1')
stale_widget = lm.new_gui_item('INST', 'MECH', nil)
pump(10)
scroll_layout = lm.instance_variable_get(:@scroll_layout)
check("2 widgets in the panel (#{scroll_layout.count})", scroll_layout.count == 2)
check('item widget type', item_widget.type == :ITEM &&
      item_widget.value.is_a?(Cosmos::LabelvaluelimitsbarWidget))
check('stale widget type', stale_widget.type == :STALE &&
      stale_widget.value.is_a?(Cosmos::LabelWidget))

lm.update_gui_item(item_widget, 9.0, :RED_HIGH, :DEFAULT)
pump(10)
value_widget = item_widget.value.instance_variable_get(:@widgets)[0]
                          .instance_variable_get(:@widgets)[1]
check("value displayed (#{value_widget.text})", value_widget.text.include?('9.0'))

lm.update_overall_limits_state(:RED)
pump(5)
check("overall state Red (#{state_field.text})", state_field.text == 'Red')

screenshot(lm, '/tmp/cosmos_limits_monitor_qt6.png')

tabbook.setCurrentIndex(1)
pump(10)
check('log tab selected', tabbook.current_name == 'Log')
screenshot(lm, '/tmp/cosmos_limits_monitor_qt6_log.png')
tabbook.setCurrentIndex(0)
pump(5)

# Ignoring an item removes its widget and records it in the ignored list
limits_items = lm.limits_items
limits_items.instance_variable_set(:@out_of_limits, [['INST', 'HEALTH_STATUS', 'TEMP1']])
limits_items.instance_variable_set(:@items,
  { 'INST HEALTH_STATUS TEMP1' => item_widget })
lm.remove(item_widget, ['INST', 'HEALTH_STATUS', 'TEMP1'])
pump(10)
check("widget removed (#{scroll_layout.count})", scroll_layout.count == 1)
check("item ignored #{limits_items.ignored.inspect}",
      limits_items.ignored == [['INST', 'HEALTH_STATUS', 'TEMP1']])
check('ignored_items?', limits_items.ignored_items?)

# Modal dialogs build and are dismissed by the harness' modal closer
lm.edit_ignored_items
pump(10)
lm.show_options_dialog
pump(10)
check("dialogs shown #{MODALS_SEEN.uniq.inspect}", MODALS_SEEN.length >= 2)

lm.close
pump(20)
puts 'TEST_LIMITS_MONITOR OK'
