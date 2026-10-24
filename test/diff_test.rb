# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class DiffTest < Minitest::Test
  Diff = Outbox::Diff

  # git's listing for LISTING_ARGS, from entries written as the raw line and
  # the numstat line, with the paths in each.
  def listing(*entries, stat: " 1 file changed, 1 insertion(+)\n")
    raw = entries.map { |meta, paths, _| ":#{meta}\0#{paths.join("\0")}\0" }.join
    numstat = entries.map do |_, paths, counts|
      paths.size == 1 ? "#{counts}\t#{paths[0]}\0" : "#{counts}\t\0#{paths.join("\0")}\0"
    end.join
    raw + numstat + stat
  end

  A = "a" * 40
  B = "b" * 40
  ZERO = "0" * 40

  def test_modified_file
    files, stat = Diff.parse_listing(listing(["100644 100644 #{A} #{B} M", ["lib/thing.rb"], "3\t2"], stat: " 1 file changed, 3 insertions(+), 2 deletions(-)\n"))
    f = files.first
    assert_equal 1, files.size
    assert_equal "1 file changed, 3 insertions(+), 2 deletions(-)", stat
    assert_equal "lib/thing.rb", f.path
    assert_equal "lib/thing.rb", f.old_path
    assert_equal :modified, f.status
    assert_equal [A, B], [f.old_blob, f.new_blob]
    assert_equal [3, 2], [f.additions, f.deletions]
    refute f.binary?
    refute f.mode_change?
    refute f.empty?
  end

  def test_added_and_deleted_files_have_one_side
    added, deleted = Diff.parse_listing(listing(
      ["000000 100644 #{ZERO} #{B} A", ["new.txt"], "2\t0"],
      ["100755 000000 #{A} #{ZERO} D", ["gone.txt"], "0\t1"],
    )).first
    assert_equal :added, added.status
    assert_equal "new.txt", added.path
    assert_nil added.old_path
    assert_nil added.old_mode
    assert_nil added.old_blob
    assert_equal ["100644", B], [added.new_mode, added.new_blob]
    assert_equal 2, added.additions

    assert_equal :deleted, deleted.status
    assert_equal "gone.txt", deleted.path
    assert_nil deleted.new_path
    assert_equal ["100755", A], [deleted.old_mode, deleted.old_blob]
    assert_nil deleted.new_blob
    assert_equal 1, deleted.deletions
  end

  def test_rename_with_and_without_changes
    pure, changed = Diff.parse_listing(listing(
      ["100644 100644 #{A} #{A} R100", ["old name.rb", "new name.rb"], "0\t0"],
      ["100644 100644 #{A} #{B} R090", ["a.rb", "b.rb"], "1\t1"],
    )).first
    assert_equal :renamed, pure.status
    assert pure.renamed?
    assert_equal "old name.rb", pure.old_path
    assert_equal "new name.rb", pure.new_path
    assert_equal "new name.rb", pure.path
    assert pure.empty?

    assert_equal "a.rb", changed.old_path
    assert_equal "b.rb", changed.path
    assert_equal 1, changed.additions
    refute changed.empty?
  end

  def test_copies
    copy = Diff.parse_listing(listing(["100644 100644 #{A} #{A} C100", ["a.rb", "b.rb"], "0\t0"])).first.first
    assert_equal :copied, copy.status
    assert_equal ["a.rb", "b.rb"], [copy.old_path, copy.new_path]
  end

  def test_binary_and_mode_change
    binary, mode = Diff.parse_listing(listing(
      ["100644 100644 #{A} #{B} M", ["logo.png"], "-\t-"],
      ["100644 100755 #{A} #{A} M", ["run.sh"], "0\t0"],
    )).first
    assert binary.binary?
    refute binary.empty?, "a binary file is not an empty change"
    assert_equal [0, 0], [binary.additions, binary.deletions]

    assert_equal :modified, mode.status
    assert mode.mode_change?
    assert_equal ["100644", "100755"], [mode.old_mode, mode.new_mode]
    assert mode.empty?
  end

  def test_paths_with_tabs_newlines_and_unicode_are_taken_as_they_are
    files = Diff.parse_listing(listing(["100644 100644 #{A} #{B} M", ["café \"x\"\ty\n.txt"], "1\t1"])).first
    assert_equal "café \"x\"\ty\n.txt", files.first.path
  end

  def test_empty_listing
    assert_equal [[], ""], Diff.parse_listing("")
  end

  def test_patch_has_its_files_and_stat_on_demand
    calls = 0
    patch = Diff::Patch.new(text: "diff --git a/x b/x\n") do
      calls += 1
      listing(["100644 100644 #{A} #{B} M", ["x"], "1\t0"])
    end
    assert_equal 0, calls
    refute patch.empty?
    refute patch.truncated?
    assert_equal ["x"], patch.files.map(&:path)
    assert_equal "1 file changed, 1 insertion(+)", patch.stat
    assert_same patch.files, patch.files
    assert_equal 1, calls
    assert Diff::Patch.new(text: "").empty?
    assert_empty Diff::Patch.new(text: "").files
    assert_equal "", Diff::Patch.new(text: "").stat
  end

  def test_hidden_characters_are_flagged_per_line
    text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,4 +1,4 @@\n" \
           " plain\n-safe\u200bgone\n+new\u202eline\n+fine\n ctx\u200b\n\\ No newline at end of file\n"
    f = hidden(text, "f")
    assert_equal ["−2", "+2", "4"], f.hidden_lines
  end

  def test_hidden_characters_go_to_their_own_files
    text = "diff --git a/a b/a\n@@ -1 +1 @@\n-a\n+b\n" \
           "diff --git a/b b/b\n@@ -1 +1 @@\n-a\n+b\u200b\n" \
           "diff --git a/c b/c\n@@ -5 +5,2 @@\n-a\n+b\n+\u0001\n"
    a, b, c = hidden(text, "a", "b", "c")
    assert_empty a.hidden_lines
    assert_equal ["+1"], b.hidden_lines
    assert_equal ["+6"], c.hidden_lines
  end

  def test_hidden_characters_are_found_in_files_with_odd_paths
    text = "diff --git \"a/sp\\303\\251 x.txt\" \"b/sp\\303\\251 x.txt\"\n@@ -1 +1 @@\n-a\n+b\u200b\n" \
           "diff --git a/with space.txt b/with space.txt\n@@ -1 +1 @@\n-a\n+b\u200b\n"
    quoted, spaced = hidden(text, "spé x.txt", "with space.txt")
    assert_equal ["+1"], quoted.hidden_lines
    assert_equal ["+1"], spaced.hidden_lines
  end

  def test_characters_in_a_path_or_header_are_not_line_content
    text = "diff --git a/z\u200bz b/z\u200bz\nindex 1..2 100644\n--- a/z\u200bz\n+++ b/z\u200bz\n@@ -1 +1 @@\n-a\n+b\n"
    assert_empty hidden(text, "z\u200bz").hidden_lines
  end

  def test_visible_non_ascii_is_not_flagged
    text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-café “quoted” — ©\n+naïve ’text’ ®\n"
    assert_empty hidden(text, "f").hidden_lines
  end

  def test_the_byte_prefilter_passes_every_invisible_character
    (0..0xFFFF).reject { |c| (0xD800..0xDFFF).cover?(c) }.each do |c|
      char = [c].pack("U")
      next unless Diff::INVISIBLE_RE.match?(char)
      assert Diff::MAYBE_INVISIBLE_RE.match?(char.b), "U+#{c.to_s(16)} would be skipped"
    end
  end

  def test_content_lines_that_look_like_headers_are_still_numbered
    text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -3,2 +3,3 @@\n --- not a header\n+++ not a header either\n+diff --git nope\u200b\n"
    assert_equal ["+5"], hidden(text, "f").hidden_lines
  end

  def test_against_real_git
    Dir.mktmpdir do |dir|
      git = lambda do |*args|
        out, err, status = Open3.capture3({ "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null" }, "git", *args, chdir: dir)
        assert status.success?, err
        out
      end
      write = ->(name, content) { File.binwrite(File.join(dir, name), content) }
      git.("init", "-q", "-b", "main")
      git.("config", "user.email", "a@b")
      git.("config", "user.name", "a")
      body = (1..20).map { |i| "line #{i}\n" }.join
      write.("old name.rb", body)
      write.("run.sh", "echo\n")
      write.("logo.bin", "\0\1")
      write.("gone.txt", "x\n")
      write.("touch.txt", "a\nb\n")
      git.("add", ".")
      git.("commit", "-qm", "one")
      git.("mv", "old name.rb", "new name.rb")
      write.("new name.rb", body.sub("line 5\n", "line five\n"))
      File.chmod(0o755, File.join(dir, "run.sh"))
      write.("logo.bin", "\0\2")
      File.delete(File.join(dir, "gone.txt"))
      write.("café.txt", "new\n")
      write.("touch.txt", "a\nb\u200b\nc\n")
      git.("add", "-A")
      git.("commit", "-qm", "two")

      patch = Diff::Patch.new(text: git.("diff", "-M", "--full-index", "HEAD~1", "HEAD"),
                              listing: git.("diff", *Diff::LISTING_ARGS, "HEAD~1", "HEAD"))
      by_path = patch.files.to_h { |f| [f.path, f] }
      assert_equal ["café.txt", "gone.txt", "logo.bin", "new name.rb", "run.sh", "touch.txt"], by_path.keys.sort
      assert_equal "old name.rb", by_path["new name.rb"].old_path
      assert_equal :renamed, by_path["new name.rb"].status
      assert_equal [1, 1], [by_path["new name.rb"].additions, by_path["new name.rb"].deletions]
      assert by_path["logo.bin"].binary?
      assert by_path["run.sh"].mode_change?
      assert_equal :deleted, by_path["gone.txt"].status
      assert_equal :added, by_path["café.txt"].status
      assert_equal 40, by_path["café.txt"].new_blob.size
      assert_equal ["+2"], by_path["touch.txt"].hidden_lines
      assert_match(/6 files changed/, patch.stat)
      assert_equal ["caf\u00e9.txt", "gone.txt", "logo.bin", "new name.rb", "run.sh", "touch.txt"],
                   patch.files.map(&:path), "in the order the patch has them"
    end
  end

  private

  # Files named by path, as a listing would give them, with the patch's
  # hidden characters found.
  def hidden(text, *paths)
    entries = paths.map { |p| ["100644 100644 #{A} #{B} M", [p], "1\t1"] }
    files = Diff::Patch.new(text: text, listing: listing(*entries)).files
    paths.size == 1 ? files.first : files
  end
end
