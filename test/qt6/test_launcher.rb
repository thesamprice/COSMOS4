require_relative 'test_helper'

require 'cosmos/tools/launcher/launcher_config'
require 'cosmos/tools/launcher/launcher_tool'
require 'cosmos/tools/launcher/launcher_multitool'
require 'cosmos/gui/dialogs/legal_dialog'
require 'cosmos/tools/launcher/launcher'

options = default_tool_options
options.title = 'Launcher'
options.config_file = true
options.mini = false

launcher = Cosmos::Launcher.new(options)
pump
check('constructed', launcher.is_a?(Cosmos::Launcher))
check('visible', launcher.visible?)
check('titled', launcher.windowTitle == 'Launcher')
check('reasonable size', launcher.size.width > 300 && launcher.size.height > 300)
screenshot(launcher, '/tmp/cosmos_launcher_qt6.png')
launcher.close
pump(10)
puts 'TEST_LAUNCHER OK'
