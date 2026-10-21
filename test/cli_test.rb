# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

# bin/outbox, run as the separate process it is, against the test data dir.
class CliTest < OutboxTest::RepoCase
  BIN = File.expand_path("../bin/outbox", __dir__)

  def outbox(*args)
    env = { "OUTBOX_DATA" => ENV["OUTBOX_DATA"], "PATH" => ENV["PATH"], "HOME" => ENV["HOME"] }
    Open3.capture3(env, RbConfig.ruby, BIN, *args, unsetenv_others: true)
  end

  def outbox!(*args)
    out, err, status = outbox(*args)
    assert status.success?, "outbox #{args.join(" ")} failed:\n#{err}"
    out
  end

  def test_list_shows_repos_and_branches
    stage_commit
    out = outbox!("list")
    assert_includes out, "_config  (configuration)"
    assert_includes out, "demo  (upstream #{@upstream})"
    assert_match(/main\s+ready\s+staged=\h{10} upstream=\h{10}/, out)
  end

  def test_add_edits_the_configuration_and_fetches
    other, = make_upstream("other")
    out = outbox!("add", "other", other)
    assert_includes out, "added other"
    assert_equal({ "other" => other }, Outbox::Config.load.repos.transform_values(&:push_url))
    repo = Outbox::Repo.find!("other")
    assert_equal %w[main], repo.branches.map(&:name)
    assert File.exist?(@repo.path), "demo is not configured but is left alone"

    _, err, status = outbox("add", "bad name", other)
    refute status.success?
    assert_includes err, "invalid repository name"
    _, err, status = outbox("add", "_config", other)
    refute status.success?
    assert_includes err, "reserved"
  end

  # A wrong URL or a missing token makes the first fetch fail; the repo is
  # still added, and the fix is a fetch later.
  def test_add_survives_a_failed_first_fetch
    out, err, status = outbox("add", "unreachable", File.join(@dir, "nonexistent.git"))
    assert status.success?, err
    assert_includes out, "added unreachable"
    assert_includes err, "first fetch failed"
    assert_includes err, "outbox fetch unreachable"
    assert Outbox::Repo.find("unreachable")
    assert_equal File.join(@dir, "nonexistent.git"), Outbox::Config.load.repos["unreachable"].push_url
  end

  def test_remove_edits_the_configuration_and_destroys
    Outbox::Config.add("demo", @upstream)
    outbox!("remove", "demo")
    assert_empty Outbox::Config.load.repos
    refute File.exist?(@repo.path)
    assert_equal "hello\n", git("show", "main:README", chdir: @upstream), "upstream untouched"

    _, err, status = outbox("remove", "demo")
    refute status.success?
    assert_includes err, "no repository named"
  end

  def test_fetch_approve_and_discard
    Outbox::Config.add("demo", @upstream)
    upstream_commit
    outbox!("fetch", "demo")
    assert_equal rev(@upstream, "main"), rev(@repo.path, "refs/heads/main")

    git("pull", "--quiet", "origin", "main", chdir: @stage)
    staged = stage_commit
    assert_includes outbox!("approve", "demo", "main"), "pushed main to upstream"
    assert_equal staged, rev(@upstream, "main")

    stage_commit("z.txt", "z\n", "Z")
    outbox!("discard", "demo", "main")
    assert_equal :synced, status_of
  end

  def test_approving_the_configuration_applies_it
    config = Outbox::Config.staging
    config.fetch!
    work = File.join(@dir, "config-work")
    git("clone", "--quiet", config.path, work)
    git("config", "-f", File.join(work, "outbox.conf"), "repo.demo.upstream", @upstream, chdir: work)
    git("commit", "--quiet", "-am", "Add demo", chdir: work)
    push(work, "main")

    outbox!("approve", "_config", "main")
    assert_equal({ "demo" => @upstream }, Outbox::Config.load.repos.transform_values(&:push_url))
    assert File.exist?(@repo.path)
  end

  def test_usage_and_unknown_command
    _, err, status = outbox("nope")
    refute status.success?
    assert_includes err, "usage: outbox"
    _, err, status = outbox("add", "only-one-arg")
    refute status.success?
    assert_includes err, "usage: outbox"
  end
end
