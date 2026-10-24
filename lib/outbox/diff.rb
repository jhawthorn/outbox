# frozen_string_literal: true

module Outbox
  # What the UI needs to know about a diff besides its text: the files, with
  # status, modes, blob ids and line counts, and which lines hide characters
  # a reviewer cannot see. The files come from git's own listing (git diff
  # --raw --numstat), which costs the same however big the patch is; only
  # the hidden characters need the text. The diff body itself is rendered in
  # the browser from the raw patch.
  module Diff
    # Characters that render as nothing, or reorder what follows them, can
    # hide content from a reviewer. Zero-width, soft hyphen, BOM, bidi
    # controls, and C0 controls other than tab.
    INVISIBLE_RE = /[​-‏‪-‮⁠-⁤⁦-⁩﻿­\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/

    # What git prints for a diff when asked for these, NUL separated:
    # one ":old-mode new-mode old-blob new-blob status" entry per file with
    # its path (two for a rename or copy), then one "added deleted" entry
    # per file with the same paths, then the short stat.
    LISTING_ARGS = %w[--raw --numstat --shortstat -z --no-abbrev -M].freeze

    STATUSES = { "A" => :added, "D" => :deleted, "R" => :renamed, "C" => :copied }.freeze

    # The raw output of one git diff, with what is known about it computed
    # on demand: raw patches are served without it. The listing is git's
    # output for LISTING_ARGS, given as a string or a block.
    class Patch
      attr_reader :text

      def initialize(text:, listing: nil, truncated: false, &listing_block)
        @text = text
        @listing = listing
        @listing_block = listing_block
        @truncated = truncated
      end

      def truncated? = @truncated
      def empty? = text.empty?

      def stat = (parsed.last)

      def files
        @files ||= parsed.first.tap { |files| Diff.find_hidden_lines(text, files) }
      end

      private

      def parsed
        @parsed ||= Diff.parse_listing(@listing || @listing_block&.call || "")
      end
    end

    class File
      attr_reader :old_path, :new_path, :status, :old_mode, :new_mode, :old_blob, :new_blob,
                  :additions, :deletions, :hidden_lines

      def initialize(old_path:, new_path:, status:, old_mode:, new_mode:, old_blob:, new_blob:, additions:, deletions:, binary:)
        @old_path = old_path
        @new_path = new_path
        @status = status
        @old_mode = old_mode
        @new_mode = new_mode
        @old_blob = old_blob
        @new_blob = new_blob
        @additions = additions
        @deletions = deletions
        @binary = binary
        @hidden_lines = []
      end

      def path = new_path || old_path
      def binary? = @binary
      def renamed? = status == :renamed

      # Only the mode changed, or it did along with the content.
      def mode_change? = status == :modified && !old_mode.nil? && !new_mode.nil? && old_mode != new_mode

      # No lines changed, and not because git cannot show them.
      def empty? = !binary? && additions + deletions == 0
    end

    # The files and the short stat from git's listing (see LISTING_ARGS).
    def self.parse_listing(out)
      parts = out.split("\0", -1)
      entries = []
      until parts.empty? || !parts.first.start_with?(":")
        meta = parts.shift.split(" ")
        letter = meta[4].to_s[0]
        paths = parts.shift(%w[R C].include?(letter) ? 2 : 1)
        entries << [meta, letter, paths]
      end
      files = entries.map do |meta, letter, paths|
        counts = parts.shift.to_s
        parts.shift(2) if counts.end_with?("\t") # a rename's paths follow, as they do above
        added, deleted = counts.split("\t", 3).first(2)
        File.new(old_path: letter == "A" ? nil : paths.first, new_path: letter == "D" ? nil : paths.last,
                 status: STATUSES.fetch(letter, :modified),
                 old_mode: zero_to_nil(meta[0].delete_prefix(":"), /\A0+\z/), new_mode: zero_to_nil(meta[1], /\A0+\z/),
                 old_blob: zero_to_nil(meta[2], /\A0+\z/), new_blob: zero_to_nil(meta[3], /\A0+\z/),
                 additions: added.to_i, deletions: deleted.to_i, binary: added == "-")
      end
      [files, parts.join("\0").strip]
    end

    def self.zero_to_nil(value, zeros) = value.nil? || value.match?(zeros) ? nil : value

    HUNK_RE = /\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/

    # Bytes an invisible character can start with: the ASCII controls, and
    # the lead bytes of U+00AD (C2), U+200B..U+2069 (E2) and U+FEFF (EF).
    # Searching bytes for them is many times faster than INVISIBLE_RE, which
    # then only looks at the lines they are on.
    MAYBE_INVISIBLE_RE = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\xC2\xE2\xEF]/n

    # Fills in each file's hidden_lines with the labels of the lines of
    # the patch that hold characters a reader cannot see (INVISIBLE_RE):
    # "+12" for line 12 of the new side, "−3" for line 3 of the old one,
    # the new line number for an unchanged line. Most patches have none,
    # which one search over the bytes shows. Otherwise only the files that
    # may have some are walked, and only as far as their last candidate.
    def self.find_hidden_lines(text, files)
      bytes = text.b
      at = bytes.byteindex(MAYBE_INVISIBLE_RE, 0)
      return if at.nil?
      by_path = files.to_h { |f| [f.path, f] }
      starts = []
      starts << 0 if text.start_with?("diff --git ")
      pos = 0
      while (i = text.byteindex("\ndiff --git ", pos))
        starts << i + 1
        pos = i + 1
      end
      while at
        n = starts.bsearch_index { |start| start > at }
        n = n ? n - 1 : starts.size - 1
        break if n.negative?
        stop = starts[n + 1] || text.bytesize
        header = text.byteslice(starts[n], text.byteindex("\n", starts[n]) - starts[n])
        old_path, new_path = git_header_paths(header)
        file = by_path[new_path] || by_path[old_path]
        at = walk_section(text, bytes, starts[n], stop, at, file&.hidden_lines)
        at = bytes.byteindex(MAYBE_INVISIBLE_RE, stop) if at && at < stop
      end
    end

    # One file's part of the patch, from its "diff --git" line, up to the
    # last candidate in it. Returns where the next candidate is, if it is
    # in a later part.
    def self.walk_section(text, bytes, from, stop, at, labels)
      size = text.bytesize
      hunk = false
      old_no = new_no = 0
      pos = from
      while pos < stop && at && at < stop
        nl = text.byteindex("\n", pos) || size
        first = text.getbyte(pos)
        if first == 64 && (m = HUNK_RE.match(text.byteslice(pos, nl - pos)))
          hunk = true
          old_no = m[1].to_i
          new_no = m[2].to_i
        elsif hunk
          kind = case first
                 when 43 then :add  # +
                 when 45 then :del  # -
                 when 92 then :note # \
                 else :ctx
                 end
          if at < nl
            body = text.byteslice(pos, nl - pos).chomp[1..] || ""
            if kind != :note && INVISIBLE_RE.match?(body)
              labels << (kind == :add ? "+#{new_no}" : kind == :del ? "\u2212#{old_no}" : new_no.to_s) if labels
            end
          end
          old_no += 1 unless kind == :add || kind == :note
          new_no += 1 unless kind == :del || kind == :note
        end
        if at < nl
          at = nl + 1 < size ? bytes.byteindex(MAYBE_INVISIBLE_RE, nl + 1) : nil
        end
        pos = nl + 1
      end
      at
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
