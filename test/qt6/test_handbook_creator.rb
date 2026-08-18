require_relative 'helper'

require 'cosmos/tools/handbook_creator/handbook_creator'
require 'fileutils'

# ---------------------------------------------------------------------------
# Main window. HandbookCreator parses options.config_file into a
# HandbookCreatorConfig inside its Splash block, so everything below depends
# on the splash worker having finished.
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Handbook Creator'
options.config_file = 'handbook_creator.txt'

HANDBOOKS = Cosmos::System.paths['HANDBOOKS']
# Start from a clean output directory so "the file exists" means this run
# created it and not a previous one
Dir.glob(File.join(HANDBOOKS, '*.html')).each { |f| File.delete(f) }
FileUtils.rm_rf(File.join(HANDBOOKS, 'assets'))

hc = Cosmos::HandbookCreator.new(options)
pump(60, 0.05)

check('constructed', hc.is_a?(Cosmos::HandbookCreator))
check('visible', hc.visible?)
check('titled', hc.windowTitle == 'Handbook Creator')

config = hc.instance_variable_get(:@config)
check('config parsed', config.is_a?(Cosmos::HandbookCreatorConfig))

# demo/config/tools/handbook_creator/handbook_creator.txt defines three PAGEs
# plus one TARGET_PAGES, which fans out to one file per target
pages = config.pages.map(&:filename)
check("pages #{pages.inspect}",
      pages == ['index.html', 'command_handbook.html',
                'telemetry_handbook.html', '_cmd_tlm.html'])
check('index page has NO_PDF', config.pages[0].pdf == false)
check('command page keeps PDF', config.pages[1].pdf == true)
check('target page is :TARGETS', config.pages[3].type == :TARGETS)

# Sections carry the output filter (ALL/HTML/PDF) and the packet type
sections = config.pages[1].sections
check("command page sections (#{sections.length})", sections.length == 6)
check('nav section is HTML only',
      sections[1].output == :HTML && sections[1].filename.end_with?('nav.html.erb'))
check('command_packets is a :CMD section',
      sections[4].type == :CMD && sections[4].output == :ALL)

# ---------------------------------------------------------------------------
# Generate the HTML handbooks by clicking the button, which is what also
# exercises copy_assets and the "Done" QMessageBox
# ---------------------------------------------------------------------------
hc.instance_variable_get(:@html_button).click
pump(80, 0.05)
check('HTML button put up its Done dialog', MODALS_SEEN.include?('Qt::MessageBox'))

check('assets copied', File.directory?(File.join(HANDBOOKS, 'assets')))
check('bootstrap css copied',
      File.file?(File.join(HANDBOOKS, 'assets', 'css', 'bootstrap.min.css')))

EXPECTED_FILES = ['index.html', 'command_handbook.html', 'telemetry_handbook.html',
                  'inst_cmd_tlm.html', 'inst2_cmd_tlm.html', 'system_cmd_tlm.html',
                  'example_cmd_tlm.html', 'templated_cmd_tlm.html', 'dart_cmd_tlm.html']
EXPECTED_FILES.each do |name|
  path = File.join(HANDBOOKS, name)
  check("generated #{name} (#{File.exist?(path) ? File.size(path) : 'MISSING'} bytes)",
        File.exist?(path) && File.size(path) > 0)
end

# ---------------------------------------------------------------------------
# Generated content. Each ERB template is rendered with a binding that carries
# the packets / ignored hashes, so real target and packet names have to show
# up in the output for the pipeline to be working end to end.
# ---------------------------------------------------------------------------
index = File.read(File.join(HANDBOOKS, 'index.html'))
check('index has the handbook title', index.include?('<title>Command and Telemetry Handbook</title>'))
check('index navs to the command handbook',
      index.include?('<a href="command_handbook.html">All Commands</a>'))
check('index navs to a per-target page',
      index.include?('<a href="inst_cmd_tlm.html">INST</a>'))
check('index rendered the overview section',
      index.include?('This is the Command and Telemetry Handbook for the Demo COSMOS Configuration.'))

cmd = File.read(File.join(HANDBOOKS, 'command_handbook.html'))
check('command handbook has the INST COLLECT anchor', cmd.include?('id="cmd_INST_COLLECT"'))
check('command handbook has the INST COLLECT heading', cmd.include?('<h2>INST COLLECT</h2>'))
check('command handbook has the COLLECT table of contents entry',
      cmd.include?('<a href="#cmd_INST_COLLECT">INST COLLECT</a>'))
check('command handbook describes COLLECT parameters', cmd.include?('DURATION'))
check('command handbook flags a hazardous command', cmd.include?('Hazardous'))

tlm = File.read(File.join(HANDBOOKS, 'telemetry_handbook.html'))
check('telemetry handbook has INST HEALTH_STATUS', tlm.include?('<h2>INST HEALTH_STATUS</h2>'))
check('telemetry handbook has the TEMP1 item', tlm.include?('TEMP1'))
check('telemetry handbook rendered the limits groups section',
      tlm.include?('id="tlm_INST_HEALTH_STATUS"') && tlm.include?('Limits Group'))

inst = File.read(File.join(HANDBOOKS, 'inst_cmd_tlm.html'))
check('target page has both a command and a telemetry section',
      inst.include?('<h2>INST COLLECT</h2>') && inst.include?('<h2>INST HEALTH_STATUS</h2>'))
check('target page only covers its own target', !inst.include?('<h2>INST2 COLLECT</h2>'))

# Ignored items are included by default and dropped when Hide Ignored is on
check('CCSDSVER present while Hide Ignored is off', tlm.include?('CCSDSVER'))

screenshot(hc, '/tmp/cosmos_handbook_creator_qt6.png')

# ---------------------------------------------------------------------------
# Hide Ignored Items regenerates without the target's ignored items
# ---------------------------------------------------------------------------
hide_ignored = hc.instance_variable_get(:@hide_ignored_action)
check('Hide Ignored action is checkable',
      hide_ignored.isCheckable && !hide_ignored.isChecked)
hide_ignored.setChecked(true)
hc.instance_variable_get(:@html_button).click
pump(80, 0.05)
tlm_hidden = File.read(File.join(HANDBOOKS, 'telemetry_handbook.html'))
check('CCSDSVER dropped with Hide Ignored on', !tlm_hidden.include?('CCSDSVER'))
check('real items survive Hide Ignored', tlm_hidden.include?('TEMP1'))
hide_ignored.setChecked(false)

# ---------------------------------------------------------------------------
# PDF generation shells out to wkhtmltopdf. It is not a COSMOS dependency, so
# assert the tool punts gracefully rather than raising when it is missing.
# ---------------------------------------------------------------------------
wkhtmltopdf = ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
  File.executable?(File.join(dir, 'wkhtmltopdf'))
end
if wkhtmltopdf
  say 'skip: wkhtmltopdf is installed, not asserting the missing-binary path'
else
  check('create_pdf returns false instead of raising when wkhtmltopdf is missing',
        config.create_pdf(false, nil) == false)
end

hc.close
pump(20)
puts 'TEST_HANDBOOK_CREATOR OK'
