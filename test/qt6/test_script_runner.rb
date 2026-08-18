require_relative 'helper'

require 'cosmos/gui/text/ruby_editor'

# Count invocations of the Ruby override of QSyntaxHighlighter's pure virtual
# highlightBlock. Nothing else proves the C++ highlighter is actually driving
# the Ruby subclass -- the formats it sets live on the block layout, not in
# the document, so they are not observable through QTextCursor#charFormat.
class Cosmos::RubyEditor::RubySyntax
  HIGHLIGHTED = []
  unless method_defined?(:qt6_highlightBlock)
    alias_method :qt6_highlightBlock, :highlightBlock
    def highlightBlock(text)
      HIGHLIGHTED << text
      qt6_highlightBlock(text)
    end
  end
end

require 'cosmos/tools/script_runner/script_runner'

options = default_tool_options
options.title = 'Script Runner'

sr = Cosmos::ScriptRunner.new(options)
sr.resize(900, 700)
pump(40, 0.05)

check('constructed', sr.is_a?(Cosmos::ScriptRunner))
check('visible', sr.visible?)
# update_title() overrides options.title with the current tab's filename
check("titled (#{sr.windowTitle})", sr.windowTitle.start_with?('Script Runner'))

frame = sr.instance_variable_get(:@tab_book).currentTab
check('frame is a ScriptRunnerFrame', frame.is_a?(Cosmos::ScriptRunnerFrame))
editor = frame.instance_variable_get(:@script)
check('editor is a RubyEditor', editor.is_a?(Cosmos::RubyEditor))

# --- Editor -----------------------------------------------------------------

# QCompleter-backed completion is built in CompletionTextEdit#initialize inside
# a rescue, so a nil here means construction raised rather than "no completion"
completion = editor.instance_variable_get(:@code_completion)
check('completion constructed', completion.is_a?(Cosmos::Completion))
check('completion is a Qt::Completer bound to the editor',
      completion.is_a?(Qt::Completer) && completion.widget == editor)
# create_popup builds the QStringListModel and calls QCompleter#complete,
# which is what actually realises the popup view
completion.create_popup(%w(cmd tlm wait))
pump(10)
check('completion model populated', completion.model.rowCount == 3)
check('completion popup is a view', completion.popup.is_a?(Qt::ListView))
completion.popup.close
pump(5)

SCRIPT = <<~'RUBY'
  # a comment
  total = 0
  3.times do |i|
    total += i
    wait 0.1
  end
  puts "total is #{total}"
RUBY

Cosmos::RubyEditor::RubySyntax::HIGHLIGHTED.clear
frame.set_text(SCRIPT, 'inline_test.rb')
pump(20)

check("editor text round-trips (#{frame.text.lines.length} lines)",
      frame.text == SCRIPT)
check("syntax highlighter ran over every line "\
      "(#{Cosmos::RubyEditor::RubySyntax::HIGHLIGHTED.length} blocks)",
      Cosmos::RubyEditor::RubySyntax::HIGHLIGHTED.length >= SCRIPT.lines.length)
check('syntax highlighter saw the keyword line',
      Cosmos::RubyEditor::RubySyntax::HIGHLIGHTED.any? { |t| t.include?('puts') })

# The gutter paints line numbers and breakpoint dots using QPlainTextEdit's
# protected block-geometry API (firstVisibleBlock/blockBoundingGeometry/
# contentOffset), so a successful grab exercises that path
line_area = editor.instance_variable_get(:@lineNumberArea)
check('line number area exists', line_area.is_a?(Qt::Widget))
check('line number area has width', line_area.width > 0)

# --- Breakpoints ------------------------------------------------------------

Cosmos::ScriptRunnerFrame.clear_breakpoints
editor.enable_breakpoints = true

# Click points are resolved to lines through the protected block geometry, so
# derive the y coordinate from the editor itself rather than hard-coding it
def click_point(editor, block_number)
  top, bottom = editor.send(:block_top_and_bottom,
                            editor.document.findBlockByNumber(block_number))
  Qt::Point.new(5, ((top + bottom) / 2).to_i)
end

def frame_breakpoints
  Cosmos::ScriptRunnerFrame.class_variable_get(:@@breakpoints)
end

# Line 1 is a comment. ScriptRunnerFrame#breakpoint_set reads the line back out
# of the editor and clears breakpoints that land somewhere uninstrumentable,
# so this exercises the signal round trip *and* that rejection path
action = editor.send(:create_add_breakpoint_action, click_point(editor, 0))
check('add breakpoint action built', action.is_a?(Qt::Action))
action.trigger
pump(10)
check("breakpoint on a comment line is rejected #{frame_breakpoints.inspect}",
      frame_breakpoints.empty? ||
        !(frame_breakpoints['inline_test.rb'] || {})[1])
check('comment line left unmarked',
      editor.document.findBlockByNumber(0).userState !=
        Cosmos::RubyEditor::BREAKPOINT_SET)

# Line 2 ("total = 0") is real code, so the breakpoint sticks
action = editor.send(:create_add_breakpoint_action, click_point(editor, 1))
action.trigger
pump(10)
check("breakpoint recorded on the frame #{frame_breakpoints.inspect}",
      frame_breakpoints['inline_test.rb'] &&
        frame_breakpoints['inline_test.rb'][2])
check('block user state marks the breakpoint',
      editor.document.findBlockByNumber(1).userState ==
        Cosmos::RubyEditor::BREAKPOINT_SET)

screenshot(sr, '/tmp/cosmos_script_runner_qt6.png')

# A breakpoint would pause the run and hang an unattended test
editor.clear_breakpoints
Cosmos::ScriptRunnerFrame.clear_breakpoints
check('breakpoints cleared',
      Cosmos::ScriptRunnerFrame.class_variable_get(:@@breakpoints).empty?)

# --- Running the script -----------------------------------------------------

Cosmos::ScriptRunnerFrame.line_delay = 0.0
Cosmos::ScriptRunnerFrame.pause_on_error = false
Cosmos::ScriptRunnerFrame.step_mode = false

check('not running before start', !Cosmos::ScriptRunnerFrame.running?)
frame.run
# A failed assertion below would otherwise leave the run thread alive and the
# process would never exit
at_exit { Cosmos::ScriptRunnerFrame.stop! if Cosmos::ScriptRunnerFrame.running? }
check('running after start', Cosmos::ScriptRunnerFrame.running?)
check('frame is the instrumentation target',
      Cosmos::ScriptRunnerFrame.instance == frame)

# Catch the script mid-flight: pre_line_instrumentation highlights the
# executing line through Qt.execute_in_main_thread, which shows up as a
# QTextEdit::ExtraSelection on the editor
highlight_colour = nil
started = Time.now
while Cosmos::ScriptRunnerFrame.running? && (Time.now - started) < 120
  APP.processEvents
  if highlight_colour.nil?
    selections = editor.extraSelections
    unless selections.empty?
      highlight_colour = selections[0].format.background.color.name
      screenshot(sr, '/tmp/cosmos_script_runner_ran_qt6.png')
    end
  end
  sleep 0.005
end

elapsed = Time.now - started
check("run finished in #{elapsed.round(2)}s", !Cosmos::ScriptRunnerFrame.running?)
check("executing line was highlighted mid-run (#{highlight_colour.inspect})",
      highlight_colour == Cosmos.getColor('palegreen').name)
pump(30)

output = frame.instance_variable_get(:@output).toPlainText
say "--- script output ---\n#{output}\n---"
check('script started', output.include?('Starting script: inline_test.rb'))
check('script printed its result', output.include?('total is 3'))
check('script completed', output.include?('Script completed: inline_test.rb'))
check("no exceptions #{frame.exceptions.inspect}", frame.exceptions.nil? || frame.exceptions.empty?)

# post_line_instrumentation tags each output line with the source line it came
# from, which only works if the Ripper-based lexer numbered the segments right
attributed = output.scan(/\(inline_test\.rb:(\d+)\)/).flatten.uniq
check("output attributed to the right source lines (#{attributed.inspect})",
      attributed.include?('5') && attributed.include?('7'))

# The highlight is dropped once the run ends
check('highlight cleared after the run', editor.extraSelections.empty?)

sr.close
pump(20)
say 'TEST_SCRIPT_RUNNER OK'
