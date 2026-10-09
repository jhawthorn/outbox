# frozen_string_literal: true

require_relative "test_helper"

class RepoTest < OutboxTest::RepoCase
  Repo = Outbox::Repo

  # --- creation and lookup ------------------------------------------------

  def test_create_configures_staging_repo
    assert_equal @upstream, @repo.upstream_url
    assert_equal "true", @repo.git("config", "http.receivepack").strip
    assert_equal "+refs/heads/*:refs/remotes/upstream/*", @repo.git("config", "remote.upstream.fetch").strip
    assert_equal "refs/heads/main", @repo.git("symbolic-ref", "HEAD").strip
    assert @repo.head_valid?
    assert_equal [%w[main synced]], @repo.branches.map { |b| [b.name, b.status.to_s] }
  end

  def test_create_generates_a_private_deploy_key
    assert_match(/\Assh-ed25519 \S+ outbox deploy key: demo\z/, @repo.public_key)
    assert_equal 0o600, File.stat(@repo.deploy_key_path).mode & 0o777
    assert_equal @repo.path, File.dirname(@repo.deploy_key_path)
  end

  def test_create_validates_input_and_leaves_nothing_behind
    assert_raises(ArgumentError) { Repo.create("../x", @upstream) }
    assert_raises(ArgumentError) { Repo.create("", @upstream) }
    assert_raises(ArgumentError) { Repo.create("has space", @upstream) }
    assert_raises(ArgumentError) { Repo.create("ok", "   ") }
    assert_raises(ArgumentError) { Repo.create("demo", @upstream) }
    refute File.exist?(File.join(Repo.repos_dir, "ok.git"))
    assert_equal ["demo"], Repo.all.map(&:name)
  end

  def test_find
    assert_equal "demo", Repo.find("demo").name
    assert_nil Repo.find("nope")
    assert_nil Repo.find("../demo")
    assert_nil Repo.find(nil)
    assert_raises(Outbox::NotFound) { Repo.find!("nope") }
  end

  def test_destroy
    @repo.destroy!
    refute File.exist?(@repo.path)
    assert_empty Repo.all
  end

  def test_git_env_uses_the_deploy_key_through_the_wrapper
    env = @repo.git_env
    assert_equal Repo::SSH_WRAPPER, env["GIT_SSH"]
    assert_equal @repo.deploy_key_path, env["OUTBOX_SSH_KEY"]
    assert_equal File.join(ENV["OUTBOX_DATA"], "known_hosts"), env["OUTBOX_KNOWN_HOSTS"]
    assert File.executable?(Repo::SSH_WRAPPER)
    refute env.key?("GIT_SSH_COMMAND")

    File.delete(@repo.deploy_key_path)
    assert_equal({}, @repo.git_env)
  end

  # --- branch states ------------------------------------------------------

  def test_ready_branch
    first = stage_commit("a.txt", "a\n", "First")
    second = stage_commit("b.txt", "b\n", "Second")

    b = @repo.branch("main")
    assert_equal :ready, b.status
    assert_equal second, b.staged
    assert_equal rev(@upstream, "main"), b.upstream
    assert_equal 2, b.ahead
    assert_equal 0, b.behind
    assert b.pending?
    refute b.needs_force?

    assert_equal %w[Second First], @repo.commits("main").map(&:subject)
    assert_equal [second, first], @repo.commits("main").map(&:sha)
    assert_empty @repo.outgoing_commits("main")

    patch = @repo.diff("main")
    assert_includes patch.stat, "2 files changed"
    assert_equal %w[a.txt b.txt], patch.files.map(&:path)
    assert_equal %i[added added], patch.files.map(&:status)
    refute_includes patch.text, "README"
    refute patch.truncated?
  end

  def test_synced_branch_has_nothing_to_show
    b = @repo.branch("main")
    assert_equal :synced, b.status
    refute b.pending?
    assert_equal [0, 0], [b.ahead, b.behind]
    assert_empty @repo.commits("main")
    assert @repo.diff("main").empty?
  end

  def test_new_branch_diffs_against_where_it_forked
    git("checkout", "--quiet", "-b", "feature/x", chdir: @stage)
    sha = stage_commit("x.txt", "x\n", "Add x", branch: "feature/x")

    b = @repo.branch("feature/x")
    assert_equal :new, b.status
    assert_equal sha, b.staged
    assert_nil b.upstream
    assert_equal 1, b.ahead
    assert_equal ["Add x"], @repo.commits("feature/x").map(&:subject)

    patch = @repo.diff("feature/x")
    assert_includes patch.stat, "1 file changed"
    assert_equal ["x.txt"], patch.files.map(&:path)
    refute_includes patch.text, "README", "diff must be against the fork point, not the empty tree"
  end

  def test_new_branch_on_empty_upstream_diffs_against_empty_tree
    bare = File.join(@dir, "empty.git")
    git("init", "--quiet", "--bare", "-b", "main", bare)
    repo = Repo.create("empty", bare)
    repo.fetch!
    repo.set_default_head!
    assert_empty repo.branches

    work = File.join(@dir, "empty-work")
    git("init", "--quiet", "-b", "main", work)
    git("remote", "add", "origin", repo.path, chdir: work)
    sha = commit(work, "f.txt", "first\n", "First")
    push(work, "main")

    b = repo.branch("main")
    assert_equal :new, b.status
    assert_equal 1, b.ahead
    assert_includes repo.diff("main").text, "+first"

    repo.approve!("main")
    assert_equal sha, rev(bare, "main")
  end

  def test_deleted_branch
    extra = add_upstream_branch("extra")
    git("push", "--quiet", "origin", ":extra", chdir: @stage)

    b = @repo.branch("extra")
    assert_equal :deleted, b.status
    assert_nil b.staged
    assert_equal extra, b.upstream
    assert_equal 1, b.behind, "one commit only reachable from the deleted branch"
    assert_equal ["extra commit"], @repo.outgoing_commits("extra").map(&:subject)
    assert_empty @repo.commits("extra")
    assert @repo.diff("extra").empty?
  end

  def test_diverged_branch
    staged = stage_commit
    upstream_commit

    assert_equal :ready, status_of, "divergence is only visible after a fetch"
    @repo.fetch!

    b = @repo.branch("main")
    assert_equal :diverged, b.status
    assert_equal staged, b.staged
    assert_equal 1, b.ahead
    assert_equal 1, b.behind
    assert b.needs_force?
    assert_equal ["Staged change"], @repo.commits("main").map(&:subject)
    assert_equal ["Upstream change"], @repo.outgoing_commits("main").map(&:subject)

    patch = @repo.diff("main")
    assert_equal ["staged.txt"], patch.files.map(&:path), "diff shows only what the staged branch adds since the fork point"
  end

  # --- commits ------------------------------------------------------------

  def test_commit_detail_and_commit_diff
    first = stage_commit("a.txt", "a\n", "First")
    File.write(File.join(@stage, "b.txt"), "b\n")
    git("add", "b.txt", chdir: @stage)
    git("commit", "--quiet", "-m", "Second\n\nWhy it was done.", chdir: @stage)
    second = rev(@stage, "HEAD")
    push(@stage, "main")

    c = @repo.commit_detail(second)
    assert_equal second, c.sha
    assert_equal "Second", c.subject
    assert_equal "Why it was done.", c.body
    assert c.body?
    assert_equal 1, c.body_lines
    assert_equal "test@example.com", c.author_email
    assert_equal [first], c.parents
    refute c.root?
    refute c.merge?

    listed = @repo.commits("main")
    assert_equal ["Second", "First"], listed.map(&:subject)
    assert_equal ["Why it was done.", ""], listed.map(&:body), "the list carries full messages, not just subjects"
    refute listed[1].body?

    assert_equal ["b.txt"], @repo.commit_diff(second).files.map(&:path)
    assert_equal ["a.txt"], @repo.commit_diff(first).files.map(&:path)
    assert_raises(ArgumentError) { @repo.commit_detail("not a sha") }
  end

  def test_commit_message_without_blank_line_still_exposes_the_rest
    git("commit", "--quiet", "--allow-empty", "-m", "Looks innocent\nalso deletes prod\nand this", chdir: @stage)
    push(@stage, "main")
    c = @repo.commits("main").first
    assert_equal "Looks innocent", c.subject
    assert_equal "also deletes prod\nand this", c.body
    assert_equal 2, c.body_lines
  end

  def test_patch_is_truncated_at_a_line_boundary
    stage_commit("big.txt", (1..500).map { |i| "line #{i}" }.join("\n") + "\n", "Big")
    patch = @repo.diff("main", max_bytes: 1000)
    assert patch.truncated?
    assert_operator patch.text.bytesize, :<=, 1000
    assert patch.text.end_with?("\n")
    assert_equal ["big.txt"], patch.files.map(&:path)
    refute @repo.diff("main").truncated?
  end

  def test_branch_names_are_validated
    assert_raises(Outbox::NotFound) { @repo.branch("nope") }
    assert_raises(Outbox::NotFound) { @repo.commits("nope") }
  end

  # --- fetch reconciliation -----------------------------------------------

  def test_fetch_fast_forwards_untouched_branch
    sha = upstream_commit
    @repo.fetch!
    assert_equal sha, rev(@repo.path, "refs/heads/main")
    assert_equal sha, rev(@repo.path, "refs/remotes/upstream/main")
    assert_equal :synced, status_of
  end

  def test_fetch_leaves_staged_branch_alone
    staged = stage_commit
    upstream_commit
    @repo.fetch!
    assert_equal staged, rev(@repo.path, "refs/heads/main")
    assert_equal :diverged, status_of
  end

  def test_fetch_mirrors_new_upstream_branch
    sha = add_upstream_branch("nb")
    assert_equal sha, rev(@repo.path, "refs/heads/nb")
    assert_equal :synced, status_of("nb")
    assert_equal %w[main nb], @repo.branches.map(&:name)
  end

  def test_fetch_prunes_branch_deleted_upstream_when_untouched
    add_upstream_branch("nb")
    git("push", "--quiet", "origin", ":nb", chdir: @up_work)
    @repo.fetch!
    refute ref_exists?(@repo.path, "refs/heads/nb")
    refute ref_exists?(@repo.path, "refs/remotes/upstream/nb")
    assert_equal ["main"], @repo.branches.map(&:name)
  end

  def test_fetch_keeps_branch_deleted_upstream_when_staged
    add_upstream_branch("nb")
    git("fetch", "--quiet", "origin", chdir: @stage)
    git("checkout", "--quiet", "-b", "nb", "origin/nb", chdir: @stage)
    staged = stage_commit("more.txt", "more\n", "More on nb", branch: "nb")

    git("push", "--quiet", "origin", ":nb", chdir: @up_work)
    @repo.fetch!

    b = @repo.branch("nb")
    assert_equal :new, b.status, "staged work survives an upstream deletion and reads as a new branch"
    assert_equal staged, b.staged
  end

  def test_fetch_does_not_fetch_tags
    git("tag", "v1", chdir: @up_work)
    git("push", "--quiet", "origin", "v1", chdir: @up_work)
    @repo.fetch!
    assert_equal "", @repo.git("tag", "--list").strip
  end

  # --- approve ------------------------------------------------------------

  def test_approve_ready_branch_pushes_to_upstream
    staged = stage_commit
    @repo.approve!("main")
    assert_equal staged, rev(@upstream, "main")
    assert_equal :synced, status_of
  end

  def test_approve_new_branch_creates_it_upstream
    git("checkout", "--quiet", "-b", "feature/x", chdir: @stage)
    sha = stage_commit("x.txt", "x\n", "Add x", branch: "feature/x")
    @repo.approve!("feature/x")
    assert_equal sha, rev(@upstream, "feature/x")
    assert_equal :synced, status_of("feature/x")
  end

  def test_approve_deleted_branch_deletes_it_upstream
    add_upstream_branch("extra")
    git("push", "--quiet", "origin", ":extra", chdir: @stage)
    @repo.approve!("extra")
    refute ref_exists?(@upstream, "refs/heads/extra")
    assert_raises(Outbox::NotFound) { @repo.branch("extra") }
  end

  def test_approve_synced_branch_raises
    err = assert_raises(Outbox::GitError) { @repo.approve!("main") }
    assert_includes err.message, "already in sync"
  end

  def test_approve_diverged_requires_force
    staged = stage_commit
    moved = upstream_commit
    @repo.fetch!

    err = assert_raises(Outbox::GitError) { @repo.approve!("main") }
    assert_includes err.message, "diverged"
    assert_equal moved, rev(@upstream, "main"), "a refused approve must not touch upstream"

    @repo.approve!("main", force: true)
    assert_equal staged, rev(@upstream, "main")
    assert_equal :synced, status_of
  end

  def test_approve_is_refused_when_upstream_moved_since_last_fetch
    stage_commit
    moved = upstream_commit
    assert_equal :ready, status_of, "the outbox has not fetched, so it still thinks this is a fast-forward"

    err = assert_raises(Outbox::GitError) { @repo.approve!("main") }
    assert_match(/stale info|rejected/, err.message)
    assert_equal moved, rev(@upstream, "main"), "force-with-lease must protect commits the outbox has not seen"
  end

  # --- discard ------------------------------------------------------------

  def test_discard_resets_staged_branch_to_upstream
    stage_commit
    @repo.discard!("main")
    assert_equal rev(@upstream, "main"), rev(@repo.path, "refs/heads/main")
    assert_equal :synced, status_of
  end

  def test_discard_removes_new_branch
    git("checkout", "--quiet", "-b", "feature/x", chdir: @stage)
    stage_commit("x.txt", "x\n", "Add x", branch: "feature/x")
    @repo.discard!("feature/x")
    refute ref_exists?(@repo.path, "refs/heads/feature/x")
    assert_raises(Outbox::NotFound) { @repo.branch("feature/x") }
  end

  def test_discard_restores_deleted_branch
    extra = add_upstream_branch("extra")
    git("push", "--quiet", "origin", ":extra", chdir: @stage)
    @repo.discard!("extra")
    assert_equal extra, rev(@repo.path, "refs/heads/extra")
    assert_equal :synced, status_of("extra")
  end
end
