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

  PASSWORD = "smoke-test-password"

  # Minitest skips teardown when the run is interrupted, so cleanup is also
  # registered at_exit. Each cleanup runs at most once.
  CLEANUPS = []
  at_exit { CLEANUPS.each(&:call) }

  def setup
    @dir = Dir.mktmpdir("outbox-test")
    @data = File.join(@dir, "data")
    @log = File.join(@dir, "server.log")
    dir = @dir
    @cleanup = lambda do
      stop_server
      FileUtils.rm_rf(dir)
    end
    CLEANUPS << @cleanup

    boot_server
    @upstream = make_upstream("demo")
    add_repo("demo", @upstream)
  end

  def teardown
    @cleanup&.call
    CLEANUPS.delete(@cleanup)
  end

  # The port is kept across restarts so upstream URLs that point back at
  # this server stay valid. token: what the server gets as
  # OUTBOX_UPSTREAM_TOKEN; the password, so the server can fetch from its
  # own https endpoint, or nil for none.
  def boot_server(token: PASSWORD)
    @port ||= free_port
    env = { "OUTBOX_DATA" => @data, "OUTBOX_PASSWORD" => PASSWORD, "RACK_ENV" => "test", "RUBYOPT" => "-W0" }
    env["OUTBOX_UPSTREAM_TOKEN"] = token if token
    @server = spawn(
      env,
      "bundle", "exec", "puma", "-b", "tcp://127.0.0.1:#{@port}", "config.ru",
      chdir: ROOT, out: @log, err: @log,
    )
    wait_until("server to start") { port_open? }
  end

  def stop_server
    return unless @server
    Process.kill("TERM", @server)
    Process.wait(@server)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  ensure
    @server = nil
  end

  def test_push_review_approve
    clone = clone_from_outbox("demo")
    write(clone, "README", "hello world\n")
    sh("git", "-C", clone, "commit", "--quiet", "-am", "Say hello to the world")
    sh("git", "-C", clone, "push", "--quiet", "origin", "main")
    pushed = sh("git", "-C", clone, "rev-parse", "HEAD").strip

    refute_equal pushed, upstream_sha(@upstream, "main"), "push must not reach upstream before approval"

    page = get("/repos/demo").body
    assert_includes page, %(class="badge ready")
    assert_includes page, "1 commit to push"

    page = get("/repos/demo/branches/main").body
    assert_includes page, "Say hello to the world"
    assert_includes page, 'data-patch-url="/repos/demo/branches/main.patch"'
    patch = get("/repos/demo/branches/main.patch")
    assert_match(%r{\Atext/plain}, patch["content-type"])
    assert_includes patch.body, "+hello world\n"
    assert_includes patch.body, "-hello\n"
    # The viewer bundle and one of its lazily loaded chunks are served, when
    # built. It is not committed, so a fresh checkout passes without it.
    js = get("/diffs/diffs.js")
    if js.code == "200"
      assert_includes page, '<script type="module" src="/diffs/diffs.js"></script>'
      assert_match(%r{\Atext/javascript}, js["content-type"])
      chunk = js.body[%r{\./(chunk-[A-Z0-9]+\.js)}, 1]
      assert chunk, "diffs.js should import a chunk"
      assert_equal "200", get("/diffs/#{chunk}").code
    else
      assert_includes page, "The diff viewer is not built."
    end

    post_reviewed("/repos/demo/branches/main", "approve")
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
    assert_includes get("/repos/demo/branches/feature/thing.patch").body, "+a thing\n"

    post_reviewed("/repos/demo/branches/feature/thing", "discard")
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
    wait_until("fetch to notice divergence") { get("/repos/demo/branches/main").body.include?(%(class="badge diverged")) }
    page = get("/repos/demo/branches/main").body
    assert_includes page, "Upstream change"
    assert_includes page, "Force approve"

    post_reviewed("/repos/demo/branches/main", "approve")
    wait_until("approve to be refused") { get("/repos/demo").body.include?("approve failed") }
    assert_equal moved, upstream_sha(@upstream, "main"), "non-forced approve must not touch upstream"

    post_reviewed("/repos/demo/branches/main", "approve", "force" => "1")
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

    assert_includes get("/repos/other").body, %(class="badge ready")
    assert_includes get("/repos/demo").body, "in sync"

    post_reviewed("/repos/other/branches/main", "approve")
    wait_until("approve other") { get("/repos/other").body.include?("in sync") }
    assert_equal "hello\n", read_upstream_file(@upstream, "README"), "demo upstream untouched"
  end

  def test_everything_needs_the_password_by_default
    res = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))
    assert_equal "401", res.code
    res = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/demo.git/info/refs?service=git-upload-pack"))
    assert_equal "401", res.code

    _, err, status = Open3.capture3(GIT_ENV, "git", "clone", "--quiet", "http://127.0.0.1:#{@port}/demo.git", File.join(@dir, "noauth"))
    refute status.success?
    assert_match(/401|Authentication|could not read Username/, err)
    refute File.exist?(File.join(@dir, "noauth", "README"))
  end

  # An https upstream that wants credentials: this server's own
  # password-protected git endpoint stands in for GitHub. The fetch only
  # succeeds if git got the token through askpass.
  def test_https_upstream_is_authenticated_with_the_token
    add_repo("mirror", "http://127.0.0.1:#{@port}/demo.git")
    assert_includes get("/repos/mirror").body, "in sync"
    refute_includes get("/").body, "OUTBOX_UPSTREAM_TOKEN"

    stop_server
    boot_server(token: nil)
    assert_includes get("/").body, "<code>OUTBOX_UPSTREAM_TOKEN</code> is not set"
    post("/repos/mirror/fetch")
    wait_until("fetch to fail without a token") { get("/repos/mirror").body.include?("fetch failed") }
    assert_match(/401|Authentication|could not read Username/, get("/repos/mirror").body)
  end

  def test_ssh_upstreams_are_refused_at_push
    clone = clone_from_outbox("_config")
    sh("git", "config", "-f", File.join(clone, "outbox.conf"), "repo.sshy.upstream", "git@github.com:x/y.git")
    sh("git", "-C", clone, "commit", "--quiet", "-am", "Add sshy")
    _, err, status = Open3.capture3(GIT_ENV, "git", "-C", clone, "push", "--quiet", "origin", "main")
    refute status.success?
    assert_includes err, "sshy: upstream git@github.com:x/y.git must be an https URL"
    assert_equal "404", get("/repos/sshy").code
  end

  def test_removing_from_config_leaves_the_staging_repo_alone
    clone = clone_from_outbox("_config")
    sh("git", "config", "-f", File.join(clone, "outbox.conf"), "--remove-section", "repo.demo")
    sh("git", "-C", clone, "commit", "--quiet", "-am", "Remove demo")
    sh("git", "-C", clone, "push", "--quiet", "origin", "main")
    post_reviewed("/repos/_config/branches/main", "approve")
    wait_until("approval") { get("/repos/_config").body.include?("in sync") }
    assert_equal "200", get("/repos/demo").code
    assert File.exist?(File.join(@data, "repos", "demo.git"))
  end

  # A data directory from before the configuration repos existed: staging
  # repos on disk and nothing else. Deleting the two config repos from a
  # current data directory leaves exactly that.
  def test_existing_repos_survive_an_upgrade
    clone = clone_from_outbox("demo")
    write(clone, "README", "staged\n")
    sh("git", "-C", clone, "commit", "--quiet", "-am", "Staged before upgrade")
    sh("git", "-C", clone, "push", "--quiet", "origin", "main")
    staged = sh("git", "-C", clone, "rev-parse", "HEAD").strip

    stop_server
    FileUtils.rm_rf(File.join(@data, "config.git"))
    FileUtils.rm_rf(File.join(@data, "repos", "_config.git"))
    boot_server

    wait_until("_config to be fetched") { get("/repos/_config").body.include?("in sync") }
    assert File.exist?(File.join(@data, "repos", "demo.git"))
    page = get("/repos/demo").body
    assert_includes page, %(class="badge ready")
    assert_includes page, "1 commit to push"
    assert_includes get("/repos/demo/branches/main").body, "Staged before upgrade"
    assert_equal staged, sh("git", "--git-dir", File.join(@data, "repos", "demo.git"), "rev-parse", "refs/heads/main").strip
  end

  def test_config_live_copy_is_not_served
    res = get("/config.git/info/refs?service=git-upload-pack")
    assert_equal "404", res.code
    assert File.exist?(File.join(@data, "config.git", "HEAD"))
  end

  private

  # Git takes the password from the URL; fine for a test, not for real use.
  def outbox_url(name) = "http://outbox:#{PASSWORD}@127.0.0.1:#{@port}/#{name}.git"

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

  # The way anyone adds a repository: push a change to _config, approve it.
  def add_repo(name, upstream)
    wait_until("_config to be fetched and idle") { get("/repos/_config").body.include?("in sync") }
    clone = clone_from_outbox("_config")
    sh("git", "config", "-f", File.join(clone, "outbox.conf"), "repo.#{name}.upstream", upstream)
    sh("git", "-C", clone, "commit", "--quiet", "-am", "Add #{name}")
    sh("git", "-C", clone, "push", "--quiet", "origin", "main")

    page = get("/repos/_config/branches/main").body
    assert_includes page, "Add #{name}"
    assert_includes get("/repos/_config/branches/main.patch").body, "+[repo \"#{name}\"]"
    assert_equal "404", get("/repos/#{name}").code, "nothing exists before approval"

    post_reviewed("/repos/_config/branches/main", "approve")
    wait_until("initial fetch of #{name}") do
      res = get("/repos/#{name}")
      flunk "initial fetch of #{name} failed:\n#{failure_message(res.body)}" if res.body.include?("fetch failed")
      res.code == "200" && res.body.include?("fetched upstream")
    end
  end

  # The failed job's message, as the repo page shows it.
  def failure_message(page) = page[%r{<pre[^>]*>(.*?)</pre>}m, 1].to_s.strip

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

  def get(path)
    req = Net::HTTP::Get.new(path)
    req.basic_auth("outbox", PASSWORD)
    res = Net::HTTP.start("127.0.0.1", @port) { |http| http.request(req) }
    res.body.force_encoding(Encoding::UTF_8)
    res
  end

  def post(path, form = {})
    req = Net::HTTP::Post.new(path)
    req.basic_auth("outbox", PASSWORD)
    req.set_form_data(form)
    Net::HTTP.start("127.0.0.1", @port) { |http| http.request(req) }
  end

  # Approve or discard the way the buttons do, carrying the staged sha.
  def post_reviewed(branch_path, action, form = {})
    name = branch_path[%r{\A/repos/([^/]+)/}, 1]
    branch = branch_path.delete_prefix("/repos/#{name}/branches/")
    staged = sh("git", "--git-dir", File.join(@data, "repos", "#{name}.git"), "rev-parse", "refs/heads/#{branch}").strip
    post("#{branch_path}/#{action}", form.merge("expected" => staged))
  end

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
