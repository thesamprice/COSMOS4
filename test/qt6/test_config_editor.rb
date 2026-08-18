require_relative 'helper'

require 'cosmos/tools/config_editor/config_editor'

CMD_TLM_FILE = File.join(Cosmos::USERPATH, 'config/targets/INST/cmd_tlm/inst_cmds.txt')
TLM_VIEWER_FILE = File.join(Cosmos::USERPATH, 'config/tools/tlm_viewer/tlm_viewer.txt')

check('demo cmd_tlm fixture present', File.exist?(CMD_TLM_FILE))
check('demo tool config fixture present', File.exist?(TLM_VIEWER_FILE))

# ---------------------------------------------------------------------------
# Main window. ConfigEditor parses all 16 *.yaml meta config files on a Splash
# worker before it is usable, so pump long enough for that to land.
# ---------------------------------------------------------------------------
options = default_tool_options
options.title = 'Config Editor'
options.width = 1000
options.height = 700

ce = Cosmos::ConfigEditor.new(options)
ce.resize(1000, 700)
pump(80, 0.05)

check('constructed', ce.is_a?(Cosmos::ConfigEditor))
check('visible', ce.visible?)
check('titled', ce.windowTitle == 'Config Editor : Untitled')

# Every non-separator entry in CONFIGURATION_FILES should have produced a
# parsed meta hash; a Psych failure or a missing yaml would leave a hole.
expected_meta = Cosmos::ConfigEditor::CONFIGURATION_FILES.reject { |_k, v| v[0].nil? }.keys
meta = Cosmos::ConfigEditor.meta
check("all #{expected_meta.length} meta config yaml files parsed",
      expected_meta.all? { |key| meta[key].is_a?(Hash) && !meta[key].empty? })
check('command_telemetry meta carries the COMMAND keyword',
      meta['Command and Telemetry Configuration']['COMMAND']['summary'].to_s.length > 0)

# ---------------------------------------------------------------------------
# File system tree. QFileSystemModel is asynchronous -- it populates a
# directory on a worker thread -- so the demo root has to be pumped for before
# the child rows exist.
# ---------------------------------------------------------------------------
fs_model = ce.instance_variable_get(:@fs_model)
tree_view = ce.instance_variable_get(:@tree_view)
check('file system model built', fs_model.is_a?(Qt::FileSystemModel))
check('model rooted at the demo user path', fs_model.rootPath == Cosmos::USERPATH)
check('tree view rooted at the same directory',
      tree_view.rootIndex.valid? &&
      fs_model.filePath(tree_view.rootIndex) == Cosmos::USERPATH)
check('size/type/date columns hidden, name column shown',
      !tree_view.isColumnHidden(0) && [1, 2, 3].all? { |c| tree_view.isColumnHidden(c) })

cmd_tlm_index = fs_model.index(CMD_TLM_FILE)
cmd_tlm_dir_index = fs_model.index(File.dirname(CMD_TLM_FILE))
pump(20)
check('model resolves an index for the cmd_tlm file', cmd_tlm_index.valid?)
check("model reports the leaf name #{fs_model.fileName(cmd_tlm_index)}",
      fs_model.fileName(cmd_tlm_index) == 'inst_cmds.txt' &&
      !fs_model.isDir(cmd_tlm_index))
check('model reports the containing cmd_tlm directory as a directory',
      cmd_tlm_dir_index.valid? && fs_model.isDir(cmd_tlm_dir_index))
check("cmd_tlm directory populated #{fs_model.rowCount(cmd_tlm_dir_index)} rows",
      fs_model.rowCount(cmd_tlm_dir_index) > 0)

# ---------------------------------------------------------------------------
# Open a target's command definition through the same call the tree's
# clicked(QModelIndex) slot makes, deriving the path from the model rather
# than from the constant so the model -> path -> editor chain is what is
# under test.
# ---------------------------------------------------------------------------
tree_view.expand(cmd_tlm_dir_index)
tree_view.setCurrentIndex(cmd_tlm_index)
pump(10)
check('tree selection landed on the cmd_tlm file',
      tree_view.currentIndex.valid? &&
      fs_model.filePath(tree_view.currentIndex) == CMD_TLM_FILE)
check('containing directory is expanded', tree_view.isExpanded(cmd_tlm_dir_index))

ce.select_or_load_file(fs_model.filePath(tree_view.currentIndex))
pump(40, 0.05)

tab_book = ce.instance_variable_get(:@tab_book)
frame = tab_book.currentWidget
check('a ConfigEditorFrame is current', frame.is_a?(Cosmos::ConfigEditorFrame))
check('frame holds the opened filename', frame.filename == CMD_TLM_FILE)
# The pristine Untitled tab is reused rather than added to.
check("exactly one tab open (#{tab_book.count})", tab_book.count == 1)
check('tab labelled with the basename',
      tab_book.tabText(tab_book.currentIndex).strip == 'inst_cmds.txt')

# ---------------------------------------------------------------------------
# Content. The editor must hold the file verbatim, not a truncated or
# re-encoded copy -- inst_cmds.txt carries ERB tags and quoted strings.
# ---------------------------------------------------------------------------
disk_text = File.read(CMD_TLM_FILE).gsub("\r", '')
editor_text = frame.text
check("editor holds all #{disk_text.length} bytes of the file",
      editor_text == disk_text)
check('ERB tags survived the round trip',
      editor_text.include?('<%= @target_name %>'))
check('document block count matches the line count',
      frame.editor.document.blockCount == disk_text.lines.length + 1)
check('document starts unmodified', frame.modified == false)

# The type is derived from the path, and drives which meta hash the help pane
# uses.
check("file type detected as #{frame.file_type.inspect}",
      frame.file_type == 'Command and Telemetry Configuration')

# ---------------------------------------------------------------------------
# Syntax highlighting. RubySyntax is a QSyntaxHighlighter, which applies its
# colours through QTextLayout::setFormats rather than by editing the
# document, so the only way to prove it actually ran is to read the format
# ranges back off each block's layout.
# ---------------------------------------------------------------------------
syntax = frame.editor.instance_variable_get(:@syntax)
check('a RubySyntax highlighter is installed',
      syntax.is_a?(Cosmos::RubyEditor::RubySyntax))

highlighted = []
block = frame.editor.document.firstBlock
while block.isValid
  ranges = block.layout.formats
  highlighted << [block.blockNumber, block.text, ranges] unless ranges.empty?
  block = block.next
end
check("highlighter applied format ranges to #{highlighted.length} blocks",
      highlighted.length > 20)

# STYLES['string'] is getColor(127, 0, 127); the description on line 1 is a
# quoted string and must be painted with it.
string_color = Cosmos::RubyEditor::RubySyntax::STYLES['string'].foreground.color.name
check("string style resolves to #{string_color}", string_color == '#7f007f')
first_line = highlighted.find { |number, _text, _ranges| number == 0 }
check('line 1 carries exactly one format range', first_line[2].length == 1)
range = first_line[2][0]
check('the range covers the quoted description, painted with the string style',
      first_line[1][range.start, range.length] ==
        '"Starts a collect on the <%= @target_name %> target"' &&
      range.format.foreground.color.name == string_color)

comment_color = Cosmos::RubyEditor::RubySyntax::STYLES['comment'].foreground.color.name
commented = highlighted.find { |_number, text, _ranges| text.strip.start_with?('#') }
check("a comment line is painted with the comment style #{comment_color}",
      commented && commented[2].any? { |r| r.format.foreground.color.name == comment_color })

screenshot(ce, '/tmp/cosmos_config_editor_qt6.png')

# ---------------------------------------------------------------------------
# The meta-config driven help pane. Moving the cursor re-derives the keyword
# for the current line and rebuilds the pane out of the parsed yaml, so the
# pane's first label is the keyword the cursor is sitting on.
# ---------------------------------------------------------------------------
def help_labels(frame)
  widget = frame.instance_variable_get(:@gui_area).widget
  return [] unless widget && widget.layout
  (0...widget.layout.count).map do |index|
    item = widget.layout.itemAt(index)
    item.widget.respond_to?(:text) ? item.widget.text : nil
  end.compact
end

def move_cursor_to_line(frame, line_number)
  document = frame.editor.document
  cursor = frame.editor.textCursor
  cursor.setPosition(document.findBlockByNumber(line_number - 1).position)
  frame.editor.setTextCursor(cursor)
end

# Line 3 is "  PARAMETER    TYPE  64  16  UINT MIN MAX 0 ..."
move_cursor_to_line(frame, 3)
pump(15)
check("cursor moved to line 3 (#{frame.line_number})", frame.line_number == 3)
check("line_keyword picked PARAMETER off the line (#{frame.line_keyword})",
      frame.line_keyword == 'PARAMETER')
labels = help_labels(frame)
check('help pane headed by the PARAMETER keyword', labels[0] == 'PARAMETER')
check('help pane shows the yaml summary for PARAMETER',
      labels[1] == meta['Command and Telemetry Configuration']['COMMAND']['modifiers']['PARAMETER']['summary'])

screenshot(ce, '/tmp/cosmos_config_editor_help_qt6.png')

# Line 1 is the COMMAND declaration itself, a different keyword with its own
# meta entry, so the pane has to rebuild.
move_cursor_to_line(frame, 1)
pump(15)
check("cursor moved to line 1 (#{frame.line_number})", frame.line_number == 1)
labels = help_labels(frame)
check('help pane rebuilt for the COMMAND keyword', labels[0] == 'COMMAND')
check('help pane shows the yaml summary for COMMAND',
      labels[1] == meta['Command and Telemetry Configuration']['COMMAND']['summary'])

# ---------------------------------------------------------------------------
# A second file, from a different part of the tree, must open in its own tab
# and be typed independently.
# ---------------------------------------------------------------------------
tlm_viewer_index = fs_model.index(TLM_VIEWER_FILE)
pump(10)
check('model resolves the tool config file', tlm_viewer_index.valid?)
ce.select_or_load_file(fs_model.filePath(tlm_viewer_index))
pump(30, 0.05)

check("second file opened in its own tab (#{tab_book.count})", tab_book.count == 2)
second = tab_book.currentWidget
check('second tab holds the tool config', second.filename == TLM_VIEWER_FILE)
check("second tab typed independently #{second.file_type.inspect}",
      second.file_type == 'Telemetry Viewer Configuration')
check('second tab content matches disk',
      second.text == File.read(TLM_VIEWER_FILE).gsub("\r", ''))

# Re-selecting an already open file selects its tab instead of opening a
# duplicate.
ce.select_or_load_file(CMD_TLM_FILE)
pump(20)
check('re-selecting an open file did not duplicate the tab', tab_book.count == 2)
check('re-selecting an open file switched to its tab',
      tab_book.currentWidget.filename == CMD_TLM_FILE)

# Selecting a directory is a no-op -- the tree emits clicked for those too.
ce.select_or_load_file(File.dirname(CMD_TLM_FILE))
pump(10)
check('selecting a directory opened nothing', tab_book.count == 2)

# ---------------------------------------------------------------------------
# Editing marks the document modified, which is what drives the tab's dirty
# marker and the save prompt.
# ---------------------------------------------------------------------------
check('unmodified before editing', frame.modified == false)
frame.editor.appendPlainText('# appended by the qt6 regression test')
pump(10)
check('editing marked the document modified', frame.modified == true)
check('the appended line is in the text',
      frame.text.include?('# appended by the qt6 regression test'))
frame.modified = false # so file_close below does not prompt to save

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
ce.close
pump(20)
puts 'TEST_CONFIG_EDITOR OK'
