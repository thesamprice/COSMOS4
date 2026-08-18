# Regenerates test/qt6/fixtures/qt6_demo_tlm.bin, the committed telemetry log
# the qt6 tests fall back to when the machine has never run the demo
# CmdTlmServer (see helper.rb#tlm_log_file).
#
#   env COSMOS_USERPATH=$(pwd)/demo bundle exec ruby \
#       test/qt6/fixtures/build_tlm_log.rb
#
# The packets come from the demo's own simulated target (SimInst), driven the
# same way SimulatedTargetInterface drives it, so the fixture is the log the
# demo would have produced -- same items, same cycling temperatures, same
# CCSDS bookkeeping -- rather than a hand-rolled approximation. What the four
# consumers need out of it:
#
#   tlm_extractor  > 2000 INST ADCS rows spanning > 200 s
#   tlm_grapher    INST HEALTH_STATUS TEMP1/TEMP2 with > 10 samples each
#   replay         enough packets to index, step and play through
#   data_viewer    INST HEALTH_STATUS, ADCS, PARAMS and IMAGE (its 16 KB block
#                  item must reach offset 0x3FF0), SYSTEM META, and no INST2
#
# Two deliberate departures from what the live demo writes, both to keep the
# committed file under a megabyte:
#   * INST IMAGE is emitted every 10 s instead of every second. At the demo
#     rate its 16 KB block alone is 3.5 MB over this run.
#   * INST MECH is dropped: no qt6 test reads it.
# and one for reproducibility: the RNG that fills the IMAGE block is seeded, and
# every packet is stamped from BASE_TIME rather than the clock. Re-running the
# script then reproduces the file to within four bytes -- the received_time of
# the SYSTEM META entry PacketLogWriter#start_new_file_hook writes ahead of the
# first packet, which it stamps from Time.now inside the writer. (Verified with
# `cmp -l`: offsets 133-137 and nothing else.)

require 'cosmos'
require 'cosmos/packet_logs/packet_log_writer'
require 'fileutils'
require 'tmpdir'

require File.join(Cosmos::USERPATH, 'config', 'targets', 'INST', 'lib', 'sim_inst.rb')

OUTPUT = File.join(File.expand_path(__dir__), 'qt6_demo_tlm.bin')
# 215 s of telemetry: tlm_extractor asserts a span greater than 200 s, and its
# 30 s downsample has to leave more than two rows.
DURATION_SECONDS = 215
BASE_TIME = Time.utc(2026, 8, 17, 0, 0, 0)

srand(20260817)

sim = Cosmos::SimInst.new('INST')
sim.set_rates
sim.send(:set_rate, 'IMAGE', 1000) # every 10 s rather than every second
sim.send(:set_rate, 'MECH', nil)   # not read by any qt6 test

Dir.mktmpdir('cosmos_qt6_fixture') do |dir|
  writer = Cosmos::PacketLogWriter.new(:TLM, nil, true, nil, 2_000_000_000, dir, false)
  counts = Hash.new(0)
  (0...(DURATION_SECONDS * 100)).each do |count_100hz|
    time = BASE_TIME + (count_100hz / 100.0)
    sim.read(count_100hz, time).each do |packet|
      # SimInst also throws an unidentified packet at the server every 10 s to
      # demonstrate UNKNOWN handling; it has no target or packet name, so
      # there is nothing for a log consumer to do with it.
      next if packet.packet_name.nil? || packet.target_name.nil?
      packet.received_time = time
      writer.write(packet)
      counts["#{packet.target_name} #{packet.packet_name}"] += 1
    end
  end
  writer.shutdown

  written = Dir[File.join(dir, '*_tlm.bin')].sort.last
  raise 'the writer produced no log' unless written
  FileUtils.rm_f(OUTPUT)
  FileUtils.cp(written, OUTPUT)
  File.chmod(0644, OUTPUT) # the writer leaves finished logs read-only

  puts "wrote #{OUTPUT} (#{File.size(OUTPUT)} bytes)"
  counts.sort.each { |name, n| puts "  #{name}: #{n}" }
end
