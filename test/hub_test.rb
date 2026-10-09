# frozen_string_literal: true

require_relative "test_helper"

class HubTest < OutboxTest::RepoCase
  def setup
    super
    @hub = Outbox::Hub.new
  end

  def teardown
    @hub.shutdown
    super
  end

  def wait_idle(repo = @repo)
    wait_until("#{repo.name} to go idle") { !@hub.status(repo).busy? }
  end

  def test_unknown_repo_is_idle
    s = @hub.status(@repo)
    refute s.busy?
    refute s.running?
    assert_equal 0, s.queued
    assert_nil s.last
  end

  def test_fetch_job_runs_in_the_actor_and_reports_back
    sha = upstream_commit
    @hub.fetch(@repo)
    assert @hub.status(@repo).busy?
    wait_idle

    s = @hub.status(@repo)
    refute s.running?
    assert_equal 0, s.queued
    assert s.last.ok?
    assert_equal :fetch, s.last.job
    assert_nil s.last.branch
    assert_equal "fetched upstream", s.last.message
    assert_equal sha, rev(@repo.path, "refs/heads/main")
  end

  def test_fetch_fixes_head_on_a_fresh_repo
    repo = Outbox::Repo.create("fresh", @upstream)
    refute repo.head_valid?
    @hub.fetch(repo)
    wait_idle(repo)
    assert repo.head_valid?
    assert_equal "refs/heads/main", repo.git("symbolic-ref", "HEAD").strip
  end

  def test_approve_job
    staged = stage_commit
    @hub.approve(@repo, "main")
    wait_idle
    s = @hub.status(@repo)
    assert s.last.ok?, s.last.message
    assert_equal :approve, s.last.job
    assert_equal "main", s.last.branch
    assert_equal staged, rev(@upstream, "main")
  end

  def test_approve_with_force
    staged = stage_commit
    upstream_commit
    @hub.fetch(@repo)
    wait_idle
    @hub.approve(@repo, "main", force: true)
    wait_idle
    assert @hub.status(@repo).last.ok?
    assert_equal staged, rev(@upstream, "main")
  end

  def test_discard_job
    stage_commit
    @hub.discard(@repo, "main")
    wait_idle
    s = @hub.status(@repo)
    assert s.last.ok?
    assert_equal :discard, s.last.job
    assert_equal :synced, status_of
  end

  def test_failed_job_is_reported_and_the_actor_keeps_working
    @hub.approve(@repo, "main")
    wait_idle
    s = @hub.status(@repo)
    refute s.last.ok?
    assert_equal :approve, s.last.job
    assert_equal "main", s.last.branch
    assert_includes s.last.message, "already in sync"

    staged = stage_commit
    @hub.approve(@repo, "main")
    wait_idle
    assert @hub.status(@repo).last.ok?
    assert_equal staged, rev(@upstream, "main")
  end

  def test_jobs_queue_in_order_on_one_actor
    staged = stage_commit
    @hub.fetch(@repo)
    @hub.approve(@repo, "main")
    @hub.fetch(@repo)
    assert_operator @hub.status(@repo).queued, :>=, 1
    wait_idle
    s = @hub.status(@repo)
    assert_equal 0, s.queued
    assert_equal :fetch, s.last.job
    assert s.last.ok?
    assert_equal staged, rev(@upstream, "main")
  end

  def test_repos_have_independent_actors
    other_upstream, = make_upstream("other")
    other = Outbox::Repo.create("other", other_upstream)
    @hub.fetch(other)
    @hub.approve(@repo, "main")
    wait_idle(other)
    wait_idle
    assert @hub.status(other).last.ok?
    refute @hub.status(@repo).last.ok?
    assert_equal %w[main], other.branches.map(&:name)
  end

  def test_remove_stops_the_actor_and_deletes_the_repo
    @hub.fetch(@repo)
    wait_idle
    @hub.remove(@repo)
    refute File.exist?(@repo.path)
    s = @hub.status(@repo)
    refute s.busy?
    assert_nil s.last
  end

  def test_a_dead_actor_is_replaced
    @hub.fetch(@repo)
    wait_idle
    actor = @hub.instance_variable_get(:@actors).fetch("demo")
    actor.send([:stop])
    actor.join

    @hub.fetch(@repo)
    wait_idle
    assert @hub.status(@repo).last.ok?
    refute_same actor, @hub.instance_variable_get(:@actors).fetch("demo")
  end

  def test_shutdown_stops_every_actor
    @hub.fetch(@repo)
    wait_idle
    @hub.shutdown
    assert_empty @hub.instance_variable_get(:@actors)
  end
end
