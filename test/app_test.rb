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

  def test_index_lists_repos_and_pending_work
    stage_commit
    body = get("/")
    assert_includes body, ">demo<"
    assert_includes body, "ready"
    assert_includes body, "http://example.org/demo.git"
  end

  def test_repo_page_shows_branches_and_deploy_key
    body = get("/repos/demo")
    assert_includes body, "in sync"
    assert_includes body, "ssh-ed25519 "
    assert_includes body, "Fetch upstream"
    assert_equal 404, @request.get("/repos/nope").status
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
    assert_includes body, '<div class="diff" data-diff-file="lib/a.rb">'
    refute_includes body, "x = 1"
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
    res = @request.post("/repos/demo/branches/main/approve")
    assert_equal 303, res.status
    assert_equal "http://example.org/repos/demo", res["location"]
    wait_until("approve") { !Outbox.hub.status(@repo).busy? }
    assert_equal staged, rev(@upstream, "main")

    stage_commit("z.txt", "z\n", "Z")
    res = @request.post("/repos/demo/branches/main/discard")
    assert_equal 303, res.status
    wait_until("discard") { !Outbox.hub.status(@repo).busy? }
    assert_equal :synced, status_of
  end

  def test_add_repo_form
    other, = make_upstream("other")
    res = @request.post("/repos", params: { "name" => "other", "upstream" => other })
    assert_equal 303, res.status
    assert_equal "http://example.org/repos/other", res["location"]
    wait_until("fetch") { !Outbox.hub.status(Outbox::Repo.find("other")).busy? }
    assert_includes get("/repos/other"), "in sync"

    res = @request.post("/repos", params: { "name" => "bad name", "upstream" => other })
    assert_equal 422, res.status
    assert_includes res.body, "invalid repository name"
  end
end
