# frozen_string_literal: true

require_relative "test_helper"

class DiffTest < Minitest::Test
  Diff = Outbox::Diff

  MODIFIED = <<~DIFF
    diff --git a/lib/thing.rb b/lib/thing.rb
    index 1111111..2222222 100644
    --- a/lib/thing.rb
    +++ b/lib/thing.rb
    @@ -1,4 +1,5 @@
     class Thing
    -  def old
    +  def new
    +    42
       end
     end
    @@ -20,3 +21,3 @@ class Thing
       # tail
    -  A = 1
    +  A = 2
     end
  DIFF

  def test_modified_file_with_two_hunks
    files = Diff.parse(MODIFIED)
    assert_equal 1, files.size
    f = files.first
    assert_equal "lib/thing.rb", f.path
    assert_equal "lib/thing.rb", f.old_path
    assert_equal :modified, f.status
    refute f.binary?
    assert_equal 2, f.hunks.size
    assert_equal 3, f.additions
    assert_equal 2, f.deletions
    assert_equal "@@ -1,4 +1,5 @@", f.hunks[0].header
    assert_equal "@@ -20,3 +21,3 @@ class Thing", f.hunks[1].header
  end

  def test_full_index_line_gives_blob_ids_except_for_added_and_deleted_sides
    a, b = "a" * 40, "b" * 40
    files = Diff.parse("diff --git a/x b/x\nindex #{a}..#{b} 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-1\n+2\n" \
                       "diff --git a/y b/y\nnew file mode 100644\nindex #{"0" * 40}..#{b}\n--- /dev/null\n+++ b/y\n@@ -0,0 +1 @@\n+2\n")
    assert_equal [a, b], [files[0].old_blob, files[0].new_blob]
    assert_nil files[1].old_blob
    assert_equal b, files[1].new_blob
  end

  def test_line_numbers_track_old_and_new_sides
    hunk = Diff.parse(MODIFIED).first.hunks.first
    rows = hunk.lines.map { |l| [l.kind, l.old_no, l.new_no, l.text] }
    assert_equal [
      [:ctx, 1, 1, "class Thing"],
      [:del, 2, nil, "  def old"],
      [:add, nil, 2, "  def new"],
      [:add, nil, 3, "    42"],
      [:ctx, 3, 4, "  end"],
      [:ctx, 4, 5, "end"],
    ], rows

    second = Diff.parse(MODIFIED).first.hunks[1]
    assert_equal [20, 21], [second.lines[0].old_no, second.lines[0].new_no]
  end

  def test_added_and_deleted_files
    text = <<~DIFF
      diff --git a/new.txt b/new.txt
      new file mode 100644
      index 0000000..3333333
      --- /dev/null
      +++ b/new.txt
      @@ -0,0 +1,2 @@
      +one
      +two
      diff --git a/gone.txt b/gone.txt
      deleted file mode 100755
      index 4444444..0000000
      --- a/gone.txt
      +++ /dev/null
      @@ -1 +0,0 @@
      -bye
    DIFF
    added, deleted = Diff.parse(text)

    assert_equal :added, added.status
    assert_equal "new.txt", added.path
    assert_nil added.old_path
    assert_equal "100644", added.new_mode
    assert_equal [nil, 1], [added.hunks[0].lines[0].old_no, added.hunks[0].lines[0].new_no]
    assert_equal 2, added.additions

    assert_equal :deleted, deleted.status
    assert_equal "gone.txt", deleted.path
    assert_nil deleted.new_path
    assert_equal "100755", deleted.old_mode
    assert_equal 1, deleted.deletions
  end

  def test_rename_with_and_without_changes
    text = <<~DIFF
      diff --git a/old name.rb b/new name.rb
      similarity index 100%
      rename from old name.rb
      rename to new name.rb
      diff --git a/a.rb b/b.rb
      similarity index 90%
      rename from a.rb
      rename to b.rb
      index 1..2 100644
      --- a/a.rb
      +++ b/b.rb
      @@ -1 +1 @@
      -x
      +y
    DIFF
    pure, changed = Diff.parse(text)
    assert_equal :renamed, pure.status
    assert_equal "old name.rb", pure.old_path
    assert_equal "new name.rb", pure.new_path
    assert_empty pure.hunks

    assert_equal :renamed, changed.status
    assert_equal "a.rb", changed.old_path
    assert_equal "b.rb", changed.path
    assert_equal 1, changed.additions
  end

  def test_binary_and_mode_change
    text = <<~DIFF
      diff --git a/logo.png b/logo.png
      index 1..2 100644
      Binary files a/logo.png and b/logo.png differ
      diff --git a/run.sh b/run.sh
      old mode 100644
      new mode 100755
    DIFF
    binary, mode = Diff.parse(text)
    assert binary.binary?
    assert_equal "logo.png", binary.path
    assert_empty binary.hunks

    assert_equal :modified, mode.status
    assert_equal "100644", mode.old_mode
    assert_equal "100755", mode.new_mode
    assert_empty mode.hunks
  end

  def test_quoted_paths_are_unquoted
    text = <<~'DIFF'
      diff --git "a/caf\303\251 \"x\".txt" "b/caf\303\251 \"x\".txt"
      index 1..2 100644
      --- "a/caf\303\251 \"x\".txt"
      +++ "b/caf\303\251 \"x\".txt"
      @@ -1 +1 @@
      -a
      +b
    DIFF
    f = Diff.parse(text).first
    assert_equal 'café "x".txt', f.path
    assert_equal 'café "x".txt', f.old_path
  end

  def test_no_newline_marker_is_a_note_not_a_line
    text = <<~DIFF
      diff --git a/f b/f
      index 1..2 100644
      --- a/f
      +++ b/f
      @@ -1 +1 @@
      -old
      \\ No newline at end of file
      +new
      \\ No newline at end of file
    DIFF
    lines = Diff.parse(text).first.hunks.first.lines
    assert_equal %i[del note add note], lines.map(&:kind)
    assert_equal "No newline at end of file", lines[1].text
    assert_equal [1, 1], [lines[0].old_no, lines[2].new_no]
  end

  def test_content_lines_that_look_like_headers_stay_content
    text = <<~DIFF
      diff --git a/f b/f
      index 1..2 100644
      --- a/f
      +++ b/f
      @@ -1,2 +1,3 @@
       --- not a header
      +++ not a header either
      +diff --git nope
    DIFF
    f = Diff.parse(text).first
    assert_equal 1, Diff.parse(text).size
    assert_equal ["--- not a header", "++ not a header either", "diff --git nope"], f.hunks.first.lines.map(&:text)
    assert_equal "f", f.old_path
  end

  def test_hidden_characters_are_flagged_per_line
    text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n" \
           " plain\n-safe​gone\n+new‮line\n+fine\n\\ No newline at end of file\n"
    f = Diff.parse(text).first
    assert_equal ["−2", "+2"], f.hidden_lines.map(&:label)
    assert_empty Diff.parse(MODIFIED).first.hidden_lines
  end

  def test_empty_and_garbage_input
    assert_empty Diff.parse("")
    assert_empty Diff.parse("not a diff at all\n+++ nope\n")
  end

  def test_patch_wraps_text_and_parses_lazily
    patch = Diff::Patch.new(stat: "1 file changed", text: MODIFIED)
    refute patch.empty?
    refute patch.truncated?
    assert_equal ["lib/thing.rb"], patch.files.map(&:path)
    assert_same patch.files, patch.files
    assert Diff::Patch.new(stat: "", text: "").empty?
  end
end
