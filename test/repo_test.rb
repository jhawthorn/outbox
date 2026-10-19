# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

class RepoTest < OutboxTest::RepoCase
  Repo = Outbox::Repo

  # --- creation and lookup ------------------------------------------------

  def test_create_configures_staging_repo
    assert_equal @upstream, @repo.upstream_url
    assert_equal "true", @repo.git("config", "http.receivepack").strip
    assert_equal "+refs/heads/*:refs/remotes/upstream/*", @repo.git("config", "remote.upstream.fetch").strip
    assert_equal "refs/heads/main", @repo.git("symbolic-ref", "HEAD").strip
    assert_equal [%w[main synced]], @repo.branches.map { |b| [b.name, b.status.to_s] }
  end

  def test_upstream_must_be_https_or_a_local_path
    err = assert_raises(ArgumentError) { Repo.create("sshy", "git@github.com:x/y.git") }
    assert_includes err.message, "must be an https URL"
    assert_raises(ArgumentError) { Repo.create("sshy", "ssh://git@github.com/x/y.git") }
    assert_raises(ArgumentError) { Repo.create("sshy", "git://github.com/x/y.git") }
    assert_raises(ArgumentError) { Repo.create("sshy", "relative/path.git") }
    refute File.exist?(File.join(Repo.repos_dir, "sshy.git"))

    gh = Repo.create("gh", "https://github.com/x/y.git")
    assert gh.remote_upstream?
    refute @repo.remote_upstream?, "a local path needs no token"
    refute Outbox::Config.staging.remote_upstream?
  end

  def test_only_branches_can_be_pushed
    hook = File.join(@repo.path, "hooks", "update")
    assert File.executable?(hook)

    # The stage clone pushes through receive-pack, same as the daemon or HTTP.
    commit(@stage, "a.txt", "a\n", "Local only")
    _, err, status = Open3.capture3(OutboxTest::GIT_ENV, "git", "push", "origin", "HEAD:refs/remotes/upstream/main", chdir: @stage)
    refute status.success?
    assert_includes err, "only branches"
    assert_equal rev(@upstream, "main"), rev(@repo.path, "refs/remotes/upstream/main")

    git("tag", "v1", chdir: @stage)
    _, err, status = Open3.capture3(OutboxTest::GIT_ENV, "git", "push", "origin", "v1", chdir: @stage)
    refute status.success?
    assert_includes err, "only branches"

    stage_commit
    assert_equal :ready, status_of
  end

  def test_fetch_installs_the_hook_on_older_repos
    File.delete(File.join(@repo.path, "hooks", "update"))
    @repo.fetch!
    assert File.executable?(File.join(@repo.path, "hooks", "update"))
  end

  def test_fetch_builds_a_reachability_bitmap_for_clones
    @repo.fetch!
    assert_equal 1, Dir.glob(File.join(@repo.path, "objects", "pack", "*.bitmap")).size
    assert File.exist?(File.join(@repo.path, "objects", "info", "commit-graph"))
  end

  def test_create_validates_input_and_leaves_nothing_behind
    assert_raises(ArgumentError) { Repo.create("../x", @upstream) }
    assert_raises(ArgumentError) { Repo.create("", @upstream) }
    assert_raises(ArgumentError) { Repo.create("has space", @upstream) }
    assert_raises(ArgumentError) { Repo.create("ok", "   ") }
    assert_raises(ArgumentError) { Repo.create("demo", @upstream) }
    refute File.exist?(File.join(Repo.repos_dir, "ok.git"))
    assert_equal %w[_config demo], Repo.all.map(&:name)
  end

  def test_find
    assert_equal "demo", Repo.find("demo").name
    assert_equal "_config", Repo.find("_config").name
    assert Repo.find("_config").config?
    refute @repo.config?
    assert_nil Repo.find("nope")
    assert_nil Repo.find("../demo")
    assert_nil Repo.find("-x")
    assert_nil Repo.find(nil)
    assert_raises(Outbox::NotFound) { Repo.find!("nope") }
  end

  def test_destroy
    @repo.destroy!
    refute File.exist?(@repo.path)
    assert_equal %w[_config], Repo.all.map(&:name)
  end

  def test_upstream_url_can_be_changed
    other, = make_upstream("other")
    @repo.upstream_url = other
    assert_equal other, @repo.upstream_url
  end

  def test_remote_env_hands_the_token_to_askpass
    assert_equal({}, Repo.new("demo", upstream_token: nil).remote_env)
    env = Repo.new("demo", upstream_token: "ghp_test").remote_env
    assert_equal Repo::ASKPASS, env["GIT_ASKPASS"]
    assert_equal "ghp_test", env["OUTBOX_UPSTREAM_TOKEN"]
    assert File.executable?(Repo::ASKPASS)
  end

  def test_upstream_token_comes_from_the_environment
    saved = ENV.delete("OUTBOX_UPSTREAM_TOKEN")
    assert_nil Repo.upstream_token
    ENV["OUTBOX_UPSTREAM_TOKEN"] = "  "
    assert_nil Repo.upstream_token, "blank counts as unset"
    ENV["OUTBOX_UPSTREAM_TOKEN"] = "ghp_test"
    assert_equal "ghp_test", Repo.upstream_token
    assert_equal "ghp_test", Repo.new("demo").remote_env["OUTBOX_UPSTREAM_TOKEN"]
  ensure
    saved ? ENV["OUTBOX_UPSTREAM_TOKEN"] = saved : ENV.delete("OUTBOX_UPSTREAM_TOKEN")
  end

  # The program git runs for credentials: username, then token, from the
  # environment it was given.
  def test_askpass_answers_from_the_environment
    env = { "OUTBOX_UPSTREAM_TOKEN" => "ghp_test", "PATH" => ENV["PATH"] }
    out, _, status = Open3.capture3(env, RbConfig.ruby, Repo::ASKPASS, "Username for 'https://github.com': ", unsetenv_others: true)
    assert status.success?
    assert_equal "x-access-token\n", out
    out, _, status = Open3.capture3(env, RbConfig.ruby, Repo::ASKPASS, "Password for 'https://x-access-token@github.com': ", unsetenv_others: true)
    assert status.success?
    assert_equal "ghp_test\n", out

    _, err, status = Open3.capture3({ "PATH" => ENV["PATH"] }, RbConfig.ruby, Repo::ASKPASS, "Password for 'https://github.com': ", unsetenv_others: true)
    refute status.success?
    assert_includes err, "OUTBOX_UPSTREAM_TOKEN is not set"
    _, err, status = Open3.capture3(env, RbConfig.ruby, Repo::ASKPASS, "Something else: ", unsetenv_others: true)
    refute status.success?
    assert_includes err, "unexpected prompt"
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
    assert_equal 2, @repo.commit_count("main")
    assert_equal 1, @repo.commits("main", limit: 1).size
    assert_equal 0, @repo.outgoing_commit_count("main")

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

  def test_head_follows_upstream_default_branch_not_the_init_name
    bare = File.join(@dir, "trunk.git")
    work = File.join(@dir, "trunk-work")
    git("init", "--quiet", "--bare", "-b", "trunk", bare)
    git("init", "--quiet", "-b", "trunk", work)
    git("remote", "add", "origin", bare, chdir: work)
    commit(work, "README", "old\n", "ancient")
    push(work, "trunk:master")
    commit(work, "README", "new\n", "current")
    push(work, "trunk")

    repo = Repo.create("trunk", bare)
    init_default = repo.git("symbolic-ref", "HEAD").strip
    assert_includes ["refs/heads/master", "refs/heads/main"], init_default
    repo.fetch!
    assert_equal "refs/heads/trunk", repo.git("symbolic-ref", "HEAD").strip
    assert_equal %w[master trunk], repo.branches.map(&:name)

    git("symbolic-ref", "HEAD", "refs/heads/master", chdir: bare)
    repo.fetch!
    assert_equal "refs/heads/master", repo.git("symbolic-ref", "HEAD").strip
  end

  def test_new_branch_on_empty_upstream_diffs_against_empty_tree
    bare = File.join(@dir, "empty.git")
    git("init", "--quiet", "--bare", "-b", "main", bare)
    repo = Repo.create("empty", bare)
    repo.fetch!
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
    assert_equal ["staged.txt", "up.txt"], patch.files.map(&:path).sort
    by_path = patch.files.to_h { |f| [f.path, f.status] }
    assert_equal :added, by_path["staged.txt"]
    assert_equal :deleted, by_path["up.txt"], "force-pushing drops upstream's change; the diff must say so"
  end

  def test_amended_branch_diffs_against_upstream_tip
    commit(@stage, "a.txt", "a\n", "Add a")
    commit(@stage, "b.txt", "b\n", "Add b")
    push(@stage, "main")
    @repo.approve!("main")
    assert_equal :synced, status_of

    # Fix a typo in the tip commit and force-push the rewritten history.
    File.write(File.join(@stage, "b.txt"), "b fixed\n")
    git("add", "b.txt", chdir: @stage)
    git("commit", "--quiet", "--amend", "--no-edit", chdir: @stage)
    push(@stage, "main", force: true)

    b = @repo.branch("main")
    assert_equal :diverged, b.status
    assert_equal ["Add b"], @repo.commits("main").map(&:subject)
    assert_equal ["Add b"], @repo.outgoing_commits("main").map(&:subject)

    patch = @repo.diff("main")
    assert_equal ["b.txt"], patch.files.map(&:path), "only the amendment, not the whole rewritten branch"
    assert_includes patch.text, "-b\n"
    assert_includes patch.text, "+b fixed\n"
    refute_includes patch.text, "a.txt"
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

  def test_last_push_at_counts_pushes_but_not_fetches
    upstream_commit
    @repo.fetch!
    assert_nil @repo.last_push_at, "following upstream is not a push"
    before = Time.now.to_i
    git("checkout", "-q", "-b", "feature", chdir: @stage)
    stage_commit(branch: "feature")
    assert_operator @repo.last_push_at.to_i, :>=, before - 1
  end

  def test_branch_time_is_tip_committer_date
    sha = upstream_commit
    @repo.fetch!
    expected = Time.at(@repo.git("log", "-1", "--format=%ct", sha).to_i)
    assert_equal expected, @repo.branch("main").time
    assert_equal expected, @repo.branches.first.time
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
    assert_equal %w[main nb], @repo.branches.map(&:name).sort
  end

  def test_branches_are_sorted_by_tip_time_newest_first
    tree = rev(@repo.path, "refs/heads/main^{tree}")
    { "alpha" => 1_000_000_000, "beta" => 1_500_000_000, "gamma" => 1_200_000_000 }.each do |name, time|
      env = OutboxTest::GIT_ENV.merge("GIT_COMMITTER_DATE" => "#{time} +0000", "GIT_AUTHOR_DATE" => "#{time} +0000")
      sha, err, st = Open3.capture3(env, "git", "commit-tree", tree, "-m", name, chdir: @repo.path)
      assert st.success?, err
      git("update-ref", "refs/heads/#{name}", sha.strip, chdir: @repo.path)
    end
    names = @repo.branches.map(&:name)
    assert_equal %w[beta gamma alpha], names.reject { |n| n == "main" }
    assert_operator names.index("main"), :<, names.index("beta") unless names.first == "main"
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

  def test_approve_refuses_when_branch_moved_since_review
    reviewed = stage_commit("a.txt", "a\n", "Reviewed")
    sneaked = stage_commit("b.txt", "b\n", "Pushed after review")

    err = assert_raises(Outbox::GitError) { @repo.approve!("main", expected: reviewed) }
    assert_includes err.message, "changed since you reviewed it"
    assert_includes err.message, reviewed[0, 10]
    assert_includes err.message, sneaked[0, 10]
    refute_equal sneaked, rev(@upstream, "main")

    @repo.approve!("main", expected: sneaked)
    assert_equal sneaked, rev(@upstream, "main")
  end

  def test_expected_covers_deletion_and_recreation
    add_upstream_branch("extra")
    git("push", "--quiet", "origin", ":extra", chdir: @stage)
    # Reviewer saw it deleted; agent then recreates it before approve lands.
    git("fetch", "--quiet", "origin", chdir: @stage)
    git("push", "--quiet", "origin", "main:refs/heads/extra", chdir: @stage)
    assert_raises(Outbox::GitError) { @repo.approve!("extra", expected: "") }
    assert ref_exists?(@upstream, "refs/heads/extra")
  end

  def test_discard_refuses_when_branch_moved_since_review
    reviewed = stage_commit("a.txt", "a\n", "Reviewed")
    stage_commit("b.txt", "b\n", "Pushed after review")
    assert_raises(Outbox::GitError) { @repo.discard!("main", expected: reviewed) }
    assert_equal :ready, status_of
  end

  # --- identity -----------------------------------------------------------

  def test_committer_is_exposed_when_it_differs_from_author
    env = OutboxTest::GIT_ENV.merge("GIT_COMMITTER_NAME" => "Someone Else", "GIT_COMMITTER_EMAIL" => "else@example.com")
    _, err, status = Open3.capture3(env, "git", "commit", "--quiet", "--allow-empty", "-m", "Rebased", chdir: @stage)
    assert status.success?, err
    push(@stage, "main")

    c = @repo.commits("main").first
    assert c.committer_differs?
    assert_equal "Test", c.author
    assert_equal "Someone Else", c.committer
    assert_equal "else@example.com", c.committer_email
    refute @repo.commits("main").last.committer_differs? if @repo.commits("main").size > 1
  end

  def test_merge_commits_are_identified
    git("checkout", "--quiet", "-b", "side", chdir: @stage)
    commit(@stage, "s.txt", "s\n", "Side")
    git("checkout", "--quiet", "main", chdir: @stage)
    commit(@stage, "m.txt", "m\n", "Main")
    git("merge", "--quiet", "--no-ff", "-m", "Merge side", "side", chdir: @stage)
    push(@stage, "main")

    merge = @repo.commits("main").first
    assert merge.merge?
    assert_equal 2, merge.parents.size
    assert_equal ["s.txt"], @repo.commit_diff(merge.sha).files.map(&:path),
                 "merge diff is against the first parent, so only the side branch's file shows"
  end

  # --- base and stats -----------------------------------------------------

  def test_base_is_upstreams_tip_when_ready
    tip = rev(@repo.path, "refs/remotes/upstream/main")
    stage_commit
    base = @repo.base("main")
    assert_equal tip, base.commit.sha
    assert_equal "main", base.ref
  end

  def test_base_is_the_merge_base_when_diverged
    fork = rev(@repo.path, "refs/remotes/upstream/main")
    stage_commit
    upstream_commit
    @repo.fetch!
    assert_equal :diverged, status_of
    assert_equal fork, @repo.base("main").commit.sha
  end

  def test_base_of_a_new_branch_is_where_it_left_the_default_branch
    tip = rev(@repo.path, "refs/remotes/upstream/main")
    git("checkout", "--quiet", "-b", "feature", chdir: @stage)
    stage_commit(branch: "feature")
    base = @repo.base("feature")
    assert_equal tip, base.commit.sha
    assert_equal "main", base.ref
  end

  def test_nothing_staged_has_no_base
    assert_nil @repo.base("main")
  end

  def test_commit_stats_count_added_and_deleted_lines_per_commit
    first = commit(@stage, "a.txt", "1\n2\n3\n", "Add a")
    File.write(File.join(@stage, "a.txt"), "1\nX\n3\n4\n")
    File.write(File.join(@stage, "b.txt"), "b\n")
    git("add", "a.txt", "b.txt", chdir: @stage)
    git("commit", "--quiet", "-m", "Change a, add b", chdir: @stage)
    second = rev(@stage, "HEAD")
    push(@stage, "main")

    assert_equal({ first => [3, 0], second => [3, 1] }, @repo.commit_stats("main"))
  end

  def test_commit_stats_count_binary_files_as_nothing
    sha = commit(@stage, "blob.bin", "a\0b\0c", "Add binary")
    push(@stage, "main")
    assert_equal({ sha => [0, 0] }, @repo.commit_stats("main"))
  end

  def test_commit_stats_are_empty_when_nothing_is_staged
    assert_equal({}, @repo.commit_stats("main"))
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
