# Shared setup for the Qt 6 tool regression tests. See README.md.
$stdout.sync = true
ENV['QT_QPA_PLATFORM'] = 'offscreen'

require 'cosmos'
require 'cosmos/gui/qt'
require 'cosmos/gui/dialogs/splash' # referenced by the modal closer below
require 'cosmos/gui/dialogs/progress_dialog' # ditto

APP = Qt::Application.new

# Auto-dismiss any modal dialog that appears (QMessageBox ignores close(),
# so prefer done(0))
MODALS_SEEN = []
modal_closer = Qt::Timer.new
modal_closer.on_timeout do
  m = Qt::Application.activeModalWidget
  # Cosmos::Splash is modal but self-dismissing: it runs the tool's startup
  # work (System.load, config parsing) on a worker thread and closes itself
  # when that finishes. Killing it aborts the load and leaves the tool
  # half-initialized, so leave splashes alone and only dismiss real dialogs.
  # ProgressDialog works the same way -- ScriptRunnerFrame.instrument_script
  # runs the whole lexer pass inside one and calls close_done at the end, so
  # dismissing it early kills instrumentation and the script never runs.
  if m && !m.is_a?(Cosmos::Splash::SplashDialogBox) &&
     !m.is_a?(Cosmos::ProgressDialog)
    MODALS_SEEN << m.class.to_s
    m.respond_to?(:done) ? m.done(0) : m.close
  end
end
modal_closer.start(50)

def default_tool_options
  require 'cosmos/gui/qt_tool'
  _parser, options = Cosmos::QtTool.create_default_options
  options.redirect_io = false
  options.remember_geometry = false
  options
end

def pump(iterations = 20, interval = 0.02)
  iterations.times do
    APP.processEvents
    sleep interval
  end
end

# ScriptRunnerFrame#initialize calls redirect_io, which swaps $stdout for a
# Cosmos::Stdout multiplexer and then removes the real file descriptor from
# it, so anything these helpers print would be swallowed. Hold the real
# stream so test progress is always visible.
REAL_STDOUT = $stdout
REAL_STDERR = $stderr

def say(message)
  REAL_STDOUT.puts(message)
  REAL_STDOUT.flush
end

# Ruby reports an uncaught exception through the $stderr global, which
# redirect_io has also detached, so a failing test would otherwise exit 1 in
# silence. Report through the stream we captured before that happened.
at_exit do
  error = $!
  next if error.nil? || error.is_a?(SystemExit)
  REAL_STDERR.puts("EXCEPTION: #{error.class}: #{error.message}")
  REAL_STDERR.puts(error.backtrace)
  REAL_STDERR.flush
end

def screenshot(widget, path)
  APP.processEvents
  saved = widget.grab.save(path)
  raise "screenshot #{path} failed" unless saved
  say "screenshot: #{path}"
end

def check(name, condition)
  raise "FAILED: #{name}" unless condition
  say "ok: #{name}"
end
