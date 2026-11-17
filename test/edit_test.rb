# frozen_string_literal: true

require_relative "test_helper"

# Editing staged branches (lib/outbox/edit.rb): changing files in a branch's
# own commits and rewriting those commits, against real git in temp dirs.
class EditTest < OutboxTest::RepoCase
  def setup
    super
    @me = Outbox::Repo::Identity.new(name: "Rev Iewer", email: "rev@example.com")
  end

  def staged = rev(@repo.path, "refs/heads/main")
  def show(sha, file) = git("show", "#{sha}:#{file}", chdir: @repo.path)
  def subjects(range = "refs/remotes/upstream/main..refs/heads/main") = git("log", "--format=%s", range, chdir: @repo.path).lines.map(&:chomp)
  def steps(*pairs) = pairs.map { |action, sha, message| Outbox::Repo::Step.new(action, sha, message) }

  # Three staged commits on main, each adding its own file. Returns their shas, oldest first.
  def three
    [stage_commit("a.txt", "a\n", "Add a"), stage_commit("b.txt", "b\n", "Add b"), stage_commit("c.txt", "c\n", "Add c")]
  end

  def rewrite(plan, expected: staged)
    @repo.rewrite!("main", steps: plan, expected:, identity: @me, by: "rev")
  end

  def test_the_stack_is_the_branchs_own_commits_oldest_first
    a, b, c = three
    s = @repo.stack("main")
    assert_equal [a, b, c], s.commits.map(&:sha)
    assert_equal rev(@repo.path, "refs/remotes/upstream/main"), s.onto
  end

  def test_a_branch_with_nothing_of_its_own_has_an_empty_stack
    s = @repo.stack("main")
    assert s.empty?
    assert_equal staged, s.onto
  end

  def test_rewording_keeps_trees_authors_and_dates
    a, b, c = three
    before = git("log", "--format=%T %an %ae %ad", "-3", "refs/heads/main", chdir: @repo.path)
    edit = rewrite(steps([:pick, a], [:reword, b, "Add b, better\r\n\r\nWith a body.\r\n\r\n"], [:pick, c]))
    assert_equal ["Add c", "Add b, better", "Add a"], subjects
    assert_equal before, git("log", "--format=%T %an %ae %ad", "-3", "refs/heads/main", chdir: @repo.path)
    assert_equal "Add b, better\n\nWith a body.\n", git("log", "-1", "--format=%B", "main~1", chdir: @repo.path).chomp
    assert_equal a, rev(@repo.path, "main~2"), "the commit before the change is kept as it is"
    assert_equal "Rev Iewer rev@example.com", git("log", "-1", "--format=%cn %ce", "main~1", chdir: @repo.path).strip
    assert_equal({ a => a, b => rev(@repo.path, "main~1"), c => staged }, edit.rewritten)
    assert_equal c, edit.old
  end

  def test_dropping_a_commit_replays_the_ones_after_it
    a, b, c = three
    rewrite(steps([:pick, a], [:drop, b], [:pick, c]))
    assert_equal ["Add c", "Add a"], subjects
    assert_equal "c\n", show(staged, "c.txt")
    assert_raises(Minitest::Assertion) { show(staged, "b.txt") }
  end

  def test_dropping_what_a_later_commit_needs_conflicts_and_changes_nothing
    a = stage_commit("a.txt", "one\n", "Add a")
    b = stage_commit("a.txt", "two\n", "Change a")
    before = staged
    e = assert_raises(Outbox::Repo::Conflict) { rewrite(steps([:drop, a], [:pick, b])) }
    assert_equal ["a.txt"], e.paths
    assert_includes e.message, "Change a"
    assert_equal before, staged
  end

  def test_a_commit_left_empty_is_dropped
    git("checkout", "--quiet", "main", chdir: @stage)
    a = stage_commit("README", "changed\n", "Change README")
    b = stage_commit("README", "hello\n", "Change it back")
    c = stage_commit("c.txt", "c\n", "Add c")
    edit = rewrite(steps([:drop, a], [:pick, b], [:pick, c]))
    assert_equal ["Add c"], subjects
    assert_equal [b], edit.emptied
    assert_includes edit.description, "1 commit left empty dropped"
  end

  def test_reordering
    a, b, c = three
    edit = rewrite(steps([:pick, c], [:pick, a], [:pick, b]))
    assert_equal ["Add b", "Add a", "Add c"], subjects
    assert_equal "Reordered commits", edit.description
  end

  def test_squash_joins_messages_and_fixup_keeps_the_first
    a, b, c = three
    rewrite(steps([:pick, a], [:squash, b], [:fixup, c]))
    assert_equal ["Add a"], subjects.map { |s| s.lines.first.strip }
    assert_equal "Add a\n\nAdd b", git("log", "-1", "--format=%B", "main", chdir: @repo.path).strip
    %w[a b c].each { |f| assert_equal "#{f}\n", show(staged, "#{f}.txt") }
  end

  def test_squash_with_a_message_of_its_own
    a, b, c = three
    edit = rewrite(steps([:pick, a], [:squash, b, "And b, said\r\nmy way\r\n"], [:pick, c]))
    assert_equal ["Add c", "Add a"], subjects
    assert_equal "Add a\n\nAnd b, said\nmy way\n", git("log", "-1", "--format=%B", "main~1", chdir: @repo.path).chomp
    assert_equal edit.rewritten[a], edit.rewritten[b], "a and b both went into one commit"
  end

  def test_the_first_commit_cannot_be_squashed_into_upstream
    a, b, = three
    e = assert_raises(ArgumentError) { rewrite(steps([:squash, a], [:pick, b], [:pick, three_last])) }
    assert_includes e.message, "no commit before it"
  end

  def three_last = @repo.stack("main").commits.last.sha

  def test_the_plan_must_name_every_commit_once
    a, b, c = three
    assert_raises(ArgumentError) { rewrite(steps([:pick, a], [:pick, b])) }
    assert_raises(ArgumentError) { rewrite(steps([:pick, a], [:pick, b], [:pick, b])) }
    assert_raises(ArgumentError) { rewrite(steps([:pick, a], [:pick, b], [:pick, c])) }
  end

  def test_refused_when_the_branch_moved
    a, b, c = three
    seen = staged
    stage_commit("d.txt", "d\n", "Add d")
    e = assert_raises(Outbox::GitError) { rewrite(steps([:pick, a], [:drop, b], [:pick, c]), expected: seen) }
    assert_includes e.message, "changed since you reviewed it"
  end

  def test_merges_are_not_edited
    git("checkout", "--quiet", "-b", "side", chdir: @stage)
    commit(@stage, "side.txt", "side\n", "Side")
    git("checkout", "--quiet", "main", chdir: @stage)
    commit(@stage, "main.txt", "main\n", "Main")
    git("merge", "--quiet", "--no-ff", "-m", "Merge side", "side", chdir: @stage)
    push(@stage, "main")
    e = assert_raises(ArgumentError) { @repo.stack("main") }
    assert_includes e.message, "merge"
  end

  def test_an_edit_says_so_in_the_reflog_and_in_a_comment_on_what_it_replaced
    a, b, c = three
    edit = rewrite(steps([:pick, a], [:drop, b], [:pick, c]))
    rec = @repo.last_edit("main")
    assert_equal "rev", rec.by
    assert_equal "Dropped #{b[0, 7]} “Add b”", rec.description
    assert_equal c, rec.old
    assert_equal edit.new, rec.new
    assert_in_delta Time.now, rec.time, 60
    note = @repo.comments(c).last
    assert_equal "rev", note.author
    assert_includes note.description, "Dropped #{b[0, 7]}"
    assert_includes note.description, edit.new
  end

  def test_undo_puts_the_branch_back_and_takes_back_the_comment
    a, b, c = three
    edit = rewrite(steps([:pick, a], [:drop, b], [:pick, c]))
    assert_raises(Outbox::GitError) { @repo.undo_edit!("main", expected: c, by: "rev") }
    @repo.undo_edit!("main", expected: edit.new, by: "rev")
    assert_equal c, staged
    assert_empty @repo.comments(c)
    assert_nil @repo.last_edit("main"), "an undo is not an edit to undo"
    assert_raises(ArgumentError) { @repo.undo_edit!("main", expected: c, by: "rev") }
  end

  def test_a_push_is_not_an_edit
    stage_commit
    assert_nil @repo.last_edit("main")
  end

  # --- files ---

  def change(path, content) = Outbox::Repo::FileChange.new(path:, content:)

  def edit_files(*changes, base: staged, **how)
    @repo.commit_files!("main", base:, changes:, identity: @me, by: "rev", **how)
  end

  def test_an_edit_as_a_new_commit
    _, _, c = three
    edit = edit_files(change("a.txt", "a, edited\n"), message: "Edit a\r\n")
    assert_equal edit.new, staged
    assert_equal c, rev(@repo.path, "main~1"), "the commits before it are kept as they are"
    assert_equal "a, edited\n", show(staged, "a.txt")
    assert_equal "Edit a\n", git("log", "-1", "--format=%B", "main", chdir: @repo.path).chomp
    assert_equal "Rev Iewer rev@example.com Rev Iewer rev@example.com", git("log", "-1", "--format=%an %ae %cn %ce", "main", chdir: @repo.path).strip
    assert_equal "Edited a.txt in a new commit", @repo.last_edit("main").description
  end

  def test_an_edit_folded_into_the_commit_it_belongs_to
    a, b, c = three
    edit = edit_files(change("a.txt", "a, fixed\n"), into: a)
    assert_equal ["Add c", "Add b", "Add a"], subjects
    oldest = rev(@repo.path, "main~2")
    assert_equal "a, fixed\n", show(oldest, "a.txt")
    assert_equal "a, fixed\n", show(staged, "a.txt")
    assert_equal "Test", git("log", "-1", "--format=%an", oldest, chdir: @repo.path).strip, "the commit keeps its author"
    assert_equal oldest, edit.rewritten[a]
    assert_equal [a, b, c].sort, edit.rewritten.keys.sort, "only the branch's commits, not the change folded in"
    assert_equal "Edited a.txt in #{a[0, 7]} “Add a”", edit.description
  end

  def test_several_files_at_once
    a, = three
    edit = edit_files(change("a.txt", "A\n"), change("b.txt", "B\n"), into: staged)
    assert_equal "A\n", show(staged, "a.txt")
    assert_equal "B\n", show(staged, "b.txt")
    assert_includes edit.description, "Edited 2 files in"
    refute_nil a
  end

  # A commit's page shows its files as they were then: an edit made there
  # is of that commit, and the later ones are replayed on it.
  def test_an_edit_of_an_earlier_commits_files
    a = stage_commit("a.txt", "one\ntwo\nthree\n", "Add a")
    stage_commit("a.txt", "one\ntwo\nthree\nfour\n", "Add four")
    edit_files(change("a.txt", "ONE\ntwo\nthree\n"), base: a, into: a)
    assert_equal ["Add four", "Add a"], subjects
    assert_equal "ONE\ntwo\nthree\n", show("main~1", "a.txt")
    assert_equal "ONE\ntwo\nthree\nfour\n", show("main", "a.txt"), "the later commit's own change is kept"

    older = rev(@repo.path, "main~1")
    edit_files(change("a.txt", "ONE\nTWO\nthree\n"), base: older, message: "Shout two")
    assert_equal ["Shout two", "Add four", "Add a"], subjects
    assert_equal "ONE\nTWO\nthree\nfour\n", show("main", "a.txt")
  end

  def test_an_edit_that_does_not_apply_is_refused_and_says_why
    a = stage_commit("a.txt", "one\n", "Add a")
    b = stage_commit("a.txt", "two\n", "Change a")
    e = assert_raises(Outbox::Repo::Conflict) { edit_files(change("a.txt", "three\n"), into: a) }
    assert_includes e.message, "The change does not apply to #{a[0, 7]} “Add a”"
    e = assert_raises(Outbox::Repo::Conflict) { edit_files(change("a.txt", "uno\n"), base: a, into: a) }
    assert_includes e.message, "#{b[0, 7]} “Change a” no longer applies"
    e = assert_raises(Outbox::Repo::Conflict) { edit_files(change("a.txt", "uno\n"), base: a, message: "Edit") }
    assert_includes e.message, "does not apply on top of main"
    assert_equal b, staged
  end

  def test_what_cannot_be_edited
    a, = three
    tip = staged
    e = assert_raises(ArgumentError) { edit_files(change("a.txt", "a\n"), message: "m") }
    assert_includes e.message, "changes nothing"
    assert_raises(ArgumentError) { edit_files(change("a.txt", "x\n"), message: " \n") }
    assert_raises(ArgumentError) { edit_files(message: "m") }
    ["nope.txt", "../x", ".git/config"].each do |path|
      e = assert_raises(ArgumentError) { edit_files(change(path, "x\n"), message: "m") }
      assert_includes e.message, "cannot be edited here: there is no file"
    end
    e = assert_raises(ArgumentError) { edit_files(change("a.txt", "x\n"), into: base_of_upstream) }
    assert_includes e.message, "not one of main's own commits"
    e = assert_raises(Outbox::GitError) { edit_files(change("README", "x\n"), base: base_of_upstream, message: "m") }
    assert_includes e.message, "rewritten since you started editing"
    assert_equal tip, staged
    refute_nil a
  end

  def base_of_upstream = rev(@repo.path, "refs/remotes/upstream/main")

  def test_a_branch_with_nothing_of_its_own_is_not_edited
    e = assert_raises(ArgumentError) { edit_files(change("README", "x\n"), message: "m") }
    assert_includes e.message, "no commits of its own"
  end

  def test_an_edit_keeps_the_files_mode_and_its_line_ends
    File.write(File.join(@stage, "run"), "#!/bin/sh\r\n")
    File.chmod(0o755, File.join(@stage, "run"))
    git("add", "run", chdir: @stage)
    git("commit", "--quiet", "-m", "Add run", chdir: @stage)
    push(@stage, "main")
    edit_files(change("run", "#!/bin/sh\necho hi\n"), message: "Say hi")
    assert_match(/\A100755 /, git("ls-tree", "main", "run", chdir: @repo.path))
    assert_equal "#!/bin/sh\r\necho hi\r\n", show(staged, "run")
  end

  def test_where_an_edit_of_each_file_belongs
    a, b, = three
    b2 = stage_commit("a.txt", "a2\n", "Change a")
    assert_equal({ "a.txt" => b2, "b.txt" => b, "c.txt" => staged_before(b2) }, @repo.touched(@repo.stack("main")))
    refute_nil a
  end

  def staged_before(sha) = rev(@repo.path, "#{sha}~1")

  def test_editable_files
    stage_commit("bin.dat", "a\0b", "Binary")
    sha = staged
    assert_nil @repo.uneditable_reason(sha, "README")
    assert_equal "it is binary", @repo.uneditable_reason(sha, "bin.dat")
    assert_equal "there is no file nope", @repo.uneditable_reason(sha, "nope")
    assert Outbox::Repo.crlf?("a\r\nb\r\n")
    refute Outbox::Repo.crlf?("a\r\nb\n")
  end

  def test_identity
    assert_equal "Jo Doe <jo@example.com>", Outbox::Repo::Identity.for("jo", "Jo Doe <jo@example.com>").to_s
    assert_equal "jo <outbox@localhost>", Outbox::Repo::Identity.for("jo", nil).to_s
    assert_equal "jo <outbox@localhost>", Outbox::Repo::Identity.for("jo", "nonsense").to_s
  end
end
