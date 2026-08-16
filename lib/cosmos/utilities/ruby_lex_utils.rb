# encoding: ascii-8bit

# Copyright 2014 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'ripper'

# Analyzes Ruby code lexically using Ripper. Formerly built on irb's
# RubyLex/RubyToken API which was removed from modern Ruby.
class RubyLexUtils
  # Regular expression to detect blank lines
  BLANK_LINE_REGEX  = /^\s*$/
  # Regular expression to detect lines containing only 'else'
  LONELY_ELSE_REGEX = /^\s*else\s*$/

  # Ruby keywords (both statement and modifier forms lex to the same value)
  KEYWORDS = %w(class module def undef begin rescue ensure end if unless
                then elsif else case when while until for break next redo
                retry in do return alias BEGIN END).freeze

  # Keywords which begin a block: do, begin ('{' is handled via tokens)
  BLOCK_BEGINNING_KEYWORDS = %w(do begin).freeze

  # Keywords which open an indent level and are closed by 'end'.
  # if/unless/while/until only count in statement (non-modifier) form.
  INDENT_KEYWORDS = %w(class module def begin case for do if unless while until).freeze

  # Token types which open a string-like literal closed by an end token
  STRING_OPEN_TOKENS = %i(on_tstring_beg on_heredoc_beg on_regexp_beg
                          on_words_beg on_qwords_beg on_symbols_beg
                          on_qsymbols_beg on_backtick).freeze
  # Token types which close a string-like literal
  STRING_CLOSE_TOKENS = %i(on_tstring_end on_heredoc_end on_regexp_end).freeze

  # Token types which carry no meaning for continuation decisions
  IGNORED_TOKENS = %i(on_sp on_nl on_ignored_nl on_comment
                      on_embdoc_beg on_embdoc on_embdoc_end).freeze

  # @param text [String]
  # @return [Boolean] Whether the text contains the 'begin' keyword
  def contains_begin?(text)
    Ripper.lex(text).to_a.any? { |_pos, type, token, _state| type == :on_kw and token == 'begin' }
  end

  # @param text [String]
  # @return [Boolean] Whether the text contains a Ruby keyword or a block '{'
  def contains_keyword?(text)
    Ripper.lex(text).to_a.any? do |_pos, type, token, state|
      (type == :on_kw and KEYWORDS.include?(token)) or
        (type == :on_lbrace and block_brace?(state))
    end
  end

  # @param text [String]
  # @return [Boolean] Whether the text contains a keyword which starts a block.
  #   i.e. 'do', '{', or 'begin'
  def contains_block_beginning?(text)
    Ripper.lex(text).to_a.any? do |_pos, type, token, state|
      (type == :on_kw and BLOCK_BEGINNING_KEYWORDS.include?(token)) or
        (type == :on_lbrace and block_brace?(state))
    end
  end

  # @param text [String]
  # @param progress_dialog [Cosmos::ProgressDialog] If this is set, the overall
  #   progress will be set as the processing progresses
  # @return [String] The text with all comments removed
  def remove_comments(text, progress_dialog = nil)
    comments_removed = text.clone
    # Byte offset of the start of each line
    line_offsets = [0]
    text.each_line { |line| line_offsets << line_offsets[-1] + line.length }

    delete_ranges = []
    token_count = 0
    progress = 0.0
    Ripper.lex(text).to_a.each do |(line, col), type, token, _state|
      token_count += 1
      if type == :on_comment
        offset = line_offsets[line - 1] + col
        # Preserve the newline which terminates the comment
        comment = token.chomp
        delete_ranges << (offset..(offset + comment.length - 1)) unless comment.empty?
      end
      if progress_dialog and token_count % 10000 == 0
        progress += 0.01
        progress = 0.0 if progress >= 0.99
        progress_dialog.set_overall_progress(progress)
      end
    end

    delete_count = 0
    delete_ranges.reverse_each do |range|
      delete_count += 1
      comments_removed[range] = ''
      if progress_dialog and delete_count % 10000 == 0
        progress += 0.01
        progress = 0.0 if progress >= 0.99
        progress_dialog.set_overall_progress(progress)
      end
    end

    return comments_removed
  end

  # Yields each lexed segment and if the segment is instrumentable
  #
  # @param text [String]
  # @yieldparam line [String] The entire line
  # @yieldparam instrumentable [Boolean] Whether the line is instrumentable
  # @yieldparam inside_begin [Integer] The level of indentation
  # @yieldparam line_no [Integer] The current line number
  def each_lexed_segment(text)
    inside_begin = nil
    indent = 0
    line_no = 1

    each_segment(text) do |lexed|
      next_line_no = line_no + lexed.count("\n")
      indent += indent_delta(lexed)

      if contains_begin?(lexed)
        inside_begin = indent - 1
      end

      if indent == inside_begin
        inside_begin = nil
      end

      loop do # loop to allow restarting for nested conditions

        # Yield blank lines and lonely else lines before the actual line
        while (index = lexed.index("\n"))
          line = lexed[0..index]
          if line =~ BLANK_LINE_REGEX
            yield line, true, inside_begin, line_no
            line_no += 1
            lexed = lexed[(index + 1)..-1]
          elsif line =~ LONELY_ELSE_REGEX
            yield line, false, inside_begin, line_no
            line_no += 1
            lexed = lexed[(index + 1)..-1]
          else
            break
          end
        end

        if contains_keyword?(lexed)
          if contains_block_beginning?(lexed)
            section = ''
            lexed.each_line do |lexed_part|
              section << lexed_part
              if contains_block_beginning?(section)
                yield section, false, inside_begin, line_no
                break
              end
              line_no += 1
            end
            line_no += 1
            remainder = lexed[(section.length)..-1]
            lexed = remainder
            next unless remainder.empty?
          else
            yield lexed, false, inside_begin, line_no
          end
        elsif !lexed.empty?
          num_left_brackets  = lexed.count('{')
          num_right_brackets = lexed.count('}')
          if num_left_brackets != num_right_brackets
            # Don't instrument lines with unequal numbers of { and } brackets
            yield lexed, false, inside_begin, line_no
          else
            yield lexed, true, inside_begin, line_no
          end
        end
        break
      end # loop do
      line_no = next_line_no
    end # each_segment
  end # def each_lexed_segment

  private

  # A '{' token which starts a block rather than a hash literal.
  # Ripper marks hash-literal braces with the LABEL state bit.
  def block_brace?(state)
    !state.allbits?(Ripper::EXPR_LABEL)
  end

  # Yields consecutive lexically-complete segments of text. A segment ends at
  # a newline unless the text so far has unbalanced brackets, an unterminated
  # string/heredoc, or ends with a continuation token (operator, comma, '.',
  # 'and'/'or'/'not', or a trailing backslash).
  def each_segment(text)
    buffer = +''
    text.each_line do |line|
      buffer << line
      if segment_complete?(buffer)
        yield buffer
        buffer = +''
      end
    end
    yield buffer unless buffer.empty?
  end

  def segment_complete?(buffer)
    return false if buffer.end_with?("\\\n")
    tokens = Ripper.lex(buffer).to_a
    parens = brackets = braces = strings = embdocs = 0
    last_type = nil
    last_token = nil
    tokens.each do |_pos, type, token, _state|
      case type
      when :on_lparen               then parens += 1
      when :on_rparen               then parens -= 1
      when :on_lbracket             then brackets += 1
      when :on_rbracket             then brackets -= 1
      when :on_lbrace, :on_tlambeg,
           :on_embexpr_beg          then braces += 1
      when :on_rbrace, :on_embexpr_end then braces -= 1
      when *STRING_OPEN_TOKENS      then strings += 1
      when *STRING_CLOSE_TOKENS     then strings -= 1
      when :on_embdoc_beg           then embdocs += 1
      when :on_embdoc_end           then embdocs -= 1
      end
      unless IGNORED_TOKENS.include?(type) or type == :on_tstring_content or
             type == :on_words_sep or type == :on_heredoc_end
        last_type = type
        last_token = token
      end
    end
    return false if parens > 0 or brackets > 0 or braces > 0 or strings > 0 or embdocs > 0
    case last_type
    when :on_comma, :on_period
      return false
    when :on_op
      # '|' most commonly ends block params: 'do |x|'
      return false unless last_token == '|'
    when :on_kw
      return false if %w(and or not).include?(last_token)
    end
    return true
  end

  # Net indent level change of a segment: keywords which open an
  # indent level minus 'end' keywords. Modifier if/unless/while/until
  # (marked with the LABEL state bit) do not open an indent level.
  def indent_delta(text)
    delta = 0
    Ripper.lex(text).to_a.each do |_pos, type, token, state|
      next unless type == :on_kw
      if INDENT_KEYWORDS.include?(token)
        delta += 1 unless state.allbits?(Ripper::EXPR_LABEL)
      elsif token == 'end'
        delta -= 1
      end
    end
    delta
  end
end
