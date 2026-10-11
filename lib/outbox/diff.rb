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
    # form computed on demand.
    class Patch
      attr_reader :stat, :text

      def initialize(stat:, text:, truncated: false)
        @stat = stat
        @text = text
        @truncated = truncated
      end

      def truncated? = @truncated
      def empty? = text.empty?

      def files
        @files ||= Diff.parse(text)
      end
    end

    class File
      attr_accessor :old_path, :new_path, :status, :old_mode, :new_mode, :binary
      attr_reader :hunks

      def initialize(old_path, new_path)
        @old_path = old_path
        @new_path = new_path
        @status = :modified
        @binary = false
        @hunks = []
      end

      def path = new_path || old_path
      def binary? = binary
      def renamed? = status == :renamed
      def line_count = hunks.sum { |h| h.lines.size }
      def additions = hunks.sum(&:additions)
      def deletions = hunks.sum(&:deletions)

      # Lines whose text contains characters a reviewer cannot see.
      def hidden_lines
        @hidden_lines ||= hunks.flat_map(&:lines).select(&:hidden?)
      end
    end

    class Hunk
      attr_reader :header, :lines

      def initialize(header)
        @header = header
        @lines = []
      end

      def additions = lines.count(&:add?)
      def deletions = lines.count(&:del?)
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

    def self.parse(text)
      files = []
      file = nil
      hunk = nil
      old_no = new_no = 0

      text.each_line(chomp: true) do |line|
        if line.start_with?("diff --git ")
          file = File.new(*git_header_paths(line))
          files << file
          hunk = nil
          next
        end
        next if file.nil?

        if (m = HUNK_RE.match(line))
          hunk = Hunk.new(line)
          file.hunks << hunk
          old_no = m[1].to_i
          new_no = m[2].to_i
        elsif hunk
          case line[0]
          when "+"
            hunk.lines << Line.new(:add, nil, new_no, line[1..])
            new_no += 1
          when "-"
            hunk.lines << Line.new(:del, old_no, nil, line[1..])
            old_no += 1
          when "\\"
            hunk.lines << Line.new(:note, nil, nil, line[1..].strip)
          else
            hunk.lines << Line.new(:ctx, old_no, new_no, line[1..] || "")
            old_no += 1
            new_no += 1
          end
        else
          header(file, line)
        end
      end

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
      when /\A--- (.*)/                then file.old_path = strip_prefix(unquote($1), "a/")
      when /\A\+\+\+ (.*)/             then file.new_path = strip_prefix(unquote($1), "b/")
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
