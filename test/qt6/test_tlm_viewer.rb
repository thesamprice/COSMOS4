require_relative 'helper'

require 'cosmos/tools/tlm_viewer/tlm_viewer'

# ---------------------------------------------------------------------------
# Main window: the screen list built from the demo tlm_viewer.txt config
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Telemetry Viewer'
options.listen = false      # don't bind the TLMVIEWER_API DRb port
options.show_main = true    # otherwise initialize() hides the window
options.production = false
options.replay = false
options.restore_size = false
options.config_file = File.join(Cosmos::USERPATH, 'config', 'tools',
                                'tlm_viewer', 'tlm_viewer.txt')

tv = Cosmos::TlmViewer.new(options)
pump(30, 0.05)

check('constructed', tv.is_a?(Cosmos::TlmViewer))
check('visible', tv.visible?)
check('titled', tv.windowTitle == 'Telemetry Viewer')

config = tv.instance_variable_get(:@tlm_viewer_config)
screen_names = config.screen_infos.keys.sort
check("30 screens discovered (#{screen_names.length})", screen_names.length == 30)
check('AUTO_TARGETS picked up every demo target',
      %w(INST\ HS INST\ ADCS INST\ LIMITS INST\ GROUND INST\ GRAPHS
         INST2\ HS SYSTEM\ STATUS DART\ STATUS).all? { |n| screen_names.include?(n) })

# The GROUP keyword in tlm_viewer.txt adds a "My group" column entry alongside
# the per-target ones produced by AUTO_TARGETS.
targets = config.columns.flat_map { |col| col.map { |target_name, _| target_name } }
check("target columns #{targets.inspect}",
      %w(INST INST2 DART SYSTEM).all? { |t| targets.include?(t) } &&
      targets.include?('My group'))

check('search box built', tv.instance_variable_get(:@search_box).is_a?(Qt::Widget))
check('replay flag hidden', !tv.instance_variable_get(:@replay_flag).visible?)

screenshot(tv, '/tmp/cosmos_tlm_viewer_qt6.png')

# ---------------------------------------------------------------------------
# The display/clear API the Show Screen buttons (and the script Script#display
# method) drive: builds a Screen through Qt.execute_in_main_thread, raises an
# already-open screen instead of duplicating it, and tears it down on clear.
# ---------------------------------------------------------------------------
tv.display('INST ADCS')
pump(30, 0.05)
adcs_info = config.screen_infos['INST ADCS']
check('display() built the screen', adcs_info.screen.is_a?(Cosmos::Screen))
check('display() screen has a window', !adcs_info.screen.window.nil?)
check('display() titled', adcs_info.screen.windowTitle == 'INST ADCS')
check("one open screen (#{Cosmos::Screen.open_screens.length})",
      Cosmos::Screen.open_screens.length == 1)

# display() hardcodes :REALTIME, so this screen's value thread calls
# get_tlm_values against a CmdTlmServer that isn't running. Left alone it
# retries over DRb and contends with the main thread through
# Qt.execute_in_main_thread, which makes the rest of this section flaky.
# Stop it the same way test_limits_monitor stops its threads.
adcs_widgets = adcs_info.screen.instance_variable_get(:@widgets)
adcs_widgets.instance_variable_set(:@alive, false)
adcs_widgets.graceful_kill
pump(10)

tv.display('INST ADCS') # already open: raises it rather than opening a second
pump(20, 0.05)
check("still one open screen (#{Cosmos::Screen.open_screens.length})",
      Cosmos::Screen.open_screens.length == 1)

tv.clear('INST ADCS')
pump(20, 0.05)
check('clear() closed the screen', Cosmos::Screen.open_screens.empty? &&
                                   adcs_info.screen.nil?)

# ---------------------------------------------------------------------------
# Screens. Built in a non-:REALTIME mode so the value thread does not try to
# reach a CmdTlmServer; values are driven by hand below instead.
# ---------------------------------------------------------------------------
def build_screen(config, full_name)
  info = config.screen_infos[full_name]
  raise "no such screen #{full_name}" unless info
  screen = Cosmos::Screen.new(info.full_name, info.filename, nil, :TEST, nil, nil,
                              info.original_target_name, info.substitute,
                              info.force_substitute)
  pump(15, 0.02)
  raise "screen #{full_name} failed to build" unless screen.window
  screen
end

# Widget bookkeeping lives on the Screen::Widgets instance
def widget_bag(screen)
  screen.instance_variable_get(:@widgets)
end

def widget_classes(screen)
  screen.widgets.map { |w| w.class.name.split('::').last }
end

# --- INST HS: labels, values, limits bars, buttons, group boxes -------------
hs = build_screen(config, 'INST HS')
check('HS titled', hs.windowTitle == 'INST HS')
check("HS has no invalid items #{widget_bag(hs).invalid.inspect}",
      widget_bag(hs).invalid.empty?)

hs_classes = widget_classes(hs)
%w(TitleWidget VerticalWidget VerticalboxWidget SectionheaderWidget ButtonWidget
   FormatvalueWidget LabelvalueWidget LabelvaluelimitsbarWidget
   LabeltrendlimitsbarWidget ScreenshotbuttonWidget).each do |klass|
  check("HS builds a #{klass}", hs_classes.include?(klass))
end
check("HS has 13 value-taking widgets (#{widget_bag(hs).item.length})",
      widget_bag(hs).item.length == 13)

# The COLORBLIND global setting from the screen file reaches the limits bars
bar = hs.widgets.find { |w| w.is_a?(Cosmos::LabelvaluelimitsbarWidget) }
check('LABELVALUELIMITSBAR is a composite of label+value and a limits bar',
      bar.widgets[0].is_a?(Cosmos::LabelvalueWidget) &&
      bar.widgets[1].is_a?(Cosmos::LimitsbarWidget))

# Drive one update cycle by hand, the way Screen::Widgets#update_gui does.
# hs.txt declares TEMP2 three times (CONVERTED/FORMATTED/WITH_UNITS) plus
# TEMP3 and TEMP4; TEMP1 is a LABELTRENDLIMITSBAR and so is not in this list.
temp_bars = hs.widgets.select do |w|
  w.is_a?(Cosmos::LabelvaluelimitsbarWidget) && w.item_name.start_with?('TEMP')
end
check("5 TEMP limits bars (#{temp_bars.length})", temp_bars.length == 5)

states = [:GREEN, :YELLOW_HIGH, :RED_HIGH, :GREEN, :RED_LOW]
values = [25.0, 32.5, 85.0, -15.25, -99.5]
temp_bars.each_with_index do |widget, i|
  widget.limits_state = states[i]
  widget.value = values[i]
end
pump(15)

# LabelvalueWidget is itself a composite: [LabelWidget, ValueWidget]
displayed = temp_bars.map { |bar_widget| bar_widget.widgets[0].widgets[1].text }
check("TEMP values displayed #{displayed.inspect}",
      values.each_with_index.all? { |v, i| displayed[i].include?(v.to_s) })
check('limits states recorded', temp_bars.map(&:limits_state) == states)

screenshot(hs, '/tmp/cosmos_tlm_screen_inst_hs_qt6.png')

# --- INST LIMITS: the full custom-painted limits/range widget family --------
limits = build_screen(config, 'INST LIMITS')
limits_classes = widget_classes(limits)
%w(LimitsbarWidget ValuelimitsbarWidget LabelvaluelimitsbarWidget
   RangebarWidget ValuerangebarWidget LabelvaluerangebarWidget
   LimitscolorWidget LimitscolumnWidget ValuelimitscolumnWidget
   LabelvaluelimitscolumnWidget RangecolumnWidget ValuerangecolumnWidget
   LabelvaluerangecolumnWidget).each do |klass|
  check("LIMITS builds a #{klass}", limits_classes.include?(klass))
end
check("LIMITS has no invalid items #{widget_bag(limits).invalid.inspect}",
      widget_bag(limits).invalid.empty?)

# SUBSETTING MIN_VALUE/MAX_VALUE reach the nested LimitsbarWidget
narrowed = limits.widgets.select { |w| w.is_a?(Cosmos::LabelvaluelimitsbarWidget) }
check("7 LABELVALUELIMITSBARs (#{narrowed.length})", narrowed.length == 7)
check('MIN_VALUE/MAX_VALUE subsettings applied to the nested bar',
      narrowed[1].widgets[1].instance_variable_get(:@min_value) == -80.0 &&
      narrowed[1].widgets[1].instance_variable_get(:@max_value) == 80.0)

screenshot(limits, '/tmp/cosmos_tlm_screen_inst_limits_qt6.png')

# --- INST GROUND: canvas widgets (QPainter drawImage/drawLine/drawText) -----
ground = build_screen(config, 'INST GROUND')
canvas = ground.widgets.find { |w| w.is_a?(Cosmos::CanvasWidget) }
check('GROUND builds a CanvasWidget', !canvas.nil?)
painted = canvas.instance_variable_get(:@repaint_objects)
check("canvas has painted children (#{painted.length})", painted.length >= 5)
painted_classes = painted.map { |o| o.class.name.split('::').last }.uniq
check("canvas child types #{painted_classes.inspect}",
      painted_classes.include?('CanvasimageWidget') &&
      painted_classes.include?('CanvaslabelWidget') &&
      painted_classes.include?('CanvasimagevalueWidget'))
screenshot(ground, '/tmp/cosmos_tlm_screen_inst_ground_qt6.png')

# --- INST GRAPHS: LINEGRAPH inside a MATRIXBYCOLUMNS layout ----------------
# Regression for Range#size raising on Ruby >= 3.4 in auto_scale_y_axis, which
# aborted LineGraph#paintEvent and left the graphs blank.
graphs = build_screen(config, 'INST GRAPHS')
graph_widgets = graphs.widgets.select { |w| w.is_a?(Cosmos::LinegraphWidget) }
check("4 line graphs (#{graph_widgets.length})", graph_widgets.length == 4)
check('graphs sit in a MATRIXBYCOLUMNS layout',
      widget_classes(graphs).include?('MatrixbycolumnsWidget'))
screenshot(graphs, '/tmp/cosmos_tlm_screen_inst_graphs_qt6.png')

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
[hs, limits, ground, graphs].each(&:close)
pump(20)
check('all screens deregistered', Cosmos::Screen.open_screens.empty?)

tv.close
pump(20)
puts 'TEST_TLM_VIEWER OK'
