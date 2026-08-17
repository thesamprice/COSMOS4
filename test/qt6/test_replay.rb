require_relative 'helper'

require 'cosmos/tools/replay/replay'

# Replay is CmdTlmServerGui in :REPLAY mode: same window, but the Interfaces
# tab is swapped for the Replay tab and telemetry is sourced from a log file
# instead of live interfaces. It binds REPLAY_API rather than CTS_API.
options = default_tool_options
options.title = 'Replay'
options.auto_size = false
options.width = 800
options.height = 500
options.production = false
options.no_prompt = true
options.no_gui = false
options.replay = true
options.replay_routers = false
options.config_file = 'cmd_tlm_server.txt'
options.config_dir = File.join(Cosmos::USERPATH, 'config', 'tools', 'cmd_tlm_server')

# Replay needs a telemetry log to play back; any of the demo's *_tlm.bin will
# do. Replay mode does no packet logging of its own, but snapshot the log
# directory anyway so this test cannot leave a short log behind for
# test_tlm_extractor.rb / test_tlm_grapher.rb to pick up as "the newest".
PACKET_LOG_GLOB = File.join(Cosmos::System.paths['LOGS'], '*_{tlm,cmd}.bin')
PRE_EXISTING_PACKET_LOGS = Dir[PACKET_LOG_GLOB]

log_file = Dir[File.join(Cosmos::System.paths['LOGS'], '*_tlm.bin')].sort.last
raise 'no demo *_tlm.bin log to replay' unless log_file

replay = nil
begin
  replay = Cosmos::Replay.new(options)

  200.times do
    APP.processEvents
    break if replay.instance_variable_get(:@tabs_ready)
    sleep 0.05
  end
  check('constructed', replay.is_a?(Cosmos::Replay))
  check('is a CmdTlmServerGui in replay mode', replay.is_a?(Cosmos::CmdTlmServerGui))
  check('server ready', replay.instance_variable_get(:@ready) == true)
  check('tabs ready', replay.instance_variable_get(:@tabs_ready) == true)
  check('visible', replay.visible?)
  check("mode is REPLAY (#{Cosmos::CmdTlmServer.mode})",
        Cosmos::CmdTlmServer.mode == :REPLAY)

  tab_widget = replay.instance_variable_get(:@tab_widget)
  tabs = (0...tab_widget.count).map { |i| tab_widget.tabText(i) }
  # No Interfaces tab and no Logging tab in replay mode
  check("tabs #{tabs.inspect}",
        tabs == ['Replay', 'Targets', 'Cmd Packets', 'Tlm Packets',
                 'Routers', 'Status'])
  check('no interfaces tab', replay.instance_variable_get(:@interfaces_tab).nil?)
  check('no logging tab', replay.instance_variable_get(:@logging_tab).nil?)

  replay_tab = replay.instance_variable_get(:@replay_tab)
  check('replay tab built', replay_tab.is_a?(Cosmos::ReplayTab))
  backend = Cosmos::CmdTlmServer.replay_backend
  check('replay backend present', backend.is_a?(Cosmos::ReplayBackend))

  #
  # VCR transport controls start disabled -- nothing is loaded yet.
  #
  vcr = {
    'move_start' => replay_tab.instance_variable_get(:@move_start),
    'step_back' => replay_tab.instance_variable_get(:@step_back),
    'reverse_play' => replay_tab.instance_variable_get(:@reverse_play),
    'stop' => replay_tab.instance_variable_get(:@stop),
    'play' => replay_tab.instance_variable_get(:@play),
    'step_forward' => replay_tab.instance_variable_get(:@step_forward),
    'move_end' => replay_tab.instance_variable_get(:@move_end)
  }
  disabled = vcr.reject { |_name, button| button.enabled? }.keys
  check("all 7 VCR buttons start disabled (#{disabled.length})", disabled.length == 7)
  status_field = replay_tab.instance_variable_get(:@status)
  check("status starts Stopped (#{status_field.text})", status_field.text == 'Stopped')
  check('log file radio selected by default',
        replay_tab.instance_variable_get(:@log_file_radio).checked?)

  #
  # Load the log through the real Browse... path: ReplayTab#select_log_file
  # opens a modal PacketLogDialog, so claim it with a modal handler that
  # fills in the filename the way handle_browse_button would and accepts.
  # That runs the accept branch which is what enables the VCR buttons.
  #
  accepted = false
  MODAL_HANDLERS << lambda do |dialog|
    next false unless dialog.is_a?(Cosmos::PacketLogDialog)
    frame = dialog.instance_variable_get(:@packet_log_frame)
    list = frame.instance_variable_get(:@filenames)
    if list.findItems(log_file, Qt::MatchExactly).empty?
      list.addItem(log_file)
      frame.change_callback.call(:INPUT_FILES) if frame.change_callback
    end
    accepted = true
    dialog.accept
    true
  end

  replay_tab.send(:select_log_file)
  pump(20, 0.05)
  check('log file dialog accepted', accepted)
  MODAL_HANDLERS.clear

  enabled = vcr.select { |_name, button| button.enabled? }.keys
  check("all 7 VCR buttons enabled after load (#{enabled.length})", enabled.length == 7)

  # select_file analyzes the log on a worker thread; wait for it to index.
  400.times do
    APP.processEvents
    break if backend.status[0] == 'Stopped' && backend.status[7].to_i > 0
    sleep 0.05
  end
  status, _delay, filename, file_start, file_current, file_end, index, max_index = backend.status
  check("log indexed (#{max_index} packets)", max_index.to_i > 0)
  check("backend loaded our log (#{File.basename(filename)})", filename == log_file)
  check("start/end times parsed (#{file_start} .. #{file_end})",
        file_start =~ %r{^\d{4}/\d{2}/\d{2} } && file_end =~ %r{^\d{4}/\d{2}/\d{2} })
  check("backend stopped after analysis (#{status})", status == 'Stopped')

  replay_tab.update
  pump(10)
  check("log name shown in GUI (#{File.basename(replay_tab.instance_variable_get(:@log_name).text)})",
        replay_tab.instance_variable_get(:@log_name).text == log_file)
  check("GUI start time populated (#{replay_tab.instance_variable_get(:@start_time).value})",
        replay_tab.instance_variable_get(:@start_time).value == file_start)
  check("GUI end time populated (#{replay_tab.instance_variable_get(:@end_time).value})",
        replay_tab.instance_variable_get(:@end_time).value == file_end)
  check("speed combo shows a delay (#{replay_tab.instance_variable_get(:@speed_select).currentText})",
        !replay_tab.instance_variable_get(:@speed_select).currentText.to_s.empty?)

  #
  # Step forward a few packets: the file index and the received counts of the
  # telemetry packets in the log both have to move.
  #
  before_index = backend.status[6]
  before_total = Cosmos::System.telemetry.all.values.map(&:values).flatten
                               .map { |packet| packet.received_count.to_i }.sum
  8.times do
    backend.step_forward
    APP.processEvents
  end
  pump(20, 0.05)
  after_index = backend.status[6]
  after_total = Cosmos::System.telemetry.all.values.map(&:values).flatten
                              .map { |packet| packet.received_count.to_i }.sum
  check("file index advanced (#{before_index} -> #{after_index})", after_index > before_index)
  check("telemetry received counts advanced (#{before_total} -> #{after_total})",
        after_total > before_total)

  replay_tab.update
  pump(10)
  check("current time advanced past start (#{replay_tab.instance_variable_get(:@current_time).value})",
        replay_tab.instance_variable_get(:@current_time).value != file_start)
  slider = replay_tab.instance_variable_get(:@slider)
  check("slider tracked the position (#{slider.value})", slider.value > 0)

  # Step back returns the index
  stepped_back = backend.status[6]
  3.times do
    backend.step_back
    APP.processEvents
  end
  pump(10)
  check("file index stepped back (#{stepped_back} -> #{backend.status[6]})",
        backend.status[6] < stepped_back)

  #
  # Play: the backend runs a playback thread that pushes packets until the end
  # of the log, so counts keep moving without us stepping.
  #
  # A small per-packet delay keeps playback running long enough to observe the
  # Playing state; with no delay the whole log is consumed before we can look.
  backend.set_playback_delay(0.01)
  play_start_index = backend.status[6]
  backend.play
  played = false
  200.times do
    APP.processEvents
    if backend.status[6] > play_start_index + 10
      played = true
      break
    end
    sleep 0.05
  end
  check("playback advanced the index (#{play_start_index} -> #{backend.status[6]})", played)
  replay_tab.update
  pump(10)
  check("status reads Playing while playing (#{status_field.text})",
        status_field.text == 'Playing')
  check("speed combo followed the delay (#{replay_tab.instance_variable_get(:@speed_select).currentText})",
        replay_tab.instance_variable_get(:@speed_select).currentText == '10ms Delay')
  screenshot(replay, '/tmp/cosmos_replay_qt6.png')

  backend.stop
  300.times do
    APP.processEvents
    break if backend.status[0] == 'Stopped'
    sleep 0.05
  end
  replay_tab.update
  pump(10)
  check("stopped (#{status_field.text})", status_field.text == 'Stopped')

  #
  # The Tlm Packets tab must show the counts the replayed packets produced.
  #
  tab_widget.setCurrentIndex(3)
  pump(60, 0.05)
  telemetry_table = replay.instance_variable_get(:@telemetry_tab)
                          .instance_variable_get(:@packets_table)
  rows = (0...telemetry_table.rowCount).map { |r| [telemetry_table.item(r, 0).text, telemetry_table.item(r, 1).text] }
  check("INST HEALTH_STATUS listed (#{telemetry_table.rowCount} rows)",
        rows.include?(['INST', 'HEALTH_STATUS']))
  # Which packets appear first depends on the log, so total the column rather
  # than requiring any one packet to have been reached.
  counted = (0...telemetry_table.rowCount).map { |r| telemetry_table.item(r, 2).text.to_i }
  populated = rows.zip(counted).reject { |_row, count| count.zero? }
  check("replayed packet counts shown in the tab #{populated.map { |row, count| "#{row.join(' ')}=#{count}" }.inspect}",
        counted.sum > 10)
  screenshot(replay, '/tmp/cosmos_replay_qt6_tlm_packets.png')

  #
  # Status tab reports the REPLAY_API port, not CTS_API.
  #
  tab_widget.setCurrentIndex(5)
  pump(60, 0.05)
  api_table = replay.instance_variable_get(:@status_tab).instance_variable_get(:@api_table)
  check("API port is REPLAY_API (#{api_table.item(0, 0).text})",
        api_table.item(0, 0).text == Cosmos::System.ports['REPLAY_API'].to_s)

  tab_widget.setCurrentIndex(0)
  pump(20, 0.05)
  check('back on Replay tab', tab_widget.tabText(tab_widget.currentIndex) == 'Replay')

  #
  # Shutdown: closeEvent also shuts the replay backend down.
  #
  replay.close
  pump(60, 0.05)
  check('window hidden after close', !replay.visible?)
  check('tab thread stopped', replay.instance_variable_get(:@tab_thread).nil?)
  check('json_drb no longer listening', Cosmos::CmdTlmServer.json_drb.thread.nil? ||
        !Cosmos::CmdTlmServer.json_drb.thread.alive?)
ensure
  MODAL_HANDLERS.clear
  begin
    if Cosmos::CmdTlmServer.instance
      Cosmos::CmdTlmServer.replay_backend.shutdown if Cosmos::CmdTlmServer.replay_backend
      Cosmos::CmdTlmServer.instance.stop
    end
  rescue Exception => error
    say "shutdown error (ignored): #{error.class}: #{error.message}"
  end
  (Dir[PACKET_LOG_GLOB] - PRE_EXISTING_PACKET_LOGS).each do |written|
    File.delete(written)
    say "cleaned up #{File.basename(written)}"
  end
  # See test_cmd_tlm_server_gui.rb -- the GUI redirected $stdout into the
  # message pane, so restore it before printing the marker.
  $stdout = REAL_STDOUT
end

puts 'TEST_REPLAY OK'
