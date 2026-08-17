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
  # ProgressDialog runs its work on a worker thread the same way and needs the
  # separate handling below rather than a blind done(0).
  if m.is_a?(Cosmos::ProgressDialog)
    # A ProgressDialog runs its work on a worker thread and then calls
    # #complete, which only ENABLES the Done button -- the dialog stays up
    # until the user clicks it, so ProgressDialog.execute (and with it the
    # tool method that called it) never returns on its own. Click Done for
    # the user, but only once the button is enabled, which is the worker
    # saying it has finished. Dialogs built with show_done = false, such as
    # ScriptRunnerFrame.instrument_script's, have no button here and still
    # close themselves via close_done, so they are left alone.
    done_button = m.instance_variable_get(:@done_button)
    if done_button && done_button.enabled?
      MODALS_SEEN << m.class.to_s
      m.close_done
    end
  elsif m && !m.is_a?(Cosmos::Splash::SplashDialogBox)
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
