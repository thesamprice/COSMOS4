require_relative 'helper'

require 'cosmos/tools/cmd_tlm_server/cmd_tlm_server_gui'

# The CmdTlmServer binds the CTS_API port and starts interface, router,
# logging and background-task threads. Everything below therefore runs inside
# a begin/ensure so a failure still shuts the server down and frees the port.
options = default_tool_options
options.title = Cosmos::CmdTlmServerGui::TOOL_NAME
options.auto_size = false
options.width = 800
options.height = 500
options.production = false
options.no_prompt = true # skip the "Are you sure?" dialog in closeEvent
options.no_gui = false
options.replay = false
options.replay_routers = false
options.config_file = 'cmd_tlm_server.txt'
options.config_dir = File.join(Cosmos::USERPATH, 'config', 'tools', 'cmd_tlm_server')

# Running the real server writes real packet logs into demo/outputs/logs.
# test_tlm_extractor.rb and test_tlm_grapher.rb both process "the newest
# *_tlm.bin in the demo log directory", and the handful of seconds of data
# this test produces is far too short for their assertions, so remember what
# was there beforehand and remove whatever we add.
PACKET_LOG_GLOB = File.join(Cosmos::System.paths['LOGS'], '*_{tlm,cmd}.bin')
PRE_EXISTING_PACKET_LOGS = Dir[PACKET_LOG_GLOB]

cts = nil
begin
  cts = Cosmos::CmdTlmServerGui.new(options)

  # CmdTlmServerGui#initialize kicks the whole server start off inside
  # Splash.execute, which runs the block on a worker thread and returns
  # immediately. That worker calls back into the main thread to populate the
  # tabs, so pump until it reports it is done rather than sleeping a fixed
  # amount.
  200.times do
    APP.processEvents
    break if cts.instance_variable_get(:@tabs_ready)
    sleep 0.05
  end
  check('constructed', cts.is_a?(Cosmos::CmdTlmServerGui))
  check('server ready', cts.instance_variable_get(:@ready) == true)
  check('tabs ready', cts.instance_variable_get(:@tabs_ready) == true)
  check('visible', cts.visible?)
  # The demo config's TITLE keyword overrides options.title
  check("titled from config (#{cts.windowTitle})",
        cts.windowTitle == 'COSMOS Command and Telemetry Server - Demo Configuration')
  check('CmdTlmServer instance running', Cosmos::CmdTlmServer.instance.is_a?(Cosmos::CmdTlmServer))
  check('JSON DRb serving CTS_API port',
        Cosmos::CmdTlmServer.json_drb.request_count.is_a?(Integer))

  tab_widget = cts.instance_variable_get(:@tab_widget)
  tabs = (0...tab_widget.count).map { |i| tab_widget.tabText(i) }
  check("tabs #{tabs.inspect}",
        tabs == ['Interfaces', 'Targets', 'Cmd Packets', 'Tlm Packets',
                 'Routers', 'Logging', 'Status'])

  #
  # Interfaces tab -- the demo's INST/INST2 interfaces are simulated and
  # connect internally, so wait for the *table* (not the interface object) to
  # show them connected. That proves the tab's update thread is running and
  # marshalling into the main thread.
  #
  interfaces_tab = cts.instance_variable_get(:@interfaces_tab)
  table = interfaces_tab.instance_variable_get(:@interfaces_table)
  headers = (0...table.columnCount).map { |c| table.horizontalHeaderItem(c).text.strip }
  check("interface headers #{headers.inspect}",
        headers[0] == 'Interface' && headers[2] == 'Connected?' &&
        headers[7] == 'Bytes Rx' && headers[9] == 'Tlm Pkts')

  interface_names = (0...table.rowCount).map { |r| table.item(r, 0).text }
  check("interfaces listed #{interface_names.inspect}",
        interface_names.include?('INST_INT') && interface_names.include?('INST2_INT') &&
        interface_names.include?('SYSTEM_INT'))
  inst_row = interface_names.index('INST_INT')

  connected = false
  300.times do
    APP.processEvents
    if table.item(inst_row, 2).text == 'true' && table.item(inst_row, 9).text.to_i > 0
      connected = true
      break
    end
    sleep 0.05
  end
  check("INST_INT connected in table (state=#{table.item(inst_row, 2).text})", connected)
  check("INST_INT Connect/Disconnect button reads Disconnect",
        table.cellWidget(inst_row, 1).text == 'Disconnect')
  # SYSTEM_INT is declared DISABLE_DISCONNECT in the demo config
  system_row = interface_names.index('SYSTEM_INT')
  check('SYSTEM_INT disconnect button disabled', !table.cellWidget(system_row, 1).enabled?)

  first_bytes = table.item(inst_row, 7).text.to_i
  first_pkts = table.item(inst_row, 9).text.to_i
  check("INST_INT has traffic (#{first_bytes} bytes, #{first_pkts} pkts)",
        first_bytes > 0 && first_pkts > 0)

  # The message log pane is fed by the output thread reading the $stdout
  # StringIO the GUI installed, so it should be filling with server messages.
  output = cts.instance_variable_get(:@output)
  messages = ''
  200.times do
    APP.processEvents
    messages = output.toPlainText
    break unless messages.empty?
    sleep 0.05
  end
  check("message log pane populated (#{messages.split("\n").length} lines)",
        !messages.empty?)
  check('message log is timestamped', messages =~ %r{^\d{4}/\d{2}/\d{2} })
  check('message log written to disk',
        cts.instance_variable_get(:@message_log).filename &&
        File.exist?(cts.instance_variable_get(:@message_log).filename))

  screenshot(cts, '/tmp/cosmos_cts_gui_qt6.png')

  # Let the interfaces tab thread run a few more update cycles (period 1.0s)
  # and confirm the counts in the table really move.
  grew = false
  200.times do
    APP.processEvents
    if table.item(inst_row, 7).text.to_i > first_bytes &&
       table.item(inst_row, 9).text.to_i > first_pkts
      grew = true
      break
    end
    sleep 0.05
  end
  check("INST_INT counts incremented (#{first_bytes}->#{table.item(inst_row, 7).text} bytes, " \
        "#{first_pkts}->#{table.item(inst_row, 9).text} pkts)", grew)
  screenshot(cts, '/tmp/cosmos_cts_gui_qt6_counts.png')

  #
  # Targets tab
  #
  tab_widget.setCurrentIndex(1)
  pump(40, 0.05)
  targets_tab = cts.instance_variable_get(:@targets_tab)
  targets_table = targets_tab.instance_variable_get(:@targets_table)
  target_names = (0...targets_table.rowCount).map { |r| targets_table.item(r, 0).text }
  check("targets listed #{target_names.inspect}",
        target_names.include?('INST') && target_names.include?('INST2') &&
        target_names.include?('SYSTEM'))
  inst_target_row = target_names.index('INST')
  check("INST mapped to its interface (#{targets_table.item(inst_target_row, 1).text})",
        targets_table.item(inst_target_row, 1).text == 'INST_INT')
  check("INST telemetry count > 0 (#{targets_table.item(inst_target_row, 3).text})",
        targets_table.item(inst_target_row, 3).text.to_i > 0)

  #
  # Cmd Packets / Tlm Packets tabs
  #
  tab_widget.setCurrentIndex(2)
  pump(40, 0.05)
  commands_table = cts.instance_variable_get(:@commands_tab).instance_variable_get(:@packets_table)
  check("command packets table populated (#{commands_table.rowCount} rows)",
        commands_table.rowCount > 10)
  cmd_rows = (0...commands_table.rowCount).map { |r| [commands_table.item(r, 0).text, commands_table.item(r, 1).text] }
  check('INST COLLECT command listed', cmd_rows.include?(['INST', 'COLLECT']))
  check('UNKNOWN UNKNOWN row present', cmd_rows.include?(['UNKNOWN', 'UNKNOWN']))

  tab_widget.setCurrentIndex(3)
  pump(60, 0.05)
  telemetry_table = cts.instance_variable_get(:@telemetry_tab).instance_variable_get(:@packets_table)
  tlm_rows = (0...telemetry_table.rowCount).map { |r| [telemetry_table.item(r, 0).text, telemetry_table.item(r, 1).text] }
  hs_row = tlm_rows.index(['INST', 'HEALTH_STATUS'])
  check("INST HEALTH_STATUS listed (#{telemetry_table.rowCount} rows)", !hs_row.nil?)
  hs_count = telemetry_table.item(hs_row, 2).text.to_i
  check("INST HEALTH_STATUS received count > 0 (#{hs_count})", hs_count > 0)

  #
  # Routers tab
  #
  tab_widget.setCurrentIndex(4)
  pump(40, 0.05)
  routers_table = cts.instance_variable_get(:@routers_tab).instance_variable_get(:@interfaces_table)
  router_names = (0...routers_table.rowCount).map { |r| routers_table.item(r, 0).text }
  check("routers listed #{router_names.inspect}", router_names.include?('INST_ROUTER'))
  router_headers = (0...routers_table.columnCount).map { |c| routers_table.horizontalHeaderItem(c).text.strip }
  check("router headers #{router_headers.inspect}",
        router_headers[0] == 'Router' && router_headers[8] == 'Pkts Rcvd')

  #
  # Logging tab -- LoggingTab#update writes into QFormLayout rows via
  # itemAt(row, FieldRole), so this exercises that overload end to end.
  #
  tab_widget.setCurrentIndex(5)
  pump(60, 0.05)
  logging_tab = cts.instance_variable_get(:@logging_tab)
  logging_layouts = logging_tab.instance_variable_get(:@logging_layouts)
  check("logging layouts built #{logging_layouts.keys.inspect}",
        logging_layouts.keys.include?('DEFAULT'))
  default_layout = logging_layouts['DEFAULT']
  tlm_logging = default_layout.itemAt(5, Qt::FormLayout::FieldRole).widget.text
  tlm_filename = default_layout.itemAt(7, Qt::FormLayout::FieldRole).widget.text
  check("tlm logging enabled (#{tlm_logging})", tlm_logging == 'true')
  check("tlm log filename shown (#{File.basename(tlm_filename.to_s)})",
        tlm_filename.to_s.end_with?('_tlm.bin'))
  screenshot(cts, '/tmp/cosmos_cts_gui_qt6_logging.png')

  #
  # Status tab
  #
  tab_widget.setCurrentIndex(6)
  pump(60, 0.05)
  status_tab = cts.instance_variable_get(:@status_tab)
  api_table = status_tab.instance_variable_get(:@api_table)
  check("API port is CTS_API (#{api_table.item(0, 0).text})",
        api_table.item(0, 0).text == Cosmos::System.ports['CTS_API'].to_s)
  system_table = status_tab.instance_variable_get(:@system_table)
  check("thread count reported (#{system_table.item(0, 0).text})",
        system_table.item(0, 0).text.to_i > 1)
  background_table = status_tab.instance_variable_get(:@background_tasks_table)
  task_names = (0...background_table.rowCount).map { |r| background_table.item(r, 0).text }
  check("background tasks listed #{task_names.inspect}", background_table.rowCount >= 2)
  limits_combo = status_tab.instance_variable_get(:@limits_set_combo)
  check("limits set combo shows current set (#{limits_combo.currentText})",
        limits_combo.currentText == Cosmos::System.limits_set.to_s)
  screenshot(cts, '/tmp/cosmos_cts_gui_qt6_status.png')

  tab_widget.setCurrentIndex(0)
  pump(20, 0.05)
  check('back on Interfaces tab', tab_widget.tabText(tab_widget.currentIndex) == 'Interfaces')

  #
  # Shutdown: closeEvent stops the tab thread, stops logging and stops the
  # server (releasing the API port).
  #
  interface = Cosmos::CmdTlmServer.interfaces.all['INST_INT']
  cts.close
  pump(60, 0.05)
  check('window hidden after close', !cts.visible?)
  check('tab thread stopped', cts.instance_variable_get(:@tab_thread).nil?)
  check('interface disconnected by shutdown', !interface.connected?)
  check('json_drb no longer listening', Cosmos::CmdTlmServer.json_drb.thread.nil? ||
        !Cosmos::CmdTlmServer.json_drb.thread.alive?)
ensure
  # Belt and braces: if anything above raised before close, still stop the
  # server so the API port is not left bound for the next test.
  begin
    if Cosmos::CmdTlmServer.instance
      Cosmos::CmdTlmServer.instance.stop_logging('ALL')
      Cosmos::CmdTlmServer.instance.stop
    end
  rescue Exception => error
    say "shutdown error (ignored): #{error.class}: #{error.message}"
  end
  # Now that the log writers are closed, drop the packet logs this run created
  # so the next test still sees the demo's own logs as the newest ones.
  (Dir[PACKET_LOG_GLOB] - PRE_EXISTING_PACKET_LOGS).each do |written|
    File.delete(written)
    say "cleaned up #{File.basename(written)}"
  end
  # CmdTlmServerGui#initialize_central_widget points $stdout at a StringIO so
  # server output lands in the message pane. Put the real stream back now that
  # the server is stopped, otherwise the marker below is swallowed.
  $stdout = REAL_STDOUT
end

puts 'TEST_CMD_TLM_SERVER_GUI OK'
