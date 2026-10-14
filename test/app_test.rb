# frozen_string_literal: true

require_relative "test_helper"
require "rack"

# The Sinatra pages, driven through Rack directly (no server). The Hub is
# real, so approve and discard go through actors.
class AppTest < OutboxTest::RepoCase
  def setup
    super
    Outbox.hub = Outbox::Hub.new
    @request = Rack::MockRequest.new(Outbox::App)
  end

  def teardown
    Outbox.hub.shutdown
    Outbox.hub = nil
    super
  end

  def get(path)
    res = @request.get(path)
    assert_equal 200, res.status, "GET #{path}: #{res.body[0, 300]}"
    res.body
  end

  def test_installable_as_an_app
    manifest = JSON.parse(get("/manifest.webmanifest"))
    assert_equal "standalone", manifest["display"]
    manifest["icons"].each { |icon| get(icon["src"]) }
    assert_includes get("/sw.js"), "fetch"
    assert_includes get("/offline"), "offline"
    assert_includes get("/"), 'rel="manifest" href="/manifest.webmanifest" crossorigin="use-credentials"'
    assert_equal 404, @request.get("/pwa/sw.js").status
  end

  def test_index_lists_repos_and_pending_work
    stage_commit
    body = get("/")
    assert_includes body, ">demo<"
    assert_includes body, "ready"
    assert_operator body.index(">demo<"), :<, body.index(">_config<"), "pending repos sort first"
    assert_includes body, ">_config<"
    assert_includes body, "http://example.org/_config.git"
    assert_includes body, "Adding a repository"
    refute_includes body, 'action="/repos"', "repositories are added through _config, not a form"
    assert_equal 404, @request.post("/repos", params: { "name" => "x", "upstream" => "y" }).status
  end

  def test_fetch_all_queues_a_fetch_on_every_repo
    sha = upstream_commit
    assert_includes get("/"), 'action="/fetch"'

    res = @request.post("/fetch")
    assert_equal 303, res.status
    assert_equal "http://example.org/", res["location"]

    repos = Outbox::Repo.all
    assert_equal %w[_config demo], repos.map(&:name)
    repos.each do |repo|
      wait_until("#{repo.name} to finish fetching") { !Outbox.hub.status(repo).busy? }
      assert_equal :fetch, Outbox.hub.status(repo).last.job
      assert Outbox.hub.status(repo).last.ok?, Outbox.hub.status(repo).last.message
    end
    assert_equal sha, rev(@repo.path, "refs/heads/main")
  end

  def test_index_reports_configuration_problems
    Outbox::Config.edit(message: "Bad entry") do |f|
      File.write(f, "[repo \"-bad\"]\n\tupstream = x\n[repo \"_config\"]\n\tupstream = y\n[repo \"ok\"]\n\tupstream =\n")
    end
    body = get("/")
    assert_includes body, "&quot;-bad&quot; is not a valid repository name"
    assert_includes body, "_config is reserved"
    assert_includes body, "ok has no upstream"
  end

  def test_index_leaves_upstream_and_clone_url_to_the_repo_page
    body = get("/")
    refute_includes body, @upstream
    refute_includes body, "Clone URL"
  end

  def test_repo_page_shows_branches
    body = get("/repos/demo")
    assert_includes body, "in sync"
    assert_includes body, @upstream
    assert_includes body, "Fetch upstream"
    refute_includes body, "Remove"
    assert_equal 404, @request.get("/repos/nope").status
    assert_equal 404, @request.post("/repos/demo/destroy").status
  end

  def test_config_repo_page
    Outbox::Config.staging.fetch!
    body = get("/repos/_config")
    assert_includes body, "the outbox's own configuration"
    assert_includes body, "in sync"
  end

  # Only an https upstream needs the token; the test repos are local paths.
  def test_index_warns_when_an_https_upstream_has_no_token
    saved = ENV.delete("OUTBOX_UPSTREAM_TOKEN")
    refute_includes get("/"), "OUTBOX_UPSTREAM_TOKEN"
    Outbox::Repo.create("gh", "https://github.com/x/y.git")
    assert_includes get("/"), "OUTBOX_UPSTREAM_TOKEN"
    ENV["OUTBOX_UPSTREAM_TOKEN"] = "ghp_test"
    refute_includes get("/"), "OUTBOX_UPSTREAM_TOKEN"
  ensure
    saved ? ENV["OUTBOX_UPSTREAM_TOKEN"] = saved : ENV.delete("OUTBOX_UPSTREAM_TOKEN")
  end

  def test_config_change_is_reviewed_like_any_other
    config = Outbox::Config.staging
    config.fetch!
    work = File.join(@dir, "config-work")
    git("clone", "--quiet", config.path, work)
    git("config", "-f", File.join(work, "outbox.conf"), "repo.demo.upstream", @upstream, chdir: work)
    git("commit", "--quiet", "-am", "Add demo", chdir: work)
    push(work, "main")

    body = get("/repos/_config/branches/main")
    assert_includes body, "Add demo"
    assert_includes body, '<a href="#f0">outbox.conf</a>'
    assert_includes get("/repos/_config/branches/main.patch"), "+[repo \"demo\"]"
  end

  def test_branch_page_renders_summary_and_diff_placeholders
    stage_commit("lib/a.rb", "x = 1\ny = 2\n", "Add a")
    body = get("/repos/demo/branches/main")

    assert_includes body, "Add a"
    assert_includes body, "Files changed (1)"
    assert_includes body, '<a href="#f0">lib/a.rb</a>'
    assert_includes body, 'class="badge added"'
    assert_includes body, "+2</span>"
    assert_includes body, "1 file changed"
    # The diff body is drawn in the browser from the raw patch.
    assert_includes body, 'data-patch-url="/repos/demo/branches/main.patch"'
    assert_includes body, '<details class="file" id="f0" open>'
    assert_match %r{<div class="diff" data-diff-file="lib/a.rb" data-new-blob="[0-9a-f]{40}">}, body
    refute_includes body, "data-old-blob"
    assert_includes body, 'data-blob-url="/repos/demo/blobs"'
    refute_includes body, "x = 1"
  end

  def test_blob_route_serves_file_contents_by_blob_id
    stage_commit("lib/a.rb", "x = 1\ny = 2\n", "Add a")
    id = get("/repos/demo/branches/main")[/data-new-blob="([0-9a-f]{40})"/, 1]

    res = @request.get("/repos/demo/blobs/#{id}")
    assert_equal 200, res.status
    assert_equal "x = 1\ny = 2\n", res.body
    assert_equal 404, @request.get("/repos/demo/blobs/#{"0" * 40}").status
    assert_equal 404, @request.get("/repos/demo/blobs/HEAD").status
  end

  def test_raw_patch_for_branch_and_commit
    first = stage_commit("a.txt", "a\n", "First")
    stage_commit("b.txt", "b\n", "Second")

    res = @request.get("/repos/demo/branches/main.patch")
    assert_equal 200, res.status
    assert_equal "text/plain;charset=utf-8", res["content-type"]
    assert_includes res.body, "diff --git a/a.txt b/a.txt"
    assert_includes res.body, "diff --git a/b.txt b/b.txt"
    assert_includes res.body, "+a\n"

    res = @request.get("/repos/demo/branches/main/commits/#{first}.patch")
    assert_equal 200, res.status
    assert_includes res.body, "+a\n"
    refute_includes res.body, "b.txt", "only this commit's changes"

    assert_equal 404, @request.get("/repos/demo/branches/nope.patch").status
    assert_equal 404, @request.get("/repos/demo/branches/main/commits/#{rev(@upstream, "main")}.patch").status
  end

  def test_raw_patch_with_slash_in_branch_name
    git("checkout", "--quiet", "-b", "feature/x", chdir: @stage)
    sha = stage_commit("x.txt", "x\n", "Add x", branch: "feature/x")
    assert_includes get("/repos/demo/branches/feature/x.patch"), "+x\n"
    assert_includes get("/repos/demo/branches/feature/x/commits/#{sha}.patch"), "+x\n"
    assert_includes get("/repos/demo/branches/feature/x"), 'data-patch-url="/repos/demo/branches/feature/x.patch"'
  end

  def test_synced_branch_has_an_empty_patch
    res = @request.get("/repos/demo/branches/main.patch")
    assert_equal 200, res.status
    assert_equal "", res.body
  end

  # public/diffs is build output and not committed, so either state is valid.
  def test_bundle_is_served_or_its_absence_explained
    stage_commit("a.txt", "a\n", "A")
    body = get("/repos/demo/branches/main")
    res = @request.get("/diffs/diffs.js")
    if res.status == 200
      assert_match(%r{\Atext/javascript}, res["content-type"])
      assert_includes body, '<script type="module" src="/diffs/diffs.js"></script>'
      refute_includes body, "The diff viewer is not built."
    else
      assert_includes body, "The diff viewer is not built."
      refute_includes body, "/diffs/diffs.js\""
    end
  end

  def test_branch_page_links_each_commit
    first = stage_commit("a.txt", "a\n", "First")
    second = stage_commit("b.txt", "b\n", "Second")
    body = get("/repos/demo/branches/main")
    assert_includes body, "/repos/demo/branches/main/commits/#{first}"
    assert_includes body, "/repos/demo/branches/main/commits/#{second}"
  end

  def test_commit_page_shows_one_commit_with_navigation
    first = stage_commit("a.txt", "a\n", "First")
    File.write(File.join(@stage, "b.txt"), "b\n")
    git("add", "b.txt", chdir: @stage)
    git("commit", "--quiet", "-m", "Second\n\nLonger explanation here.", chdir: @stage)
    second = rev(@stage, "HEAD")
    push(@stage, "main")

    body = get("/repos/demo/branches/main/commits/#{first}")
    assert_includes body, "commit 1 of 2"
    assert_includes body, "<h1>First</h1>"
    assert_includes body, "a.txt"
    refute_includes body, "b.txt", "only this commit's changes"
    assert_includes body, "← oldest"
    assert_includes body, "newer: Second"
    assert_includes body, "/commits/#{second}"

    body = get("/repos/demo/branches/main/commits/#{second}")
    assert_includes body, "commit 2 of 2"
    assert_includes body, "Longer explanation here."
    assert_includes body, "b.txt"
    refute_includes body, '<a href="#f0">a.txt</a>'
    assert_includes body, "older: First"
    assert_includes body, "newest →"
  end

  def test_commit_bodies_are_shown_in_full_on_the_branch_page
    File.write(File.join(@stage, "a.txt"), "a\n")
    git("add", "a.txt", chdir: @stage)
    git("commit", "--quiet", "-m", "Tidy up\n\nAlso rewrites auth.\nAnd disables the tests.", chdir: @stage)
    push(@stage, "main")

    body = get("/repos/demo/branches/main")
    assert_match(%r{<details class="more">\s*<summary class="ellipsis" title="Show full commit message \(2 more lines\)">…</summary>\s*<pre class="message">Also rewrites auth\.\nAnd disables the tests\.</pre>}m, body)
    assert_includes body, "&lt;test@example.com&gt;"
  end

  def test_invisible_characters_are_made_visible
    File.write(File.join(@stage, "a.txt"), "safe​hidden\n")
    git("add", "a.txt", chdir: @stage)
    git("commit", "--quiet", "-m", "Fix‮ gnihtemos", chdir: @stage)
    push(@stage, "main")

    body = get("/repos/demo/branches/main")
    assert_includes body, '<span class="invis" title="hidden character">U+202E</span>'
    refute_includes body, "‮"
    # Diff bodies are not in the page; the file is badged instead.
    assert_includes body, '<a href="#f0">a.txt</a>'
    assert_includes body, '<span class="badge hidden">hidden characters</span>'
    assert_includes body, 'title="Zero-width, bidi or control characters on lines +1">hidden characters on 1 line</span>'
    refute_includes body, "​"
  end

  def test_commit_page_refuses_commits_outside_the_staged_range
    stage_commit
    upstream_sha = rev(@upstream, "main")
    res = @request.get("/repos/demo/branches/main/commits/#{upstream_sha}")
    assert_equal 404, res.status
    assert_equal 404, @request.get("/repos/demo/branches/main/commits/notasha").status
  end

  def test_commit_page_for_root_commit_on_empty_upstream
    bare = File.join(@dir, "empty.git")
    git("init", "--quiet", "--bare", "-b", "main", bare)
    repo = Outbox::Repo.create("empty", bare)
    repo.fetch!
    work = File.join(@dir, "empty-work")
    git("init", "--quiet", "-b", "main", work)
    git("remote", "add", "origin", repo.path, chdir: work)
    sha = commit(work, "f.txt", "first\n", "Root")
    push(work, "main")

    body = get("/repos/empty/branches/main/commits/#{sha}")
    assert_includes body, "root commit"
    assert_includes body, '<a href="#f0">f.txt</a>'
    assert_includes get("/repos/empty/branches/main/commits/#{sha}.patch"), "+first\n"
  end

  def test_branch_with_slash_in_commit_route
    git("checkout", "--quiet", "-b", "feature/x", chdir: @stage)
    sha = stage_commit("x.txt", "x\n", "Add x", branch: "feature/x")
    body = get("/repos/demo/branches/feature/x/commits/#{sha}")
    assert_includes body, "commit 1 of 1"
    assert_includes body, "<h1>Add x</h1>"
  end

  def test_approve_and_discard_enqueue_and_redirect
    staged = stage_commit
    res = @request.post("/repos/demo/branches/main/approve", params: { expected: staged })
    assert_equal 303, res.status
    assert_equal "http://example.org/repos/demo", res["location"]
    wait_until("approve") { !Outbox.hub.status(@repo).busy? }
    assert_equal staged, rev(@upstream, "main")

    stage_commit("z.txt", "z\n", "Z")
    res = @request.post("/repos/demo/branches/main/discard", params: { expected: rev(@stage, "main") })
    assert_equal 303, res.status
    wait_until("discard") { !Outbox.hub.status(@repo).busy? }
    assert_equal :synced, status_of
  end

  def test_approve_and_discard_require_expected_sha
    staged = stage_commit
    %w[approve discard].each do |action|
      res = @request.post("/repos/demo/branches/main/#{action}")
      assert_equal 422, res.status
      assert_includes res.body, "missing expected"
    end
    refute_equal staged, rev(@upstream, "main")
    assert_equal :ready, status_of
  end
end
