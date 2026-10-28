# frozen_string_literal: true

require_relative "test_helper"

# Review comments as git notes (Repo#comments, Repo#add_comment!), in
# git-appraise's format.
class CommentTest < OutboxTest::RepoCase
  def test_a_comment_is_a_line_of_json_in_a_note_on_the_commit
    sha = stage_commit("lib/a.rb", "x = 1\ny = 2\n", "Add a")
    @repo.add_comment!(sha, Outbox::Comment.new(author: "jh", description: "Why y?", timestamp: "1700000000",
                                                commit: sha, path: "lib/a.rb", start_line: 2, end_line: 2))

    # Read with git itself, the way whoever pushed it would.
    note = git("notes", "--ref", "devtools/discuss", "show", sha, chdir: @repo.path)
    assert_equal 1, note.lines.size
    assert_equal({ "timestamp" => "1700000000", "author" => "jh",
                   "location" => { "commit" => sha, "path" => "lib/a.rb", "range" => { "startLine" => 2 } },
                   "description" => "Why y?" }, JSON.parse(note))

    c, = @repo.comments(sha)
    assert_equal ["jh", "Why y?", sha, "lib/a.rb", 2, 2], [c.author, c.description, c.commit, c.path, c.start_line, c.end_line]
    assert c.line?
    assert_nil c.resolved
  end

  def test_comments_accumulate_oldest_first
    sha = stage_commit
    @repo.add_comment!(sha, Outbox::Comment.new(author: "a", description: "second", timestamp: "20"))
    @repo.add_comment!(sha, Outbox::Comment.new(author: "a", description: "first", timestamp: "10"))
    @repo.add_comment!(sha, Outbox::Comment.new(author: "b", description: "multi\nline", timestamp: "30", resolved: false))
    assert_equal ["first", "second", "multi\nline"], @repo.comments(sha).map(&:description)
    assert @repo.comments(sha).last.rejection?
    assert_equal 3, git("notes", "--ref", "devtools/discuss", "show", sha, chdir: @repo.path).lines.size
  end

  def test_no_comments
    sha = stage_commit
    assert_empty @repo.comments(sha)
    refute ref_exists?(@repo.path, Outbox::Repo::COMMENTS_REF)
  end

  def test_unreadable_lines_are_skipped
    sha = stage_commit
    git("notes", "--ref", "devtools/discuss", "add", "-m", "not json", sha, chdir: @repo.path)
    @repo.add_comment!(sha, Outbox::Comment.new(author: "a", description: "fine"))
    assert_equal ["fine"], @repo.comments(sha).map(&:description)
  end

  # Requests and the repo's actor both write; neither may lose the other's.
  def test_writers_at_once_lose_nothing
    sha = stage_commit
    threads = 8.times.map do |i|
      Thread.new { Outbox::Repo.new("demo").add_comment!(sha, Outbox::Comment.new(author: "t", description: "c#{i}"), attempts: 50) }
    end
    threads.each(&:join)
    assert_equal (0...8).map { |i| "c#{i}" }.sort, @repo.comments(sha).map(&:description).sort
    assert_empty git("for-each-ref", "refs/notes/outbox-scratch", chdir: @repo.path), "scratch refs are cleaned up"
  end

  def test_a_clone_fetches_comments_and_cannot_push_them
    sha = stage_commit
    @repo.add_comment!(sha, Outbox::Comment.new(author: "jh", description: "LGTM", commit: sha, resolved: true))
    git("fetch", "--quiet", "origin", "refs/notes/devtools/*:refs/notes/devtools/*", chdir: @stage)
    assert_includes git("notes", "--ref", "devtools/discuss", "show", sha, chdir: @stage), %("resolved":true)

    git("notes", "--ref", "devtools/discuss", "append", "-m", "forged", sha, chdir: @stage)
    _, err, status = Open3.capture3(OutboxTest::GIT_ENV, "git", "push", "origin", "refs/notes/devtools/discuss", chdir: @stage)
    refute status.success?
    assert_includes err, "only branches"
  end

  def test_removed_lines_are_in_upstreams_commit
    up = rev(@repo.path, "refs/remotes/upstream/main")
    stage_commit
    assert_equal up, @repo.removed_lines_commit("main")
  end

  def test_parse_reads_git_appraise_comments
    c = Outbox::Comment.parse(%({"timestamp":"5","author":"x","location":{"commit":"abc","path":"p","range":{"startLine":3,"endLine":7}},"description":"d","resolved":true,"v":0}))
    assert_equal [3, 7, "p", true], [c.start_line, c.end_line, c.path, c.resolved]
    assert_equal 40, c.id.size
    assert_nil Outbox::Comment.parse("[1]")
    assert_nil Outbox::Comment.parse("{")
  end

  # After a discard and a new push, what was said is on the old tip, and the
  # branch's reflog still knows it was there.
  def test_earlier_pushes_keep_their_comments
    first = stage_commit("a.txt", "a\n", "First try")
    @repo.add_comment!(first, Outbox::Comment.new(author: "jh", description: "No", timestamp: "10"))
    @repo.discard!("main")
    second = stage_commit("a.txt", "b\n", "Second try")
    @repo.add_comment!(second, Outbox::Comment.new(author: "jh", description: "Better", timestamp: "20"))
    third = stage_commit("c.txt", "c\n", "More")

    earlier = @repo.earlier_comments("main")
    assert_equal [second, first], earlier.map(&:first), "newest push first"
    assert_equal [["Better"], ["No"]], earlier.map { |_, list| list.map(&:description) }
    refute_includes earlier.map(&:first), third
    assert_empty Outbox::Repo.new("demo").earlier_comments(@repo.branch("main")).select { |sha, _| sha == third }
  end

  def test_no_earlier_comments
    stage_commit
    assert_empty @repo.earlier_comments("main")
  end

  # --- edit and delete -------------------------------------------------------

  def test_an_edit_is_a_line_naming_the_comment_it_edits
    sha = stage_commit
    @repo.add_comment!(sha, Outbox::Comment.new(author: "jh", description: "Typo", timestamp: "10", commit: sha, path: "staged.txt", start_line: 1))
    @repo.add_comment!(sha, Outbox::Comment.new(author: "jh", description: "Other", timestamp: "11"))
    first, = @repo.comments(sha)
    @repo.edit_comment!(sha, first.id, "Fixed", author: "jh")
    @repo.edit_comment!(sha, first.id, "Fixed again", author: "jh")

    lines = git("notes", "--ref", "devtools/discuss", "show", sha, chdir: @repo.path).lines.map { |l| JSON.parse(l) }
    assert_equal 4, lines.size, "edits are added, nothing is rewritten"
    assert_equal [first.id, first.id], lines.last(2).map { |l| l["original"] }
    assert_equal({ "commit" => sha, "path" => "staged.txt", "range" => { "startLine" => 1 } }, lines.last["location"])

    shown, other = @repo.comments(sha)
    assert_equal ["Fixed again", first.id, "10", "staged.txt"], [shown.description, shown.id, shown.timestamp, shown.path]
    assert shown.edited?
    refute_equal shown.id, shown.version, "the version is the latest edit's"
    assert_equal "Other", other.description
    refute other.edited?
  end

  def test_delete_takes_a_comment_and_its_edits_out_of_the_note
    sha = stage_commit
    @repo.add_comment!(sha, Outbox::Comment.new(author: "jh", description: "Keep", timestamp: "10"))
    @repo.add_comment!(sha, Outbox::Comment.new(author: "jh", description: "Drop", timestamp: "11"))
    keep, drop = @repo.comments(sha)
    @repo.edit_comment!(sha, drop.id, "Drop, edited", author: "jh")
    @repo.delete_comment!(sha, drop.id)
    assert_equal ["Keep"], @repo.comments(sha).map(&:description)
    assert_equal 1, git("notes", "--ref", "devtools/discuss", "show", sha, chdir: @repo.path).lines.size
    assert_equal keep.id, @repo.comments(sha).first.id, "the lines left are as they were"

    @repo.delete_comment!(sha, keep.id)
    assert_empty @repo.comments(sha)
    assert_empty git("notes", "--ref", "devtools/discuss", "list", chdir: @repo.path), "an empty note is removed"
  end

  def test_verdicts_and_missing_comments_cannot_be_edited_or_deleted
    sha = stage_commit
    @repo.add_comment!(sha, Outbox::Comment.new(author: "jh", description: "Approved.", resolved: true))
    verdict, = @repo.comments(sha)
    assert_raises(ArgumentError) { @repo.edit_comment!(sha, verdict.id, "No", author: "jh") }
    assert_raises(ArgumentError) { @repo.delete_comment!(sha, verdict.id) }
    assert_raises(Outbox::NotFound) { @repo.delete_comment!(sha, "0" * 40) }
    assert_equal ["Approved."], @repo.comments(sha).map(&:description)
  end
end

