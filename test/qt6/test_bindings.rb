require_relative 'helper'

# Bindings-level regressions that no tool test reaches: the Ruby-driven
# application event loop, QObject wrapper identity/lifetime, and the
# Ruby-driven QMenu popup loop. All three replace C++ calls that hold the Ruby
# GVL for the whole life of a nested event loop.

# processEvents deliberately does not reap DeferredDelete events -- only a real
# QEventLoop iteration does, and the Ruby loops in qt6.rb are not one. The app
# exec loop flushes them itself; here the flush has to be explicit.
def settle(iterations = 40)
  iterations.times do
    APP.processEvents
    Qt::CoreApplication.send_posted_events(nil, Qt::Event::DeferredDelete)
    sleep 0.005
  end
end

# ---------------------------------------------------------------------------
# QCoreApplication#exec. The native exec is one C call that never returns to
# the Ruby VM, so background threads only run in the slivers a handler yields
# and a thread that calls quit() deadlocks against the main thread's GVL.
# ---------------------------------------------------------------------------
counter = 0
Thread.new do
  50.times { counter += 1; sleep 0.002 }
  Qt::Application.quit
end
started = Time.now
code = APP.exec
elapsed = Time.now - started
check("exec returned (#{elapsed.round(2)}s)", elapsed < 10)
check("a background thread ran while exec was up (counter=#{counter})", counter == 50)
check("quit() from that thread ended exec with 0 (got #{code.inspect})", code == 0)

Thread.new { sleep 0.05; Qt::CoreApplication.instance.exit(7) }
check('exec reports the code passed to exit', APP.exec == 7)

Thread.new { sleep 0.05; APP.quit }
check('the instance quit form works too', APP.exec == 0)

ran = false
Thread.new do
  # This is the call every Cosmos worker thread makes; under the native exec
  # it slept forever waiting for a main thread that never ran Ruby.
  Qt.execute_in_main_thread(true) { ran = true }
  Qt::Application.quit
end
APP.exec
check('execute_in_main_thread(blocking) completes under exec', ran)

# quitOnLastWindowClosed. Qt's own lastWindowClosed() signal is emitted only
# from inside the native exec, so the Ruby loop polls the top-level widget list
# with Qt's predicate (visible + WA_QuitOnClose) instead.
window = Qt::Widget.new
window.show
Thread.new { sleep 0.2; Qt.execute_in_main_thread(false) { window.close } }
started = Time.now
check('closing the last window ends exec', APP.exec == 0)
check("... promptly (#{(Time.now - started).round(2)}s)", (Time.now - started) < 5)

Qt::GuiApplication.setQuitOnLastWindowClosed(false)
begin
  other = Qt::Widget.new
  other.show
  Thread.new do
    Qt.execute_in_main_thread(true) { other.close }
    sleep 0.5
    raise 'exec exited early' unless Qt.qt6rb_app_in_exec?
    Qt::Application.quit
  end
  check('quitOnLastWindowClosed=false keeps exec running', APP.exec == 0)
ensure
  Qt::GuiApplication.setQuitOnLastWindowClosed(true)
end

# QCoreApplication::exec() clears quitNow on entry, so a quit that arrived
# before the loop started is ignored; the Ruby loop mirrors that.
Qt::Application.quit
Thread.new { sleep 0.1; Qt::Application.exit(3) }
check('a quit that predates exec is cleared on entry', APP.exec == 3)

# ---------------------------------------------------------------------------
# QObject wrapper cache. Objects Qt built in C++ have no RubyPeer, so every
# accessor used to mint a fresh wrapper (no identity, no state) and every
# wrapper outlived the object it pointed at.
# ---------------------------------------------------------------------------
main = Qt::MainWindow.new
check('a C++-created child wraps to the same Ruby object', main.menuBar.equal?(main.menuBar))
check('it still downcasts to the most derived class', main.menuBar.is_a?(Qt::MenuBar))
check('different children get different wrappers', !main.menuBar.equal?(main.statusBar))

main.menuBar.instance_variable_set(:@qt6_marker, 42)
check('state left on such a wrapper survives the round trip',
      main.menuBar.instance_variable_get(:@qt6_marker) == 42)

# Ruby-constructed objects keep taking the RubyPeer path, which dispose unlinks
class BindingsProbeWidget < Qt::Widget
  attr_accessor :tag
end
probe = BindingsProbeWidget.new(main)
probe.tag = 'peer'
check('RubyPeer identity is unaffected by the cache',
      probe.parentWidget.equal?(main) && probe.tag == 'peer')

cached = main.menuBar
5.times { 2000.times { main.menuBar }; GC.start }
check('identity survives GC pressure', main.menuBar.equal?(cached))
check('and the wrapper is still usable', !main.menuBar.disposed?)

menu_bar = main.menuBar
status_bar = main.statusBar
main.dispose
settle
check('a child of a disposed parent is detached when Qt deletes it',
      menu_bar.disposed? && status_bar.disposed?)
detached_raised =
  begin
    menu_bar.setNativeMenuBar(false)
    false
  rescue RuntimeError => error
    error.message.include?('used before construction')
  end
check('using it raises instead of dereferencing freed memory', detached_raised)

# dispose evicts, so the object stays wrappable for the deleteLater window
main2 = Qt::MainWindow.new
disposed_bar = main2.menuBar
disposed_bar.dispose
fresh_bar = main2.menuBar
check('dispose drops the cache entry', !fresh_bar.equal?(disposed_bar))
check('the replacement wrapper works', !fresh_bar.disposed?)
settle
check('the disposed wrapper stays detached', disposed_bar.disposed?)
main2.dispose
settle

# Churning objects must evict, not accumulate. Cache entries hold a strong GC
# reference to their wrapper (a weak one is not safe in CRuby -- see the cache
# comment in qt6_runtime.cpp), so a missed eviction is a real leak. Counting
# T_DATA slots across a churn is the observable version of that: the cache
# itself is C++ side and has no Ruby-visible size.
identical = []
churn = lambda do |count|
  count.times do
    menu = Qt::Menu.new                      # Ruby-created: RubyPeer, never cached
    3.times { |i| menu.addAction("a#{i}") }  # C++-created: cached
    identical << menu.actions.first.equal?(menu.actions.first)
    menu.dispose
  end
  settle
  GC.start
end
churn.call(100) # warm up: first-time wrappers for shared Qt internals
baseline = ObjectSpace.count_objects[:T_DATA]
churn.call(500)
grew = ObjectSpace.count_objects[:T_DATA] - baseline
check('actions Qt hands back are identity-stable', identical.all?)
check("destroyed objects evict their cache entry (T_DATA grew by #{grew} " \
      'over 1500 cached wrappers)', grew < 100)
check('the app instance wrapper is stable too',
      Qt::CoreApplication.instance.equal?(Qt::CoreApplication.instance))

# ---------------------------------------------------------------------------
# Qt::Menu#exec. Same nested-loop problem as QDialog#exec, plus nothing
# headless can dismiss it. helper.rb's popup arm closes an unclaimed menu;
# POPUP_HANDLERS claims one to drive it.
# ---------------------------------------------------------------------------
menu = Qt::Menu.new
alpha = menu.addAction('Alpha')
beta = menu.addAction('Beta')
started = Time.now
seen_before = POPUPS_SEEN.length
check('an unattended menu is dismissed and exec returns nil',
      menu.exec(Qt::Point.new(10, 10)).nil?)
check("... without blocking (#{(Time.now - started).round(2)}s)", (Time.now - started) < 5)
check('the popup arm saw it', POPUPS_SEEN.length == seen_before + 1)
check('the menu is hidden afterwards', !menu.visible?)

fired = false
beta.connect(SIGNAL('triggered()')) { fired = true }
POPUP_HANDLERS << lambda do |popup|
  popup.actions.find { |action| action.text == 'Beta' }.trigger
  popup.close
  true
end
begin
  chosen = menu.exec(Qt::Point.new(10, 10))
ensure
  POPUP_HANDLERS.clear
end
check("exec returns the action that was triggered (#{chosen && chosen.text})",
      chosen.equal?(beta))
check("the action's own handler ran", fired)

POPUP_HANDLERS << lambda { |popup| popup.close; true }
begin
  check('a menu dismissed without a selection returns nil', menu.exec.nil?)
ensure
  POPUP_HANDLERS.clear
end

# The GVL point: a background thread has to keep running while the menu is up
counter = 0
spawned = false
POPUP_HANDLERS << lambda do |popup|
  next true if spawned # the arm polls every 50ms; only start the thread once
  spawned = true
  Thread.new do
    30.times { counter += 1; sleep 0.005 }
    Qt.execute_in_main_thread(false) do
      popup.actions.find { |action| action.text == 'Alpha' }.trigger
      popup.close
    end
  end
  true
end
begin
  chosen = menu.exec(Qt::Point.new(10, 10))
ensure
  POPUP_HANDLERS.clear
end
check("a background thread ran while the menu was up (counter=#{counter})", counter == 30)
check('and its choice came back out of exec', chosen.equal?(alpha))
menu.dispose
settle

puts 'TEST_BINDINGS OK'
