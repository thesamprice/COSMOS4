require_relative 'helper'

require 'cosmos/tools/tlm_grapher/tlm_grapher'
require 'cosmos/tools/tlm_grapher/data_objects/xy_data_object'
require 'cosmos/tools/tlm_grapher/tabbed_plots_tool/tabbed_plots_logfile_thread'

# ---------------------------------------------------------------------------
# Main window. TlmGrapher.run() fills these in from the command line; the tool
# reads them straight off the options struct in TabbedPlotsTool#initialize.
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Telemetry Grapher'
options.auto_size = false
options.width = 1000
options.height = 800
options.tool_short_name = 'tlmgrapher'
options.tabbed_plots_type = 'overview'
options.data_object_types = %w(HOUSEKEEPING XY SINGLEXY)
options.plot_types = %w(LINEGRAPH XY SINGLEXY)
options.plot_type_to_data_object_type_mapping =
  { 'LINEGRAPH' => ['HOUSEKEEPING'], 'XY' => ['XY'], 'SINGLEXY' => ['SINGLEXY'] }
options.adder_types = ['HOUSEKEEPING']
options.adder_orientation = Qt::Horizontal
options.items = []
options.start = false     # don't dial the CmdTlmServer
options.replay = false
options.about_string = 'TlmGrapher regression'

tg = Cosmos::TlmGrapher.new(options)
pump(40, 0.05)

check('constructed', tg.is_a?(Cosmos::TlmGrapher))
check('visible', tg.visible?)
check('titled', tg.windowTitle == 'Telemetry Grapher')

config = tg.instance_variable_get(:@tabbed_plots_config)
plots  = tg.instance_variable_get(:@tabbed_plots)
check('config built', config.is_a?(Cosmos::TabbedPlotsConfig))
check('overview tabbed plots widget', plots.is_a?(Cosmos::OverviewTabbedPlots))

# No config file was given, so TabbedPlotsConfig synthesizes the default
# structure: one tab holding one plot of the first plot type.
check("default structure is 1 tab / 1 plot (#{config.tabs.length}/#{config.tabs[0].plots.length})",
      config.tabs.length == 1 && config.tabs[0].plots.length == 1)
check('default plot is a LINEGRAPH', config.tabs[0].plots[0].plot_type == 'LINEGRAPH')
check('plot gui object is a LineGraph subclass',
      config.tabs[0].plots[0].gui_object.is_a?(Cosmos::LinegraphPlotGuiObject))
check('plot starts selected', config.tabs[0].plots[0].gui_object.selected?)

# Left panel choosers, data object list and the housekeeping adder
%i(@seconds_plotted @points_saved @points_plotted @refresh_rate_hz
   @data_object_list @tab_book).each do |name|
  widget = plots.instance_variable_get(name)
  check("#{name} built and visible", widget.is_a?(Qt::Widget) && widget.visible?)
end
check("global defaults reached the choosers",
      plots.instance_variable_get(:@seconds_plotted).value == Cosmos::TabbedPlotsConfig::DEFAULT_SECONDS_PLOTTED &&
      plots.instance_variable_get(:@points_saved).value == Cosmos::TabbedPlotsConfig::DEFAULT_POINTS_SAVED)
check('one overview graph per tab',
      plots.instance_variable_get(:@overview_graphs).length == config.tabs.length)
check('housekeeping adder built',
      plots.data_object_adders.length == 1 &&
      plots.data_object_adders[0].is_a?(Cosmos::HousekeepingDataObjectAdder))

screenshot(tg, '/tmp/cosmos_tlm_grapher_qt6.png')

# ---------------------------------------------------------------------------
# Data objects. TEMP1 goes in through the adder's search box the way a user
# adds one; TEMP2 goes through the plain model API.
# ---------------------------------------------------------------------------
adder = plots.data_object_adders[0]
adder.instance_variable_get(:@search_box).callback.call('INST HEALTH_STATUS TEMP1')
pump(10)

temp2 = Cosmos::HousekeepingDataObject.new
temp2.set_item('INST', 'HEALTH_STATUS', 'TEMP2')
plots.add_data_object(0, 0, temp2)
pump(10)

plot = config.tabs[0].plots[0]
check("two data objects #{plot.data_objects.map(&:name).inspect}",
      plot.data_objects.map(&:name) ==
      ['INST HEALTH_STATUS TEMP1', 'INST HEALTH_STATUS TEMP2'])
check("distinct auto-assigned colors #{plot.data_objects.map(&:color).inspect}",
      plot.data_objects.map(&:color) == %w(blue red))
check('data object list shows both',
      plots.instance_variable_get(:@data_object_list).count == 2)
check('time item defaulted to PACKET_TIMESECONDS',
      plot.data_objects.all? { |d| d.time_item_name == 'PACKET_TIMESECONDS' })

# ---------------------------------------------------------------------------
# Feed samples through the same entry point TabbedPlotsRealtimeThread uses:
# its worker thread pops packets off a queue and calls config.process_packet.
# ---------------------------------------------------------------------------
SAMPLES = 300
def inject(config, samples, t0)
  packet = Cosmos::System.telemetry.packet('INST', 'HEALTH_STATUS')
  samples.times do |i|
    packet.received_time = t0 + i
    packet.write('TEMP1', 20.0 * Math.sin(i / 20.0))
    packet.write('TEMP2', 15.0 * Math.cos(i / 30.0) + 5.0)
    config.process_packet(packet)
  end
end
inject(config, SAMPLES, Time.now.sys - SAMPLES)

check("#{SAMPLES} samples landed in each data object " \
      "#{plot.data_objects.map { |d| d.x_values.length }.inspect}",
      plot.data_objects.all? { |d| d.x_values.length == SAMPLES })
check('sample values are the injected sine/cosine',
      (plot.data_objects[0].y_values[0] - 0.0).abs < 0.2 &&
      (plot.data_objects[1].y_values[0] - 20.0).abs < 0.2)
check('processing flagged the plot for redraw', plot.redraw_needed)

plots.resume
plots.redraw_plots(true, true) # what the refresh timer does each tick
pump(30, 0.05)

screenshot(tg, '/tmp/cosmos_tlm_grapher_data_qt6.png')

# The graph is painted into an offscreen buffer by LineGraph#paintEvent, so
# grab the plot widget and look for the two line colors. Counting pixels
# rather than "is the pixmap uniform" catches a graph that drew its frame and
# axes but no data.
def line_pixels(widget)
  image = widget.grab.toImage
  blue = 0
  red = 0
  # Stop short of the bottom of the widget: the legend is drawn there in the
  # line colors and would answer for the lines themselves.
  (0...image.width).step(2) do |x|
    (0...(image.height * 0.85).to_i).step(2) do |y|
      argb = image.pixel(x, y)
      r = (argb >> 16) & 0xFF
      g = (argb >> 8) & 0xFF
      b = argb & 0xFF
      blue += 1 if b > 200 && r < 80 && g < 80
      red += 1 if r > 200 && g < 80 && b < 80
    end
  end
  [blue, red]
end

blue, red = line_pixels(plot.gui_object)
check("blue TEMP1 line drawn (#{blue} px)", blue > 300)
check("red TEMP2 line drawn (#{red} px)", red > 300)
check('graph took no drawing error', plot.gui_object.error.nil?)

# The x axis is labelled with formatted times and the y axis auto-scaled to
# the data, so the graph carries real axis state rather than the +/-1 default.
graph = plot.gui_object
check("left y axis auto-scaled to the data (#{graph.left_y_min} .. #{graph.left_y_max})",
      graph.left_y_min < -15.0 && graph.left_y_max > 15.0)
# redraw_plots scales x to the overview graph's window, which the Seconds
# Plotted chooser sizes; the axis is then labelled with formatted timestamps
# (visible in the screenshot) rather than the raw seconds.
check("x axis follows the #{config.seconds_plotted}s overview window " \
      "(#{(graph.x_max - graph.x_min).round(3)})",
      ((graph.x_max - graph.x_min) - config.seconds_plotted).abs < 1.0)
check('x values are unix epoch times', graph.unix_epoch_x_values)
overview = plots.instance_variable_get(:@overview_graphs)[0]
check('overview graph got both lines',
      overview.instance_variable_get(:@lines).num_lines == 2)

# ---------------------------------------------------------------------------
# A second tab holding an XY plot: a different plot gui object and data object
# family (x from one item, y from another) over the same packet stream.
# ---------------------------------------------------------------------------
plots.add_tab
pump(10)
check("second tab added #{config.tabs.map(&:tab_text).inspect}",
      config.tabs.length == 2 && config.tabs[1].tab_text == 'Tab 2')
check('new tab got a default plot', config.tabs[1].plots.length == 1)

# add_plot(dialog = false) takes the first known plot type; reorder so the
# tool's own code path builds the XY plot and its gui object.
config.plot_types = %w(XY LINEGRAPH SINGLEXY)
plots.add_plot(1, false)
config.plot_types = %w(LINEGRAPH XY SINGLEXY)
pump(10)
xy_plot = config.tabs[1].plots[-1]
check("XY plot added #{config.tabs[1].plots.map(&:plot_type).inspect}",
      xy_plot.plot_type == 'XY')
check('XY gui object built', xy_plot.gui_object.is_a?(Cosmos::XyPlotGuiObject))

xy_object = Cosmos::XyDataObject.new
xy_object.target_name = 'INST'
xy_object.packet_name = 'HEALTH_STATUS'
xy_object.x_item_name = 'TEMP1'
xy_object.y_item_name = 'TEMP2'
plots.add_data_object(1, config.tabs[1].plots.length - 1, xy_object)
pump(10)
check("XY data object named #{xy_object.name.inspect}",
      xy_object.name == 'INST HEALTH_STATUS TEMP2 VS TEMP1')

inject(config, SAMPLES, Time.now.sys - SAMPLES)
check("XY data object collected #{xy_object.x_values.length} points",
      xy_object.x_values.length == SAMPLES)

plots.instance_variable_get(:@tab_book).setCurrentIndex(1)
plots.redraw_plots(true, true)
pump(30, 0.05)
screenshot(tg, '/tmp/cosmos_tlm_grapher_xy_qt6.png')
xy_blue, _ = line_pixels(xy_plot.gui_object)
check("XY curve drawn (#{xy_blue} px)", xy_blue > 300)

# ---------------------------------------------------------------------------
# Configuration round trip: the string the Save Config menu item writes has to
# reload into the same structure.
# ---------------------------------------------------------------------------
config_file = File.join(Dir.tmpdir, 'cosmos_tlm_grapher_qt6_config.txt')
File.write(config_file, config.configuration_string)
reloaded = Cosmos::TabbedPlotsConfig.new(config_file, options.plot_types,
                                         options.data_object_types,
                                         options.plot_type_to_data_object_type_mapping)
check("config reloaded without errors #{reloaded.configuration_errors.map(&:message).inspect}",
      reloaded.configuration_errors.empty?)
check('reloaded tab/plot structure matches',
      reloaded.tabs.map { |t| t.plots.map(&:plot_type) } ==
      config.tabs.map { |t| t.plots.map(&:plot_type) })
check('reloaded data objects match',
      reloaded.tabs.map { |t| t.plots.map { |p| p.data_objects.map(&:name) } } ==
      config.tabs.map { |t| t.plots.map { |p| p.data_objects.map(&:name) } })
File.delete(config_file)

# ---------------------------------------------------------------------------
# Offline graphing: the Open Log path runs the same config.process_packet over
# a packet log instead of a socket.
# ---------------------------------------------------------------------------
log_file = tlm_log_file
config.reset_data_objects
check('reset cleared the data objects',
      plot.data_objects.all? { |d| d.x_values.empty? })

logfile_thread = Cosmos::TabbedPlotsLogfileThread.new([log_file],
                                                      Cosmos::PacketLogReader.new,
                                                      config, nil)
waited = 0.0
until logfile_thread.done? || waited > 60.0
  pump(5, 0.02)
  waited += 0.1
end
check('log file thread finished', logfile_thread.done?)
check("log file processed cleanly #{logfile_thread.errors.map(&:message).inspect}",
      logfile_thread.errors.empty?)
check("log file produced samples #{plot.data_objects.map { |d| d.x_values.length }.inspect}",
      plot.data_objects.all? { |d| d.x_values.length > 10 })

plots.instance_variable_get(:@tab_book).setCurrentIndex(0)
plots.redraw_plots(true, true)
pump(30, 0.05)
screenshot(tg, '/tmp/cosmos_tlm_grapher_logfile_qt6.png')
log_blue, log_red = line_pixels(plot.gui_object)
check("log file data drawn (#{log_blue} blue / #{log_red} red px)",
      log_blue > 300 && log_red > 300)

# ---------------------------------------------------------------------------
# Structure edits. The menu handlers wrap these in confirmation dialogs; drive
# the model API directly (helper.rb auto-dismisses modals with done(0), which
# would answer "No" to the delete confirmations).
# ---------------------------------------------------------------------------
plots.instance_variable_get(:@tab_book).setCurrentIndex(1)
before = config.tabs[1].plots.length
plots.delete_plot(1, before - 1)
pump(10)
check("plot deleted (#{config.tabs[1].plots.length})",
      config.tabs[1].plots.length == before - 1)

plots.delete_data_object(0, 0, 1)
pump(10)
check("data object deleted #{config.tabs[0].plots[0].data_objects.map(&:name).inspect}",
      config.tabs[0].plots[0].data_objects.map(&:name) == ['INST HEALTH_STATUS TEMP1'])

plots.delete_tab(1)
pump(10)
check("tab deleted (#{config.tabs.length})", config.tabs.length == 1)
check('overview graph removed with the tab',
      plots.instance_variable_get(:@overview_graphs).length == 1)

check('editing the config marked the window title modified',
      tg.instance_variable_get(:@config_modified))

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
plots.pause
plots.shutdown
tg.close
pump(20)
puts 'TEST_TLM_GRAPHER OK'
