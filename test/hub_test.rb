# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class HubTest < OutboxTest::RepoCase
  def setup
    super
    @hub = Outbox::Hub.new(push_check: 0.05)
  end

  def teardown
    @release&.close
    @hub.shutdown
    @stub&.kill
    @stub_server&.close
    super
  end

  def wait_idle(repo = @repo)
    wait_until("#{repo.name} to go idle") { !@hub.status(repo).busy? }
  end

  # Every push to a staging repo is followed by a fetch. Wait for it, so
  # that it does not land in the middle of what the test does next.
  def push(work, *refspecs, **opts)
    url = File.realpath(git("remote", "get-url", "origin", chdir: work).strip)
    repo = Outbox::Repo.all.find { |r| File.realpath(r.path) == url }
    return super unless repo

    before = @hub.status(repo).fetched_at
    super
    wait_until("the fetch after a push to #{repo.name}") do
      s = @hub.status(repo)
      s.fetched_at != before && !s.busy?
    end
  end

  # An http server that takes requests and answers none (404) until
  # released, so that a fetch from it stays running for as long as a test
  # needs. Returns its url.
  def stalled_remote
    @release = Thread::Queue.new
    server = @stub_server = TCPServer.new("127.0.0.1", 0)
    @stub = Thread.new do
      loop do
        Thread.new(server.accept) do |c|
          loop { line = c.gets; break if line.nil? || line.strip.empty? }
          @release.pop
          c.write "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        rescue IOError, SystemCallError
          # git gave up
        ensure
          c.close
        end
      end
    end
    "http://127.0.0.1:#{server.addr[1]}/stalled.git"
  end

  def release_remote = @release.close

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

  def test_fetch_sets_head_on_a_fresh_repo
    repo = Outbox::Repo.create("fresh", @upstream)
    refute ref_exists?(repo.path, "HEAD")
    @hub.fetch(repo)
    wait_idle(repo)
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

  def test_dismiss_clears_a_failed_result_only
    @hub.approve(@repo, "nope")
    wait_idle
    refute @hub.status(@repo).last.ok?
    @hub.dismiss(@repo)
    assert_nil @hub.status(@repo).last

    @hub.fetch(@repo)
    wait_idle
    @hub.dismiss(@repo)
    assert @hub.status(@repo).last.ok?, "a success is not dismissed"
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

  def test_a_push_is_followed_by_a_fetch
    up = upstream_commit
    refute_equal up, rev(@repo.path, "refs/remotes/upstream/main"), "the outbox has not seen it yet"
    stage_commit(branch: "main:feature")
    assert_equal up, rev(@repo.path, "refs/remotes/upstream/main")
    assert_equal up, rev(@repo.path, "refs/heads/main"), "and main, with nothing staged, follows it"
    s = @hub.status(@repo)
    assert_equal :fetch, s.last.job
    assert s.last.ok?
    assert_equal 0, s.fetches_queued
  end

  def test_a_fetch_queued_and_not_started_serves_every_push
    @repo.git("config", "remote.upstream.url", stalled_remote)
    @hub.fetch(@repo)
    wait_until("the fetch to start") { @hub.status(@repo).job == :fetch }

    3.times { @hub.send(:noticed, "demo", true) }
    s = @hub.status(@repo)
    assert_equal 1, s.fetches_queued, "one fetch waits behind the running one, for all three pushes"
    assert_equal 2, s.queued
    refute_includes @hub.fetch_stale(Time.now + Outbox::Hub::FETCH_EVERY).map(&:name), "demo"

    release_remote
    wait_idle
    s = @hub.status(@repo)
    assert_equal 0, s.fetches_queued
    refute s.last.ok?, "the stub only ever says 404"
    assert_equal :fetch, s.last.job
  end

  def test_a_repo_appearing_is_not_fetched_for_it
    other_upstream, = make_upstream("other")
    other = Outbox::Repo.create("other", other_upstream)
    client = subscribe
    @hub.send(:noticed, "other", false)
    read_until(client, /event: refs\ndata: other\n\n/)
    refute @hub.status(other).busy?
    assert_nil @hub.status(other).last
  end

  def test_fetch_stale_fetches_what_was_fetched_long_enough_ago
    every = Outbox::Hub::FETCH_EVERY
    assert_empty @hub.fetch_stale, "a repo this hub never fetched counts from its start"
    assert_equal %w[_config demo], @hub.fetch_stale(Time.now + every).map(&:name)
    wait_idle
    wait_idle(Outbox::Config.staging)

    fetched_at = @hub.status(@repo).fetched_at
    assert_kind_of Time, fetched_at
    assert_empty @hub.fetch_stale(fetched_at + every - 1).map(&:name) & ["demo"]
    assert_includes @hub.fetch_stale(fetched_at + every).map(&:name), "demo"
    assert_empty @hub.fetch_stale(fetched_at + every).map(&:name), "not while that one is queued or running"
    wait_idle
    wait_idle(Outbox::Config.staging)
  end

  def test_the_timer_fetches_on_its_own
    @hub.shutdown
    @hub = Outbox::Hub.new(fetch_every: 0, fetch_check: 0.05)
    up = upstream_commit
    wait_until("the timer to fetch") { rev(@repo.path, "refs/heads/main") == up }
  end

  def test_a_fetch_that_works_leaves_another_jobs_failure_showing
    @hub.approve(@repo, "main")
    wait_idle
    @hub.fetch(@repo)
    wait_idle
    s = @hub.status(@repo)
    assert_equal :approve, s.last.job
    refute s.last.ok?
    assert s.fetched_at
  end

  def test_a_fetch_that_works_clears_a_failed_fetch
    url = @repo.git("config", "remote.upstream.url").strip
    @repo.git("config", "remote.upstream.url", File.join(@dir, "nowhere.git"))
    @hub.fetch(@repo)
    wait_idle
    refute @hub.status(@repo).last.ok?

    @repo.git("config", "remote.upstream.url", url)
    @hub.fetch(@repo)
    wait_idle
    assert @hub.status(@repo).last.ok?
  end

  def test_fetch_all_skips_repos_that_are_already_busy
    other_upstream, = make_upstream("other")
    other = Outbox::Repo.create("other", other_upstream)
    @hub.fetch(@repo)
    queued_before = @hub.status(@repo).queued

    fetched = @hub.fetch_all
    assert_includes fetched.map(&:name), "other"
    refute_includes fetched.map(&:name), "demo", "demo already has a fetch in flight"
    assert_equal queued_before, @hub.status(@repo).queued

    wait_idle(other)
    wait_idle
    assert @hub.status(other).last.ok?
    assert_equal :fetch, @hub.status(other).last.job
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

  def test_start_all_applies_the_configuration_and_fetches_everything
    other_upstream, = make_upstream("other")
    Outbox::Config.add("other", other_upstream)
    sha = upstream_commit
    # demo was created directly and is not in the configuration.
    @hub.start_all
    other = Outbox::Repo.find!("other")
    wait_idle(other)
    wait_idle(Outbox::Config.staging)
    wait_idle
    assert File.exist?(@repo.path), "a repo missing from the configuration is left alone"
    assert_equal %w[_config demo other], Outbox::Repo.all.map(&:name)
    assert_equal %w[main], other.branches.map(&:name)
    assert_equal sha, rev(@repo.path, "refs/heads/main"), "and fetched like the rest"
    assert @hub.status(other).last.ok?
    assert @hub.status(@repo).last.ok?
    assert @hub.status(Outbox::Config.staging).last.ok?
  end

  def test_approving_a_configuration_change_applies_it
    Outbox::Config.add("demo", @upstream)
    @hub.start_all
    config = Outbox::Config.staging
    wait_idle(config)
    wait_idle
    assert_equal "refs/heads/main", config.git("symbolic-ref", "HEAD").strip

    other_upstream, = make_upstream("other")
    work = File.join(@dir, "config-work")
    git("clone", "--quiet", config.path, work)
    git("config", "-f", File.join(work, "outbox.conf"), "repo.other.upstream", other_upstream, chdir: work)
    git("config", "-f", File.join(work, "outbox.conf"), "--remove-section", "repo.demo", chdir: work)
    git("commit", "--quiet", "-am", "Swap demo for other", chdir: work)
    push(work, "main")

    assert_equal :ready, config.branch("main").status
    assert_includes config.diff("main").text, "+[repo \"other\"]"
    assert_nil Outbox::Repo.find("other"), "nothing happens before approval"

    @hub.approve(config, "main")
    wait_idle(config)
    wait_until("other to be created") { Outbox::Repo.find("other") }
    other = Outbox::Repo.find!("other")
    wait_idle(other)
    assert @hub.status(config).last.ok?, @hub.status(config).last.message
    assert_equal %w[main], other.branches.map(&:name)
    assert_equal ["other"], Outbox::Config.load.repos.keys
    assert File.exist?(@repo.path), "dropping an entry does not delete the staging repo"
    assert_equal %w[_config demo other], Outbox::Repo.all.map(&:name)
  end

  def test_a_failed_apply_is_reported_on_the_config_repo
    @hub.start_all
    config = Outbox::Config.staging
    wait_idle(config)
    wait_idle

    work = File.join(@dir, "config-work")
    git("clone", "--quiet", config.path, work)
    File.write(File.join(work, "outbox.conf"), "[repo \"bad\"]\n\tupstream = #{@upstream}\n")
    git("commit", "--quiet", "-am", "Break it", chdir: work)
    push(work, "main")
    # A directory that is not a repo, where the staging repo would go, is
    # one way apply! can fail: git refuses to set up its remotes.
    FileUtils.mkdir_p(File.join(Outbox::Repo.repos_dir, "bad.git"))

    @hub.approve(config, "main")
    wait_idle(config)
    wait_until("apply to fail") { @hub.status(config).last&.job == :apply }
    s = @hub.status(config).last
    refute s.ok?
    assert_match(/not a git repository/, s.message)
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

  # The browser's end of a stream, once its hello has arrived.
  def subscribe
    server, client = UNIXSocket.pair
    @hub.subscribe(server)
    read_until(client, /event: hello\n.*\n\n/)
    client
  end

  def read_until(client, pattern, timeout: 5)
    buffer = +""
    deadline = Time.now + timeout
    until buffer.match?(pattern)
      left = deadline - Time.now
      flunk "timed out waiting for #{pattern.inspect}; got #{buffer.inspect}" if left <= 0
      next unless IO.select([client], nil, nil, left)
      chunk = client.read_nonblock(4096, exception: false)
      flunk "stream closed; got #{buffer.inspect}" if chunk.nil?
      buffer << chunk unless chunk == :wait_readable
    end
    buffer
  end

  def test_a_job_is_announced_as_it_runs_and_when_it_finishes
    client = subscribe
    @hub.fetch(@repo)
    out = read_until(client, /event: refs\ndata: demo\n\n/)
    assert_operator out.index("event: status\ndata: demo\n\n"), :<, out.index("event: refs\ndata: demo\n\n")
    wait_idle
  end

  def test_a_push_is_announced
    client = subscribe
    stage_commit
    read_until(client, /event: refs\ndata: demo\n\n/)
  end

  def test_shutdown_stops_the_timer
    @hub.shutdown
    refute @hub.instance_variable_get(:@timer).alive?
    @hub = Outbox::Hub.new
  end

  def test_a_dismissal_is_announced
    @hub.approve(@repo, "nope", expected: "")
    wait_idle
    client = subscribe
    @hub.dismiss(@repo)
    read_until(client, /event: status\ndata: demo\n\n/)
  end

  def test_seq_counts_what_has_gone_out
    before = @hub.seq
    @hub.dismiss(@repo)
    wait_until("the dismissal to go out") { @hub.seq == before + 1 }
  end

  def test_shutdown_stops_every_actor
    @hub.fetch(@repo)
    wait_idle
    @hub.shutdown
    assert_empty @hub.instance_variable_get(:@actors)
  end
end
