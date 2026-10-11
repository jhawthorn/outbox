# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < OutboxTest::RepoCase
  Config = Outbox::Config
  Repo = Outbox::Repo

  def live = Config.live_path

  def conf = git("show", "HEAD:outbox.conf", chdir: live)

  def test_ensure_creates_the_live_repo_and_its_staging_repo
    assert_equal "refs/heads/main", git("symbolic-ref", "HEAD", chdir: live).strip
    assert_includes conf, "[repo \"rails\"]", "the initial file explains the format"
    assert_equal "outbox", git("log", "-1", "--format=%an", chdir: live).strip

    staging = Config.staging
    assert File.directory?(staging.path)
    assert staging.config?
    assert_equal "../../config.git", staging.upstream_url
    assert File.executable?(File.join(staging.path, "hooks", "update"))
    assert_equal File.join(Repo.repos_dir, "_config.git"), staging.path

    staging.fetch!
    assert_equal [%w[main synced]], staging.branches.map { |b| [b.name, b.status.to_s] }
    assert_equal "refs/heads/main", staging.git("symbolic-ref", "HEAD").strip
  end

  def test_ensure_is_idempotent
    before = rev(live, "main")
    Config.ensure!
    assert_equal before, rev(live, "main")
    assert_equal %w[_config demo], Repo.all.map(&:name)
  end

  def test_load_parses_entries_and_reports_problems
    assert_empty Config.load.repos
    assert_empty Config.load.problems

    Config.edit(message: "Several") do |f|
      File.write(f, <<~CONF)
        [repo "rails"]
            upstream = git@github.com:rails/rails.git
        [repo "a.b"]
            upstream = https://example.com/a.git
            other = ignored
        [repo "-x"]
            upstream = x
        [repo "_config"]
            upstream = y
        [repo "empty"]
            upstream =
        [something]
            upstream = not a repo
      CONF
    end
    config = Config.load
    assert_equal({ "rails" => "git@github.com:rails/rails.git", "a.b" => "https://example.com/a.git" }, config.repos)
    assert_equal [
      "\"-x\" is not a valid repository name",
      "_config is reserved for the configuration itself",
      "empty has no upstream",
    ], config.problems
  end

  def test_load_survives_a_missing_file
    Config.edit(message: "Delete it") { |f| File.delete(f) }
    config = Config.load
    assert_empty config.repos
    assert_match(/outbox\.conf could not be read/, config.problems.first)
  end

  def test_add_and_remove_edit_the_live_config
    Config.add("demo", @upstream)
    assert_equal({ "demo" => @upstream }, Config.load.repos)
    assert_equal "Add demo", git("log", "-1", "--format=%s", chdir: live).strip

    other, = make_upstream("other")
    Config.add("other", other)
    assert_equal %w[demo other], Config.load.repos.keys

    Config.remove("demo")
    assert_equal({ "other" => other }, Config.load.repos)
    assert_equal 4, git("rev-list", "--count", "main", chdir: live).to_i

    assert_raises(ArgumentError) { Config.add("bad name", other) }
    assert_raises(ArgumentError) { Config.add("_config", other) }
    assert_raises(ArgumentError) { Config.add("x", " ") }
    assert_raises(Outbox::GitError) { Config.remove("nope") }
  end

  def test_apply_creates_updates_and_destroys
    # demo exists on disk but is not configured; other is configured but absent.
    other, = make_upstream("other")
    Config.add("other", other)
    key = @repo.deploy_key_path

    stopped = []
    created = Config.apply! { |repo| stopped << repo.name }
    assert_equal ["other"], created.map(&:name)
    assert_equal ["demo"], stopped
    refute File.exist?(@repo.path)
    refute File.exist?(key)
    assert_equal %w[_config other], Repo.all.map(&:name)
    assert_equal other, Repo.find!("other").upstream_url

    created.first.fetch!
    assert_equal %w[main], Repo.find!("other").branches.map(&:name)

    # A changed upstream re-points the existing staging repo.
    moved, = make_upstream("moved")
    Config.add("other", moved)
    assert_empty Config.apply!
    assert_equal moved, Repo.find!("other").upstream_url

    # The config repo itself is never touched.
    assert File.directory?(Config.staging.path)
    assert_empty Config.apply!
  end

  def test_proposed_change_goes_through_review_before_taking_effect
    staging = Config.staging
    staging.fetch!
    work = File.join(@dir, "config-work")
    git("clone", "--quiet", staging.path, work)
    git("config", "-f", File.join(work, "outbox.conf"), "repo.demo.upstream", @upstream, chdir: work)
    git("commit", "--quiet", "-am", "Add demo", chdir: work)
    push(work, "main")

    b = staging.branch("main")
    assert_equal :ready, b.status
    assert_equal ["Add demo"], staging.commits("main").map(&:subject)
    assert_equal ["outbox.conf"], staging.diff("main").files.map(&:path)
    assert_empty Config.load.repos, "the live config is untouched until approval"

    staging.approve!("main")
    assert_equal({ "demo" => @upstream }, Config.load.repos)
    assert_equal :synced, staging.branch("main").status
    assert_equal rev(work, "HEAD"), rev(live, "main")
  end

  def test_only_branches_of_the_config_repo_can_be_pushed
    staging = Config.staging
    staging.fetch!
    work = File.join(@dir, "config-work")
    git("clone", "--quiet", staging.path, work)
    git("commit", "--quiet", "--allow-empty", "-m", "Sneaky", chdir: work)
    _, err, status = Open3.capture3(OutboxTest::GIT_ENV, "git", "push", "origin", "HEAD:refs/remotes/upstream/main", chdir: work)
    refute status.success?
    assert_includes err, "only branches"
    assert_equal rev(live, "main"), rev(staging.path, "refs/remotes/upstream/main")
  end
end
