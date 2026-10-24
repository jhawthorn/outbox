# frozen_string_literal: true

module Outbox
  # Parses unified diff output from git into files, hunks and lines so the
  # UI can render the summary (paths, status, counts) and flag hidden
  # characters. The diff body itself is rendered in the browser from the raw
  # patch. Only what git diff -p produces is handled; this is not a general
  # patch parser.
  module Diff
    # Characters that render as nothing, or reorder what follows them, can
    # hide content from a reviewer. Zero-width, soft hyphen, BOM, bidi
    # controls, and C0 controls other than tab.
    INVISIBLE_RE = /[​-‏‪-‮⁠-⁤⁦-⁩﻿­\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/

    # The raw output of one git diff plus its short stat, with the parsed
    # form computed on demand. The stat may be given as a block, run only if
    # something asks: raw patches are served without it.
    class Patch
      attr_reader :text

      def initialize(text:, stat: nil, truncated: false, &stat_block)
        @stat = stat
        @stat_block = stat_block
        @text = text
        @truncated = truncated
      end

      def stat = @stat ||= @stat_block ? @stat_block.call : ""

      def truncated? = @truncated
      def empty? = text.empty?

      def files
        @files ||= Diff.parse(text)
      end
    end

    class File
      attr_accessor :old_path, :new_path, :status, :old_mode, :new_mode, :binary, :old_blob, :new_blob
      attr_reader :hunks, :hidden_lines

      def initialize(old_path, new_path)
        @old_path = old_path
        @new_path = new_path
        @status = :modified
        @binary = false
        @hunks = []
        @hidden_lines = []
      end

      def path = new_path || old_path
      def binary? = binary
      def renamed? = status == :renamed
      def line_count = hunks.sum(&:size)
      def additions = hunks.sum(&:additions)
      def deletions = hunks.sum(&:deletions)
    end

    # A hunk is counted as the patch is parsed and keeps only where its
    # lines are in the text: a patch can have millions of them and the page
    # only needs the counts. #lines reads them when something asks.
    class Hunk
      attr_reader :header, :additions, :deletions, :size

      def initialize(header, old_no, new_no, text, start)
        @header = header
        @old_no = old_no
        @new_no = new_no
        @text = text
        @start = start
        @additions = @deletions = @size = 0
      end

      # Called as the parser reads a line of the hunk, with the byte offset
      # just past the hunk once it is known (see #close).
      def count(kind)
        @size += 1
        @additions += 1 if kind == :add
        @deletions += 1 if kind == :del
      end

      def close(stop)
        @stop = stop
      end

      def lines
        @lines ||= begin
          old_no = @old_no
          new_no = @new_no
          @text.byteslice(@start, @stop - @start).each_line(chomp: true).map do |line|
            case line[0]
            when "+"
              new_no += 1
              Line.new(:add, nil, new_no - 1, line[1..])
            when "-"
              old_no += 1
              Line.new(:del, old_no - 1, nil, line[1..])
            when "\\"
              Line.new(:note, nil, nil, line[1..].strip)
            else
              old_no += 1
              new_no += 1
              Line.new(:ctx, old_no - 1, new_no - 1, line[1..] || "")
            end
          end
        end
      end
    end

    class Line
      attr_reader :kind, :old_no, :new_no, :text

      def initialize(kind, old_no, new_no, text)
        @kind = kind
        @old_no = old_no
        @new_no = new_no
        @text = text
      end

      def add?  = kind == :add
      def del?  = kind == :del
      def ctx?  = kind == :ctx
      def note? = kind == :note
      def hidden? = !note? && INVISIBLE_RE.match?(text)

      # How the line is labelled to a reader: by its number in the new file,
      # or in the old one for deletions.
      def label = del? ? "−#{old_no}" : (add? ? "+#{new_no}" : new_no.to_s)
    end

    HUNK_RE = /\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/

    # Bytes an invisible character can start with: the ASCII controls, and
    # the lead bytes of U+00AD (C2), U+200B..U+2069 (E2) and U+FEFF (EF).
    # Searching bytes for them is many times faster than INVISIBLE_RE, which
    # then only looks at the lines they are on.
    MAYBE_INVISIBLE_RE = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\xC2\xE2\xEF]/n

    # The text is walked by byte offsets and only header lines become
    # strings, so a patch of many megabytes takes a fraction of a second.
    def self.parse(text)
      files = []
      file = nil
      hunk = nil
      old_no = new_no = 0
      size = text.bytesize
      bytes = text.b
      invisible_at = bytes.byteindex(MAYBE_INVISIBLE_RE, 0)
      pos = 0

      while pos < size
        nl = text.byteindex("\n", pos) || size
        invisible = !invisible_at.nil? && invisible_at < nl
        invisible_at = nl + 1 < size ? bytes.byteindex(MAYBE_INVISIBLE_RE, nl + 1) : nil if invisible
        first = text.getbyte(pos)

        if first == 100 && text.byteslice(pos, 11) == "diff --git " # d
          hunk&.close(pos)
          file = File.new(*git_header_paths(text.byteslice(pos, nl - pos).chomp))
          files << file
          hunk = nil
        elsif file.nil?
          # before the first file
        elsif first == 64 && (m = HUNK_RE.match(line = text.byteslice(pos, nl - pos).chomp)) # @
          hunk&.close(pos)
          old_no = m[1].to_i
          new_no = m[2].to_i
          hunk = Hunk.new(line, old_no, new_no, text, nl + 1)
          file.hunks << hunk
        elsif hunk
          kind = case first
                 when 43 then :add  # +
                 when 45 then :del  # -
                 when 92 then :note # \
                 else :ctx
                 end
          hunk.count(kind)
          if invisible && kind != :note
            body = text.byteslice(pos, nl - pos).chomp[1..] || ""
            file.hidden_lines << Line.new(kind, kind == :add ? nil : old_no, kind == :del ? nil : new_no, body) if INVISIBLE_RE.match?(body)
          end
          old_no += 1 unless kind == :add || kind == :note
          new_no += 1 unless kind == :del || kind == :note
        else
          header(file, text.byteslice(pos, nl - pos).chomp)
        end
        pos = nl + 1
      end
      hunk&.close(size)

      files
    end

    def self.header(file, line)
      case line
      when /\Anew file mode (\d+)/     then file.status = :added;   file.new_mode = $1
      when /\Adeleted file mode (\d+)/ then file.status = :deleted; file.old_mode = $1
      when /\Aold mode (\d+)/          then file.old_mode = $1
      when /\Anew mode (\d+)/          then file.new_mode = $1
      when /\Arename from (.*)/        then file.status = :renamed; file.old_path = unquote($1)
      when /\Arename to (.*)/          then file.new_path = unquote($1)
      when /\Acopy from (.*)/          then file.status = :copied;  file.old_path = unquote($1)
      when /\Acopy to (.*)/            then file.new_path = unquote($1)
      when /\A--- (.*)/                then file.old_path = strip_prefix(unquote($1.chomp("\t")), "a/")
      when /\A\+\+\+ (.*)/             then file.new_path = strip_prefix(unquote($1.chomp("\t")), "b/")
      when /\Aindex ([0-9a-f]{40,64})\.\.([0-9a-f]{40,64})/
        file.old_blob = $1 unless $1.match?(/\A0+\z/)
        file.new_blob = $2 unless $2.match?(/\A0+\z/)
      when /\ABinary files /           then file.binary = true
      end
    end

    # "diff --git a/old b/new". Paths may contain spaces, so prefer the
    # exact split when both sides are the same path, else the first " b/".
    def self.git_header_paths(line)
      rest = line.delete_prefix("diff --git ")
      if rest.start_with?('"')
        a, b = rest.scan(/"(?:[^"\\]|\\.)*"|\S+/)
        return [strip_prefix(unquote(a), "a/"), strip_prefix(unquote(b), "b/")]
      end
      if rest.length.odd?
        mid = rest.length / 2
        a = rest[0...mid]
        b = rest[(mid + 1)..]
        if rest[mid] == " " && a.delete_prefix("a/") == b.delete_prefix("b/")
          return [a.delete_prefix("a/"), b.delete_prefix("b/")]
        end
      end
      a, b = rest.split(" b/", 2)
      [a.to_s.delete_prefix("a/"), b]
    end

    def self.strip_prefix(path, prefix)
      return nil if path.nil? || path == "/dev/null"
      path.delete_prefix(prefix)
    end

    ESCAPES = { "a" => "\a", "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t", "v" => "\v",
                '"' => '"', "\\" => "\\" }.freeze

    # Git quotes paths with unusual characters in C style.
    def self.unquote(path)
      return path unless path.start_with?('"') && path.end_with?('"') && path.length >= 2
      inner = path[1..-2]
      bytes = inner.gsub(/\\(?:([abfnrtv"\\])|([0-7]{3}))/) do
        $1 ? ESCAPES[$1] : [$2.to_i(8)].pack("C")
      end
      bytes.b.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
