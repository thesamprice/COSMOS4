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

# Opt-in escape hatch from the blanket dismissal below. A test that needs a
# dialog *accepted* with real input (rather than cancelled) pushes a lambda
# here; it is called with the modal widget and returns true to claim it, which
# suppresses the default done(0). Empty by default, so tests that do not
# register anything behave exactly as before.
MODAL_HANDLERS = []

# Right-click context menus are the other kind of window that stops a headless
# run dead. Qt::Menu#exec is a Ruby-driven loop over popup() (see qt6.rb), so
# it no longer blocks the GVL -- but nothing headless will ever dismiss the
# menu, so the loop spins forever unless someone closes it.
#
# Unlike the modal arm below, this one is unconditional rather than opt-in.
# Dismissing a modal dialog is a real answer ("cancel"), so a test may
# legitimately want to give a different one; an unattended popup menu is never
# anything but a hang, and no test opens one it does not intend to drive.
# POPUP_HANDLERS is the same escape hatch as MODAL_HANDLERS for a test that
# wants to choose an action instead: push a lambda, return true to claim the
# menu (having triggered whatever it wants) and suppress the default close.
#
# Scoped to Qt::Menu on purpose. Qt::Application.activePopupWidget also
# reports QCompleter's completion list, which script_runner and config_editor
# pop up while text is being typed; those dismiss themselves and closing them
# from here would change what those tests exercise.
POPUPS_SEEN = []
POPUP_HANDLERS = []

modal_closer = Qt::Timer.new
modal_closer.on_timeout do
  popup = Qt::Application.activePopupWidget
  if popup.is_a?(Qt::Menu)
    unless POPUP_HANDLERS.any? { |handler| handler.call(popup) }
      POPUPS_SEEN << popup.title.to_s
      popup.close
    end
  end

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
    unless MODAL_HANDLERS.any? { |handler| handler.call(m) }
      MODALS_SEEN << m.class.to_s
      m.respond_to?(:done) ? m.done(0) : m.close
    end
  end
end
modal_closer.start(50)

# The telemetry log tlm_extractor, tlm_grapher, replay and data_viewer read
# back. Those four used to glob Cosmos::System.paths['LOGS'] directly, which
# only holds anything on a machine that has run the demo CmdTlmServer long
# enough to produce one -- so from a clean checkout all four failed at require
# time. Prefer the newest local log when there is one, so behaviour on a
# developer machine is unchanged, and otherwise fall back to the committed
# fixture (see fixtures/build_tlm_log.rb for what is in it and how to rebuild
# it). COSMOS_QT6_FORCE_FIXTURE=1 ignores the local log, which is how the
# fixture path gets exercised on a machine that has one.
FIXTURE_TLM_LOG = File.join(__dir__, 'fixtures', 'qt6_demo_tlm.bin')

def tlm_log_file
  unless ENV['COSMOS_QT6_FORCE_FIXTURE'] == '1'
    newest = Dir[File.join(Cosmos::System.paths['LOGS'], '*_tlm.bin')].sort.last
    return newest if newest && File.size(newest) > 0
  end
  unless File.exist?(FIXTURE_TLM_LOG)
    raise "no local *_tlm.bin and no fixture at #{FIXTURE_TLM_LOG}"
  end
  FIXTURE_TLM_LOG
end

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
