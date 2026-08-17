# Shared setup for the Qt 6 tool regression tests. See README.md.
$stdout.sync = true
ENV['QT_QPA_PLATFORM'] = 'offscreen'

require 'cosmos'
require 'cosmos/gui/qt'
require 'cosmos/gui/dialogs/splash' # referenced by the modal closer below

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
  if m && !m.is_a?(Cosmos::Splash::SplashDialogBox)
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

def screenshot(widget, path)
  APP.processEvents
  saved = widget.grab.save(path)
  raise "screenshot #{path} failed" unless saved
  puts "screenshot: #{path}"
end

def check(name, condition)
  raise "FAILED: #{name}" unless condition
  puts "ok: #{name}"
end
