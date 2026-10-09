# frozen_string_literal: true

# End-to-end: boots the real server on a random port with its data in a temp
# dir, creates local bare "upstream" repos, pushes through the outbox over
# HTTP, drives the UI, and checks the upstreams. Run with:
#
#   bundle exec ruby test/smoke_test.rb
#
require "minitest/autorun"
require "open3"
require "tmpdir"
require "socket"
require "net/http"
require "fileutils"

ROOT = File.expand_path("..", __dir__)

class SmokeTest < Minitest::Test
  GIT_ENV = {
    "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
    "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com",
    "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
    "GIT_TERMINAL_PROMPT" => "0",
  }.freeze

  # Minitest skips teardown when the run is interrupted, so cleanup is also
  # registered at_exit. Each cleanup runs at most once.
  CLEANUPS = []
  at_exit { CLEANUPS.each(&:call) }

  def setup
    @dir = Dir.mktmpdir("outbox-test")
    @port = free_port
    @log = File.join(@dir, "server.log")
    @server = spawn(
      { "OUTBOX_DATA" => File.join(@dir, "data"), "RACK_ENV" => "test", "RUBYOPT" => "-W0" },
      "bundle", "exec", "puma", "-b", "tcp://127.0.0.1:#{@port}", "config.ru",
      chdir: ROOT, out: @log, err: @log,
    )
    dir = @dir
    server = @server
    done = false
    @cleanup = lambda do
      next if done
      done = true
      begin
        Process.kill("TERM", server)
        Process.wait(server)
      rescue Errno::ESRCH, Errno::ECHILD
        # already gone
      end
      FileUtils.rm_rf(dir)
    end
    CLEANUPS << @cleanup

    wait_until("server to start") { port_open? }
    @upstream = make_upstream("demo")
    add_repo("demo", @upstream)
  end

  def teardown
    @cleanup&.call
    CLEANUPS.delete(@cleanup)
  end

  def test_push_review_approve
    clone = clone_from_outbox("demo")
    write(clone, "README", "hello world\n")
    sh("git", "-C", clone, "commit", "--quiet", "-am", "Say hello to the world")
    sh("git", "-C", clone, "push", "--quiet", "origin", "main")
    pushed = sh("git", "-C", clone, "rev-parse", "HEAD").strip

    refute_equal pushed, upstream_sha(@upstream, "main"), "push must not reach upstream before approval"

    page = get("/repos/demo").body
    assert_includes page, "ready"
    assert_includes page, "1 commit to push"

    page = get("/repos/demo/branches/main").body
    assert_includes page, "Say hello to the world"
    assert_includes page, '<span class="mark">+</span>hello world'
    assert_includes page, '<span class="mark">−</span>hello'

    post("/repos/demo/branches/main/approve")
    wait_until("approve to reach upstream") { upstream_sha(@upstream, "main") == pushed }
    assert_includes get("/repos/demo").body, "in sync"
  end

  def test_new_branch_with_slash_and_discard
    clone = clone_from_outbox("demo")
    sh("git", "-C", clone, "checkout", "--quiet", "-b", "feature/thing")
    write(clone, "thing.txt", "a thing\n")
    sh("git", "-C", clone, "add", ".")
    sh("git", "-C", clone, "commit", "--quiet", "-m", "Add a thing")
    sh("git", "-C", clone, "push", "--quiet", "origin", "feature/thing")

    page = get("/repos/demo/branches/feature/thing").body
    assert_includes page, "new branch"
    assert_includes page, "Add a thing"
    assert_includes page, '<span class="mark">+</span>a thing'

    post("/repos/demo/branches/feature/thing/discard")
    # The branch row goes away; the "discarded ... feature/thing" result line stays.
    wait_until("discard") { !get("/repos/demo").body.include?("/branches/feature/thing") }
    assert_equal "", sh("git", "--git-dir", @upstream, "branch", "--list", "feature/thing").strip
  end

  def test_diverged_requires_force
    clone = clone_from_outbox("demo")
    write(clone, "a.txt", "staged\n")
    sh("git", "-C", clone, "add", ".")
    sh("git", "-C", clone, "commit", "--quiet", "-m", "Staged change")
    sh("git", "-C", clone, "push", "--quiet", "origin", "main")
    staged = sh("git", "-C", clone, "rev-parse", "HEAD").strip

    # Meanwhile upstream moves on its own.
    commit_to_upstream(@upstream, "b.txt", "upstream\n", "Upstream change")
    moved = upstream_sha(@upstream, "main")

    post("/repos/demo/fetch")
    wait_until("fetch to notice divergence") { get("/repos/demo/branches/main").body.include?("diverged") }
    page = get("/repos/demo/branches/main").body
    assert_includes page, "Upstream change"
    assert_includes page, "Force approve"

    post("/repos/demo/branches/main/approve")
    wait_until("approve to be refused") { get("/repos/demo").body.include?("approve failed") }
    assert_equal moved, upstream_sha(@upstream, "main"), "non-forced approve must not touch upstream"

    post("/repos/demo/branches/main/approve", "force" => "1")
    wait_until("forced approve") { upstream_sha(@upstream, "main") == staged }
  end

  def test_fetch_follows_upstream_when_nothing_staged
    commit_to_upstream(@upstream, "c.txt", "more\n", "More upstream")
    post("/repos/demo/fetch")
    wait_until("fetch") { get("/repos/demo").body.include?("fetched upstream") }

    clone = clone_from_outbox("demo")
    assert File.exist?(File.join(clone, "c.txt"))
    assert_includes get("/repos/demo").body, "in sync"
  end

  def test_repos_are_independent
    other = make_upstream("other")
    add_repo("other", other)

    clone = clone_from_outbox("other")
    write(clone, "README", "other change\n")
    sh("git", "-C", clone, "commit", "--quiet", "-am", "Change other")
    sh("git", "-C", clone, "push", "--quiet", "origin", "main")

    assert_includes get("/repos/other").body, "ready"
    assert_includes get("/repos/demo").body, "in sync"

    post("/repos/other/branches/main/approve")
    wait_until("approve other") { get("/repos/other").body.include?("in sync") }
    assert_equal "hello\n", read_upstream_file(@upstream, "README"), "demo upstream untouched"
  end

  def test_deploy_key_is_per_repo
    page = get("/repos/demo").body
    assert_includes page, "ssh-ed25519 "
    assert_includes page, "outbox deploy key: demo"

    key = File.join(@dir, "data", "repos", "demo.git", "deploy_key")
    assert File.exist?(key)
    assert_equal 0o600, File.stat(key).mode & 0o777
  end

  private

  def outbox_url(name) = "http://127.0.0.1:#{@port}/#{name}.git"

  def make_upstream(name)
    bare = File.join(@dir, "#{name}-upstream.git")
    work = File.join(@dir, "#{name}-work")
    sh("git", "init", "--quiet", "--bare", "-b", "main", bare)
    sh("git", "init", "--quiet", "-b", "main", work)
    write(work, "README", "hello\n")
    sh("git", "-C", work, "add", ".")
    sh("git", "-C", work, "commit", "--quiet", "-m", "initial")
    sh("git", "-C", work, "push", "--quiet", bare, "main")
    bare
  end

  def commit_to_upstream(bare, file, content, message)
    work = bare.sub(/-upstream\.git\z/, "-work")
    sh("git", "-C", work, "pull", "--quiet", bare, "main")
    write(work, file, content)
    sh("git", "-C", work, "add", ".")
    sh("git", "-C", work, "commit", "--quiet", "-m", message)
    sh("git", "-C", work, "push", "--quiet", bare, "main")
  end

  def add_repo(name, upstream)
    res = post("/repos", "name" => name, "upstream" => upstream)
    assert_includes %w[302 303], res.code, res.body
    wait_until("initial fetch of #{name}") { get("/repos/#{name}").body.include?("fetched upstream") }
  end

  def clone_from_outbox(name)
    clone = File.join(@dir, "clone-#{name}-#{rand(1_000_000)}")
    sh("git", "clone", "--quiet", outbox_url(name), clone)
    clone
  end

  def upstream_sha(bare, branch) = sh("git", "--git-dir", bare, "rev-parse", "refs/heads/#{branch}").strip

  def read_upstream_file(bare, file) = sh("git", "--git-dir", bare, "show", "main:#{file}")

  def write(dir, name, content) = File.write(File.join(dir, name), content)

  def sh(*cmd)
    out, err, status = Open3.capture3(GIT_ENV, *cmd)
    flunk "#{cmd.join(" ")} failed:\n#{err}" unless status.success?
    out
  end

  def get(path) = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}#{path}"))

  def post(path, form = {}) = Net::HTTP.post_form(URI("http://127.0.0.1:#{@port}#{path}"), form)

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1]
  ensure
    s&.close
  end

  def port_open?
    TCPSocket.new("127.0.0.1", @port).close
    true
  rescue Errno::ECONNREFUSED
    false
  end

  def wait_until(what, timeout: 20)
    deadline = Time.now + timeout
    until yield
      if Time.now > deadline
        log = File.exist?(@log) ? File.read(@log) : ""
        flunk "timed out waiting for #{what}\n--- server log ---\n#{log}"
      end
      sleep 0.1
    end
  end
end
