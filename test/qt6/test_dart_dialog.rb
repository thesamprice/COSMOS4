require_relative 'helper'

require 'cosmos/gui/dialogs/dart_dialog'

# DART's backend is the opt-in Rails application under lib/cosmos/dart, which
# is not installed here, so nothing is listening on the DART_DECOM port. That
# is the point of this test: the dialog is pure Qt and must construct, render
# and stay usable with the server absent, reporting the failure rather than
# raising through it.

# ---------------------------------------------------------------------------
# Construction. DartMetaFrame kicks off a worker thread 0.1s in that tries to
# fetch SYSTEM META item names from the DART decom server, so pump past that.
# ---------------------------------------------------------------------------
dialog = Cosmos::DartDialog.new(nil, 'Stream Packets From DART', true)
dialog.show
pump(60, 0.05)

check('constructed', dialog.is_a?(Cosmos::DartDialog))
check('is a Qt::Dialog', dialog.is_a?(Qt::Dialog))
check('visible', dialog.visible?)
check('titled', dialog.windowTitle == 'Stream Packets From DART')

frame = dialog.instance_variable_get(:@stream_packets_frame)
check('DartFrame built', frame.is_a?(Cosmos::DartFrame))
meta_frame = frame.instance_variable_get(:@dart_meta_frame)
check('DartMetaFrame built', meta_frame.is_a?(Cosmos::DartMetaFrame))

# ---------------------------------------------------------------------------
# Degradation without a server. update_meta_item_names rescues the connection
# failure onto a clickable error icon instead of letting it escape.
# ---------------------------------------------------------------------------
check('no DART decom server is listening',
      Cosmos::System.ports['DART_DECOM'].is_a?(Integer))
error_label = meta_frame.instance_variable_get(:@error)
combo = meta_frame.instance_variable_get(:@meta_item_name)

check('the error indicator is showing', error_label.isVisible)
check("the connection failure was captured (#{error_label.text.to_s[0, 40]}...)",
      error_label.text.to_s.include?('Connection refused'))
check('the meta item list stayed empty', combo.count == 0)
check('the frame knows it never got the item names',
      meta_frame.instance_variable_get(:@got_meta_item_names) == false)
check('no meta filters by default', dialog.meta_filters.empty?)

screenshot(dialog, '/tmp/cosmos_dart_dialog_qt6.png')

# ---------------------------------------------------------------------------
# Time period selection. DartDialog delegates the accessors to DartFrame,
# which mirrors them into the two read-only line edits.
# ---------------------------------------------------------------------------
start_field = frame.instance_variable_get(:@time_start_field)
end_field = frame.instance_variable_get(:@time_end_field)
check('time fields start at N/A',
      start_field.text == 'N/A' && end_field.text == 'N/A')
check('time fields are read only -- the calendar button is the only way in',
      start_field.isReadOnly && end_field.isReadOnly)
check('no time period selected yet',
      dialog.time_start.nil? && dialog.time_end.nil?)

start_time = Time.utc(2026, 8, 16, 1, 2, 3)
end_time = Time.utc(2026, 8, 17, 4, 5, 6)
dialog.time_start = start_time
dialog.time_end = end_time
pump(10)
check('the delegated setters reached the frame',
      dialog.time_start == start_time && dialog.time_end == end_time)
check("the start field shows the formatted time (#{start_field.text})",
      start_field.text == '2026/08/16 01:02:03.000')
check("the end field shows the formatted time (#{end_field.text})",
      end_field.text == '2026/08/17 04:05:06.000')

# Clear puts it back to N/A and fires the change callback.
frame.send(:handle_time_clear_button, 'Start', start_field)
pump(10)
check('clearing the start time reset the field and the value',
      start_field.text == 'N/A' && dialog.time_start.nil?)
dialog.time_end = nil
pump(10)
check('assigning nil resets the end field too', end_field.text == 'N/A')

# ---------------------------------------------------------------------------
# Meta filters. Building a filter is pure GUI and works with the server down;
# stand in for the item names the server would have supplied.
# ---------------------------------------------------------------------------
dialog.meta_filters.clear # class variable, shared between instances
combo.addItem('OPERATOR')
combo.addItem('MISSION NAME')
combo.setCurrentText('OPERATOR')
comparison = meta_frame.instance_variable_get(:@comparison)
filter_value = meta_frame.instance_variable_get(:@filter_value)
filters_text = meta_frame.instance_variable_get(:@meta_filters_text)
add_button = meta_frame.instance_variable_get(:@add_button)

check('six comparison operators offered', comparison.count == 6)
check('comparison defaults to equality', comparison.currentText == '==')

filter_value.setText('jsmith')
add_button.click
pump(10)
check("a bare value is added unquoted #{dialog.meta_filters.inspect}",
      dialog.meta_filters == ['OPERATOR == jsmith'])
check('the filter is echoed into the read-only summary',
      filters_text.text == '"OPERATOR == jsmith"')

# A value containing a space has to be quoted or the filter would not parse.
combo.setCurrentText('MISSION NAME')
comparison.setCurrentText('!=')
filter_value.setText('deep space')
add_button.click
pump(10)
check("a value with a space is double quoted #{dialog.meta_filters.last.inspect}",
      dialog.meta_filters.last == 'MISSION NAME != "deep space"')

filter_value.setText('')
add_button.click
pump(10)
check("an empty value becomes an empty quoted string #{dialog.meta_filters.last.inspect}",
      dialog.meta_filters.last == "MISSION NAME != ''")
check('three filters accumulated', dialog.meta_filters.length == 3)

meta_frame.instance_variable_get(:@clear_button).click
pump(10)
check('Clear emptied the filters', dialog.meta_filters.empty?)
check('Clear emptied the summary field', filters_text.text == '')

# ---------------------------------------------------------------------------
# The dialog runs modally and both buttons resolve it. helper.rb's auto
# dismissal is what closes the exec below, standing in for a user cancelling.
# ---------------------------------------------------------------------------
dialog.instance_variable_get(:@ok_button).click
pump(10)
check('OK accepted the dialog', dialog.result == Qt::Dialog::Accepted)

dialog.show
pump(10)
dialog.instance_variable_get(:@cancel_button).click
pump(10)
check('Cancel rejected the dialog', dialog.result == Qt::Dialog::Rejected)

modal = Cosmos::DartDialog.new(nil, 'Modal DART', false)
check('a dialog built with show_time false still exposes the accessors',
      modal.time_start.nil? && modal.meta_filters.empty?)
result = modal.exec
pump(10)
check("exec returned once the dialog was dismissed (#{result})",
      result == Qt::Dialog::Rejected)
check('the modal dialog was seen and dismissed by the harness',
      MODALS_SEEN.include?('Cosmos::DartDialog'))
modal.dispose

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
dialog.close
pump(20)
puts 'TEST_DART_DIALOG OK'
