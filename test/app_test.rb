# frozen_string_literal: true

require_relative "test_helper"
require "rack"
require "socket"

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

  # Pages that follow changes carry what they need to: the index nothing
  # but the seq, a repository's pages its name, a branch's and a commit's
  # the tips the page was drawn from. Error and offline pages do not.
  def test_pages_are_live
    before = Outbox.hub.seq
    sha = stage_commit
    branch = @repo.branch("main")
    # The push is announced within the watcher's interval; let it be, so the
    # seq does not move under the pages below.
    seq = wait_for_seq { |s| s > before }
    assert_includes get("/"), %(<main data-live data-seq="#{seq}">)
    assert_includes get("/repos/demo"), %(<main data-live data-seq="#{seq}" data-repo="demo">)
    live = %(<main data-live data-seq="#{seq}" data-repo="demo" data-tips="#{branch.staged} #{branch.upstream}">)
    assert_includes get("/repos/demo/branches/main"), live
    assert_includes get("/repos/demo/branches/main/commits/#{sha}"), live
    assert_includes get("/offline"), "<main>"
    assert_includes @request.get("/repos/demo/branches/nope").body, "<main>"
  end

  # The seq a page records is what has gone out to pages before it was
  # drawn, so a page drawn after a change has a later one.
  def test_a_page_drawn_after_a_change_has_a_later_seq
    before = Outbox.hub.seq
    Outbox.hub.fetch(@repo)
    wait_until("the fetch to finish") { !Outbox.hub.status(@repo).busy? }
    # Queued, started and finished: at least the first and last are announced.
    seq = wait_for_seq { |s| s >= before + 2 }
    assert_includes get("/"), %(<main data-live data-seq="#{seq}">)
  end

  # The seq once it has reached what the block asks for and then stayed put
  # for a moment, so a page drawn afterwards carries it.
  def wait_for_seq
    wait_until("the seq to move") { yield Outbox.hub.seq }
    seq = nil
    wait_until("the seq to settle") do
      s = Outbox.hub.seq
      sleep 0.05
      seq = s if Outbox.hub.seq == s
    end
    seq
  end

  # /events hands its socket to the hub and returns: the stream is written
  # from the Notifier's thread, not this one.
  def test_events_stream_names_the_repository_that_changed
    status, headers, body = Outbox::App.call(Rack::MockRequest.env_for("/events"))
    assert_equal 200, status
    assert_equal "text/event-stream;charset=utf-8", headers["content-type"]
    assert_equal "no-cache", headers["cache-control"]
    refute headers.key?("content-length")
    refute_respond_to body, :each, "a streaming body, so puma hands over the socket"

    server, client = UNIXSocket.pair
    body.call(server)
    Outbox.hub.fetch(@repo)
    received = +""
    wait_until("the fetch to be announced") do
      received << client.read_nonblock(4096, exception: false).to_s if IO.select([client], nil, nil, 0.05)
      received.include?("event: refs\ndata: demo\n\n")
    end
    assert_match(/\Aretry: \d+\nevent: hello\ndata: \d+\n\n/, received)
    assert_includes received, "event: status\ndata: demo\n\n"
  ensure
    client&.close
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

  def test_repo_page_lists_remotes_and_bases
    theirs = File.join(@dir, "theirs.git")
    git("clone", "--quiet", "--bare", @upstream, theirs)
    @repo.configure!(push: "upstream", remotes: { "upstream" => @upstream, "theirs" => theirs }, bases: ["theirs/main"])
    body = get("/repos/demo")
    assert_includes body, "push <b>upstream</b> <code>#{@upstream}</code>"
    assert_includes body, "fetch <b>theirs</b> <code>#{theirs}</code>"
    assert_includes body, "base <b>theirs/main</b>"
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

  def test_branch_page_marks_commits_that_are_another_branchs_tip
    first = stage_commit("a.txt", "a\n", "First")
    push(@stage, "main:topic")
    second = stage_commit("b.txt", "b\n", "Second")
    body = get("/repos/demo/branches/main")
    assert_includes body, 'class="badge tip" href="/repos/demo/branches/topic"'
    assert_equal 1, body.scan('class="badge tip"').size
    refute_includes get("/repos/demo/branches/topic"), 'class="badge tip"'
    assert_equal first, @repo.branch("topic").staged
    refute_equal second, first
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

  def test_branch_page_rests_the_commits_on_what_they_build_on
    stage_commit("a.txt", "a\n", "First")
    body = get("/repos/demo/branches/main")
    assert_includes body, "fork point"
    assert_includes body, "<b>upstream/main</b> · fork point"
    assert_includes body, ">initial<", "the commit they build on is shown"
    assert_includes body, "already upstream"
    assert_includes body, '<span class="count add">+1</span> <span class="count del">−0</span>'
  end

  def test_branch_page_draws_dropped_upstream_commits_like_the_staged_ones
    stage_commit
    upstream_commit("up.txt", "one\ntwo\n")
    @repo.fetch!
    body = get("/repos/demo/branches/main")
    assert_includes body, "Dropped from upstream (1)"
    assert_includes body, "Upstream has moved. Approving overwrites it."
    assert_match(%r{<div class="history dropped">.*<span class="subject">Upstream change</span>.*\+2</span> <span class="count del">−0</span>.*</div>\s*<h2>Commits}m, body)
    assert_includes body, "Force approve (drops 1 commit)"
    refute_includes body, "Approve and push to upstream"
  end

  LINES = (1..10).map { |i| "line #{i}\n" }.join

  # feature, once approved with two commits, rebased onto a main that has
  # moved on: the first commit carried over as it was, the second reworked.
  def rebase_feature
    git("checkout", "--quiet", "-b", "feature", chdir: @stage)
    stage_commit("one.txt", LINES, "Add one", branch: "feature")
    stage_commit("two.txt", LINES, "Add two", branch: "feature")
    @repo.approve!("feature")
    upstream_commit
    @repo.fetch!
    git("fetch", "--quiet", @upstream, "main:refs/remotes/up/main", chdir: @stage)
    git("rebase", "--quiet", "up/main", chdir: @stage)
    File.write(File.join(@stage, "two.txt"), LINES.sub("line 5", "two fixed"))
    git("add", "two.txt", chdir: @stage)
    git("commit", "--quiet", "--amend", "--no-edit", chdir: @stage)
    push(@stage, "feature", force: true)
  end

  def test_a_rebased_branch_is_called_that_and_lists_only_its_own_commits
    rebase_feature
    body = get("/repos/demo/branches/feature")
    assert_includes body, '<span class="badge diverged">rebased</span>'
    assert_includes body, "2 commits to push, rebased onto 1 newer upstream commit; replaces 2 upstream commits"
    assert_includes body, "onto <b>upstream/main</b>"
    assert_includes body, "Of upstream's 2 commits: 1 carried over unchanged, 1 changed, none dropped."
    assert_includes body, "Approving overwrites upstream's version."
    assert_includes body, "Commits (2)"
    refute_includes body, "Dropped from upstream", "both upstream commits live on"
    refute_includes body, '<span class="subject">Upstream change</span>', "the commit picked up from main is not the branch's"
    assert_match(%r{>Add one</a>.*<span class="badge same" title="The same patch as upstream's \h{10}; only what it builds on moved">unchanged</span>}m, body)
    assert_match(%r{>Add two</a>.*<span class="badge changed" title="Reworked from upstream's \h{10}">changed</span>}m, body)
    assert_includes body, "<b>upstream/main</b> · rebased onto"
    assert_includes body, ">Upstream change<", "the commit the branch now rests on"
    assert_includes body, "Files changed (1)"
    assert_includes body, "What changed besides the rebase"
    assert_includes body, "two.txt"
    refute_includes body, "up.txt", "what the new base brought in is not part of the review"
    assert_includes body, "confirm('Force-push feature to upstream? All 2 upstream commits are carried over.')"
    patch = get("/repos/demo/branches/feature.patch")
    assert_includes patch, "+two fixed"
    refute_includes patch, "up.txt"

    body = get("/repos/demo")
    assert_includes body, '<span class="badge diverged">rebased</span>'
    assert_includes body, "2 commits to push, rebased onto 1 newer upstream commit; replaces 2 upstream commits"
    assert_includes get("/"), "rebased onto 1 newer upstream commit"
  end

  def test_a_rebase_that_changes_nothing_says_so
    git("checkout", "--quiet", "-b", "feature", chdir: @stage)
    stage_commit("one.txt", LINES, "Add one", branch: "feature")
    @repo.approve!("feature")
    upstream_commit
    @repo.fetch!
    git("fetch", "--quiet", @upstream, "main:refs/remotes/up/main", chdir: @stage)
    git("rebase", "--quiet", "up/main", chdir: @stage)
    push(@stage, "feature", force: true)

    body = get("/repos/demo/branches/feature")
    assert_includes body, "Files changed (0)"
    assert_includes body, "The rebase changed nothing else"
    assert_includes body, "1 carried over unchanged, none dropped."
  end

  def test_a_rebase_that_dropped_a_commit_lists_it
    git("checkout", "--quiet", "-b", "feature", chdir: @stage)
    stage_commit("one.txt", LINES, "Add one", branch: "feature")
    stage_commit("two.txt", LINES, "Add two", branch: "feature")
    @repo.approve!("feature")
    upstream_commit
    @repo.fetch!
    git("fetch", "--quiet", @upstream, "main:refs/remotes/up/main", chdir: @stage)
    git("reset", "--quiet", "--hard", "up/main", chdir: @stage)
    commit(@stage, "one.txt", LINES, "Add one")
    push(@stage, "HEAD:feature", force: true)

    body = get("/repos/demo/branches/feature")
    assert_includes body, "1 carried over unchanged, 1 dropped."
    assert_includes body, "Dropped from upstream (1)"
    assert_includes body, "not even reworked: the 1 commit it carries over is marked below"
    assert_match(%r{<div class="history dropped">.*<span class="subject">Add two</span>.*</div>\s*<h2>Commits \(1\)}m, body)
    assert_includes body, "confirm('Force-push feature to upstream? 1 upstream commit will be dropped.')"
    assert_includes body, "Force approve (drops 1 commit)"
    assert_includes body, '<div class="note rebase drops">'
    assert_includes body, "two.txt"
    assert_includes get("/repos/demo/branches/feature.patch"), "-line 1", "dropping the commit shows as removing what it added"
  end

  def test_a_rebase_that_conflicted_names_the_file
    git("checkout", "--quiet", "-b", "feature", chdir: @stage)
    stage_commit("clash.txt", "feature\n" * 8, "Add clash", branch: "feature")
    @repo.approve!("feature")
    upstream_commit("clash.txt", "upstream\n" * 8, "Upstream clash")
    @repo.fetch!
    git("fetch", "--quiet", @upstream, "main:refs/remotes/up/main", chdir: @stage)
    git("reset", "--quiet", "--hard", "up/main", chdir: @stage)
    commit(@stage, "clash.txt", "resolved\n" * 8, "Add clash")
    push(@stage, "HEAD:feature", force: true)

    body = get("/repos/demo/branches/feature")
    assert_includes body, "Replaying it conflicted in <code>clash.txt</code>, so there the diff starts from the conflict markers"
    assert_includes body, "Files changed (1)"
  end

  def test_deleted_branch_page_offers_to_delete_it_from_upstream
    add_upstream_branch("extra")
    git("push", "--quiet", "origin", ":extra", chdir: @stage)
    body = get("/repos/demo/branches/extra")
    assert_includes body, "deleted here · upstream <code>"
    assert_includes body, "Approve and delete from upstream"
    assert_includes body, "confirm('Delete extra from upstream?')"
    refute_includes body, "Approve and push to upstream"
    assert_includes body, "Dropped from upstream (1)"
  end

  def test_branch_page_shows_times_with_their_offsets_and_the_committer_only_when_it_differs
    identity = { "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com" }
    commit_at = lambda do |message, author_date, committer_date, extra = {}|
      env = OutboxTest::GIT_ENV.merge(identity, extra, "GIT_AUTHOR_DATE" => author_date, "GIT_COMMITTER_DATE" => committer_date)
      _, err, status = Open3.capture3(env, "git", "commit", "--quiet", "--allow-empty", "-m", message, chdir: @stage)
      assert status.success?, err
    end
    commit_at.call("Same", "2026-10-15T14:28:54-0700", "2026-10-15T14:28:54-0700")
    commit_at.call("Later", "2026-10-16T09:00:00+0530", "2026-10-16T12:00:00+0000")
    commit_at.call("Someone else", "2026-10-17T00:00:00+0000", "2026-10-17T00:00:00+0000",
                   "GIT_COMMITTER_NAME" => "Bot", "GIT_COMMITTER_EMAIL" => "bot@example.com")
    push(@stage, "main")

    body = get("/repos/demo/branches/main")
    assert_includes body, '2026-10-15 14:28 <span class="off">UTC−7</span>'
    assert_includes body, '2026-10-16 09:00 <span class="off">UTC+5:30</span>'
    assert_includes body, '2026-10-16 12:00 <span class="off">UTC</span>'
    assert_includes body, 'title="2026-10-15T14:28:54-07:00"', "the full timestamp is on hover"
    assert_equal 2, body.scan('class="line committer"').size, "only the commits with a different time or committer"
    assert_includes body, "Bot <i>&lt;bot@example.com&gt;</i>"
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

  # A page on another site can post the approve form, and the browser sends
  # the remembered password with it. An agent knows the sha it pushed, so
  # that would let it approve its own work. The Origin header gives the
  # other site away.
  def test_posts_from_another_origin_are_refused
    staged = stage_commit
    %w[approve discard].each do |action|
      res = @request.post("/repos/demo/branches/main/#{action}", params: { expected: staged }, "HTTP_ORIGIN" => "http://evil.example")
      assert_equal 403, res.status
    end
    assert_equal 403, @request.post("/fetch", "HTTP_ORIGIN" => "http://evil.example").status
    assert_equal :ready, status_of
    refute_equal staged, rev(@upstream, "main")
    # The site's own forms carry its origin.
    res = @request.post("/repos/demo/branches/main/discard", params: { expected: staged }, "HTTP_ORIGIN" => "http://example.org")
    assert_equal 303, res.status
    wait_until("discard") { !Outbox.hub.status(@repo).busy? }
    assert_equal :synced, status_of
  end
end
