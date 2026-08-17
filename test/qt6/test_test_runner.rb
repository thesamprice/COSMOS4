require_relative 'helper'

require 'cosmos/tools/test_runner/test_runner'

options = default_tool_options
options.title = 'Test Runner'
options.width = 800
options.height = 700
options.auto_size = false
options.server_config_file = Cosmos::CmdTlmServer::DEFAULT_CONFIG_FILE
# demo/config/tools/test_runner/test_runner.txt: LOAD_UTILITY 'example_test'
options.config_file = 'test_runner.txt'
options.test_suite = nil
options.test_group = nil
options.test_case = nil

tr = Cosmos::TestRunner.new(options)
pump(60, 0.05)

check('constructed', tr.is_a?(Cosmos::TestRunner))
check('visible', tr.visible?)
check("titled (#{tr.windowTitle})", tr.windowTitle == 'Test Runner')

# --- The suite tree built from the demo config ------------------------------

suites = Cosmos::TestRunner.class_variable_get(:@@test_suites)
names = suites.map { |s| s.class.to_s }.sort
check("test suites loaded from example_test #{names.inspect}",
      names.include?('ExampleTestSuite') && names.include?('ExampleTestSuite2') &&
        names.include?('ExampleTestSuite3'))

chooser = tr.instance_variable_get(:@test_runner_chooser)
check('chooser built', chooser.is_a?(Cosmos::TestRunnerChooser))
suite_combo = chooser.instance_variable_get(:@test_suite_combobox)
test_combo = chooser.instance_variable_get(:@test_combobox)
case_combo = chooser.instance_variable_get(:@test_case_combobox)
combo_suites = (0...suite_combo.count).map { |i| suite_combo.itemText(i) }
check("suite combo populated #{combo_suites.inspect}",
      combo_suites.include?('ExampleTestSuite'))

# Selecting a suite has to repopulate the group and case combos through the
# chooser's callbacks, which is the whole point of the widget
chooser.select_suite('ExampleTestSuite')
pump(10)
test_combo.setCurrentText('ExampleTest')
chooser.handle_test_change
pump(10)
combo_cases = (0...case_combo.count).map { |i| case_combo.itemText(i) }
check("case combo repopulated for ExampleTest #{combo_cases.inspect}",
      combo_cases.include?('test_3xx'))
combo_tests = (0...test_combo.count).map { |i| test_combo.itemText(i) }
check("group combo populated #{combo_tests.inspect}",
      combo_tests.include?('ExampleTest'))

frame = tr.instance_variable_get(:@script_runner_frame)
check('embedded ScriptRunnerFrame', frame.is_a?(Cosmos::ScriptRunnerFrame))

screenshot(tr, '/tmp/cosmos_test_runner_qt6.png')

# --- Running a single test case ---------------------------------------------

# The demo config asks for COLLECT_METADATA and CREATE_DATA_PACKAGE. Metadata
# is gathered through SetTlmDialog, which needs a live CmdTlmServer; with none
# running it fails and TestRunner refuses to start the test at all. Both are
# orthogonal to exercising the test framework itself.
writer = Cosmos::TestRunner.results_writer
writer.metadata = false
writer.data_package = false

Cosmos::ScriptRunnerFrame.line_delay = 0.0
Cosmos::ScriptRunnerFrame.pause_on_error = false
Cosmos::ScriptRunnerFrame.clear_breakpoints

check('not running before start', !Cosmos::ScriptRunnerFrame.running?)
# ExampleTest#test_3xx just logs and waits -- no `ask` prompt, so it completes
# unattended even with the config's MANUAL setting
tr.handle_start('ExampleTestSuite', 'ExampleTest', 'test_3xx', false)
at_exit { Cosmos::ScriptRunnerFrame.stop! if Cosmos::ScriptRunnerFrame.running? }
check('running after start', Cosmos::ScriptRunnerFrame.running?)
check("generated script is #{frame.text.strip.inspect}",
      frame.text.include?("TestRunner.start(ExampleTestSuite, ExampleTest, 'test_3xx')"))

started = Time.now
while Cosmos::ScriptRunnerFrame.running? && (Time.now - started) < 150
  APP.processEvents
  sleep 0.005
end
check("test run finished in #{(Time.now - started).round(2)}s",
      !Cosmos::ScriptRunnerFrame.running?)
pump(40)

output = frame.instance_variable_get(:@output).toPlainText
say "--- test output ---\n#{output}\n---"

# example_test.rb starts with `load 'cosmos/tools/test_runner/test.rb'`, and
# load re-runs the class bodies -- which resets TestStatus's @@instance. So the
# singleton must be fetched after require_utilities has run, not before, or the
# counters read here belong to a discarded object. TestRunner#disable_while_running
# zeroes the counters when the run starts, so no manual reset is needed.
status = Cosmos::TestStatus.instance
check("test case passed (pass=#{status.pass_count} fail=#{status.fail_count} "\
      "skip=#{status.skip_count})",
      status.pass_count == 1 && status.fail_count == 0 && status.skip_count == 0)
check('the test case ran and identified itself',
      output.include?('ExampleTestSuite:ExampleTest:test_3xx'))
check('script completed', output.include?('Script completed'))

# ResultsWriter writes the verdict to its own report file rather than to the
# Script Output pane
report_path = writer.filename
report = Cosmos.set_working_dir { File.read(report_path) }
say "--- report #{report_path} ---\n#{report}\n---"
verdicts = report.lines.grep(/:PASS|:FAIL|:SKIP/).map(&:strip)
check("report records the PASS verdict #{verdicts.inspect}",
      report.include?('ExampleTest:test_3xx:PASS'))
check('report is a Test Report', report.include?('--- Test Report ---'))

# status_timeout() copies the counters into the GUI on a 100ms timer
tr.status_timeout
pump(10)
check("pass count shown in the GUI (#{tr.instance_variable_get(:@pass_count).text})",
      tr.instance_variable_get(:@pass_count).text == '1')
check("fail count shown in the GUI (#{tr.instance_variable_get(:@fail_count).text})",
      tr.instance_variable_get(:@fail_count).text == '0')

screenshot(tr, '/tmp/cosmos_test_runner_ran_qt6.png')

tr.close
pump(20)
say 'TEST_TEST_RUNNER OK'
