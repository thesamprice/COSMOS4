# Runs a headless CmdTlmServer with the demo configuration so the Python
# API examples in this directory have something to talk to.
#
#   env COSMOS_USERPATH=$(pwd)/demo bundle exec ruby python/run_demo_server.rb
#
# The JSON-RPC API listens on http://127.0.0.1:7777. Ctrl-C to stop.
require 'cosmos'
require 'cosmos/tools/cmd_tlm_server/cmd_tlm_server'

server = Cosmos::CmdTlmServer.new
puts "CmdTlmServer up: API on port #{Cosmos::System.ports['CTS_API']}"
$stdout.flush
begin
  sleep 1 while true
rescue Interrupt
ensure
  server.stop
end
