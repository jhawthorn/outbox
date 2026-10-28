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
    live = %(<main data-live data-seq="#{seq}" data-repo="demo" data-tips="#{branch.staged} #{branch.upstream}" data-comments-seen="#{Digest::SHA1.hexdigest("")[0, 16]}">)
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

  # A repository's Code and Review tabs are pages of their own: the code
  # at /repos/<name>, with a note of what awaits review, and the list.
  # Reviewing is what the outbox is for, so a repository's home is its
  # review list, the first tab. Code is the next tab, and a page of its own.
  def test_review_is_the_home_and_code_a_tab_of_its_own
    stage_commit("lib/a.rb", "x\n", "Add a\n\nWith a body.")
    review = get("/repos/demo")
    assert_includes review, %(<nav class="tabs"><a class="tab active" href="/repos/demo" aria-current="page"><span class="label" data-label="Review">Review</span> <span class="count-pill">1</span></a><a class="tab" href="/repos/demo/tree/main"><span class="label" data-label="Code">Code</span></a>)
    assert_includes review, %(<table class="pending">)
    assert_match %r{<td class="latest">\s*<a class="subject" href="/repos/demo/commit/\h{40}" title="Add a">Add a</a>}, review, "each branch says what it is about"
    refute_includes review, %(<table class="tree")
    code = get("/repos/demo/tree/main")
    assert_includes code, %(<a class="tab active" href="/repos/demo/tree/main" aria-current="page"><span class="label" data-label="Code">Code</span></a>)
    assert_includes code, %(<table class="tree")
    assert_includes code, "has staged work awaiting review"
    assert_includes get("/repos/demo/branches/main"), %(<a class="crumb" href="/repos/demo">Review</a>)
    assert_equal "/repos/demo", URI(@request.get("/repos/demo/review").headers["location"]).path
    assert_equal "/repos/demo/tree/main", URI(@request.get("/repos/demo/code").headers["location"]).path
  end

  def test_nothing_to_review_points_at_the_code
    body = get("/repos/demo")
    assert_includes body, "Nothing to review"
    assert_includes body, %(<a class="button" href="/repos/demo/tree/main">Browse code</a>)
  end

  def test_an_empty_repository_says_how_to_fill_it
    empty = File.join(@dir, "empty.git")
    git("init", "--quiet", "--bare", empty)
    Outbox::Repo.create("void", empty)
    assert_includes get("/repos/void"), "No branches. Push something to"
    assert_includes get("/repos/void/code"), "No code yet. Push something to"
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
    assert_includes body, '<a class="path" href="#f0" title="outbox.conf">outbox.conf</a>'
    assert_includes get("/repos/_config/branches/main.patch"), "+[repo \"demo\"]"
  end

  def test_branch_page_renders_summary_and_diff_placeholders
    stage_commit("lib/a.rb", "x = 1\ny = 2\n", "Add a")
    body = get("/repos/demo/branches/main")

    assert_includes body, "Add a"
    assert_includes body, "Files changed (1)"
    assert_includes body, '<a class="path" href="#f0" title="lib/a.rb">lib/a.rb</a>'
    assert_includes body, 'class="badge added"'
    assert_includes body, "+2</span>"
    assert_includes body, "1 file changed"
    # The diff body is drawn in the browser from the raw patch.
    assert_includes body, 'data-patch-url="/repos/demo/branches/main.patch"'
    assert_match %r{<details class="file" id="f0" open data-path="lib/a.rb" data-new-blob="[0-9a-f]{40}" data-status="added" data-add="\d+" data-del="0"(?: data-view-url="[^"]*")?>}, body
    assert_includes body, '<div class="diff" data-diff-file="lib/a.rb">'
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

  def test_images_in_a_diff_are_served_by_blob_id
    png = "\x89PNG\r\n\x1A\n\x00binary".b
    stage_commit("img/a b.png", png, "Add an image")
    body = get("/repos/demo/branches/main")
    id = body[/data-new-blob="([0-9a-f]{40})"/, 1]
    assert_match(/data-binary data-image/, body)
    assert_includes body, %(<img src="/repos/demo/blobs/#{id}/a%20b.png" alt="img/a b.png, after">)

    res = @request.get("/repos/demo/blobs/#{id}/a%20b.png")
    assert_equal 200, res.status
    assert_equal "image/png", res.headers["content-type"]
    assert_includes res.headers["content-security-policy"], "sandbox"
    assert_equal png, res.body.b
    assert_equal "image/svg+xml", @request.get("/repos/demo/blobs/#{id}/x.svg").headers["content-type"]
    assert_equal 404, @request.get("/repos/demo/blobs/#{id}/a.html").status, "only images"
    assert_equal 404, @request.get("/repos/demo/blobs/#{"0" * 40}/a.png").status
    assert_equal 404, @request.get("/repos/demo/blobs/HEAD/a.png").status
  end

  def test_tree_url_shows_a_file_as_it_is_in_a_commit
    sha = stage_commit("lib/a b.rb", "x = 1\ny = 2\n", "Add a")
    blob = @repo.file_blob(sha, "lib/a b.rb")

    assert_includes get("/repos/demo/branches/main"), %(href="/repos/demo/tree/#{sha}/lib/a%20b.rb" title="View the whole file at this commit">view file</a>)
    assert_includes get("/repos/demo/branches/main/commits/#{sha}"), %(href="/repos/demo/tree/#{sha}/lib/a%20b.rb")
    body = get("/repos/demo/tree/#{sha}/lib/a%20b.rb")
    assert_includes body, %(<a class="crumb" href="/repos/demo/tree/#{sha}/lib">lib</a>)
    assert_includes body, %(<a class="crumb" href="/repos/demo/tree/#{sha}">demo</a>)
    assert_includes body, "<b>a b.rb</b>"
    assert_includes body, %(<span class="name">#{sha[0, 10]}</span>), "the picker names the commit"
    assert_includes body, "2 lines · 12 bytes"
    assert_includes body, %(href="/repos/demo/raw/#{sha}/lib/a%20b.rb">Raw</a>)
    assert_includes body, %(href="/repos/demo/blame/#{sha}/lib/a%20b.rb")
    assert_includes body, %(href="/repos/demo/commits/#{sha}/lib/a%20b.rb")
    assert_includes body, %(href="/repos/demo/commit/#{sha}"), "the last commit to touch it"
    assert_includes body, %(data-file-name="lib/a b.rb" data-blob-url="/repos/demo/blobs/#{blob}")
    refute_includes body, "data-permalink", "a sha is a permalink already"
    refute_includes body, "x = 1"
  end

  # A branch, a remote's branch or a tag can stand where the sha does, and
  # the pages then link on by that name.
  def test_tree_url_takes_branch_names
    stage_commit("lib/a.rb", "x = 1\n", "Add a", branch: "main")
    git("checkout", "--quiet", "-b", "topic/deep", chdir: @stage)
    sha = stage_commit("lib/b.rb", "y = 1\n", "Add b", branch: "topic/deep")
    upstream = @repo.branch("main").upstream

    body = get("/repos/demo/tree/topic/deep/lib/b.rb")
    assert_includes body, %(<span class="name">topic/deep</span>)
    assert_includes body, %(<a class="crumb" href="/repos/demo/tree/topic/deep/lib">lib</a>)
    assert_includes body, %(href="/repos/demo/tree/#{sha}/lib/b.rb" data-permalink)
    assert_includes body, "awaiting review", "staged work is pointed out"
    assert_includes get("/repos/demo/tree/topic/deep/lib"), %(href="/repos/demo/tree/topic/deep/lib/b.rb">b.rb</a>)
    assert_includes get("/repos/demo/tree/upstream/main"), %(<span class="name">upstream/main</span>)
    assert_equal 404, @request.get("/repos/demo/tree/upstream/main/lib/a.rb").status, "not upstream's yet"
    assert_includes get("/repos/demo/tree/main/lib/a.rb"), "1 line · 6 bytes"
    assert_includes get("/repos/demo/tree/#{upstream[0, 8]}"), %(<span class="name">#{upstream[0, 10]}</span>), "short shas"
    assert_equal 302, @request.get("/repos/demo/blob/main/lib/a.rb").status, "GitHub's URLs"
  end

  def test_tree_url_lists_a_directory_the_same_way
    commit(@stage, "lib/deep/c.rb", "c\n", "Add c")
    commit(@stage, "lib/a.rb", "x = 1\n", "Add a")
    commit(@stage, "z.txt", "z\n", "Add z")
    commit(@stage, "README.md", "# Hello <script>x</script>\n", "Add readme")
    sha = push(@stage, "main") && @repo.branch("main").staged

    root = get("/repos/demo/tree/#{sha}")
    assert_operator root.index(">lib<"), :<, root.index(">z.txt<"), "directories first"
    assert_includes root, %(href="/repos/demo/tree/#{sha}/lib")
    refute_includes root, ">..<"
    assert_includes root, %(href="/repos/demo/tree/#{sha}/README.md">README.md</a>)
    refute_includes root, "data-markdown", "the README is listed, not shown"
    assert_includes get("/repos/demo/tree/#{sha}/README.md"), %(<pre class="md-source"># Hello &lt;script&gt;x&lt;/script&gt;), "for the browser to draw"
    lib = get("/repos/demo/tree/#{sha}/lib/")
    assert_includes lib, %(href="/repos/demo/tree/#{sha}/lib/a.rb">a.rb</a>)
    assert_includes lib, %(href="/repos/demo/tree/#{sha}/lib/deep">deep</a>)
    assert_includes lib, %(href="/repos/demo/tree/#{sha}" title="Up one directory">..</a>)
    assert_includes lib, "6 bytes"
    assert_includes get("/repos/demo/tree/#{sha}/lib/deep"), %(href="/repos/demo/tree/#{sha}/lib" title="Up one directory">..</a>)
    assert_includes get("/repos/demo/branches/main"), %(href="/repos/demo/tree/#{sha}">Browse files</a>)
    assert_includes get("/repos/demo/tree/main"), %(href="/repos/demo/tree/main/lib">lib</a>)
  end

  def test_tree_url_refuses_what_is_not_in_a_commit
    sha = stage_commit("lib/a.rb", "x = 1\n", "Add a")

    assert_equal 404, @request.get("/repos/demo/tree/#{sha}/nope.rb").status
    assert_nil @repo.object_type(sha, "lib/../lib")
    assert_nil @repo.object_type(sha, "lib//a.rb")
    assert_equal "blob", @repo.object_type(sha, "lib/a.rb")
    assert_equal 404, @request.get("/repos/demo/tree/nope/lib/a.rb").status
    assert_equal 404, @request.get("/repos/demo/tree/#{"0" * 40}/lib/a.rb").status
    assert_equal 404, @request.get("/repos/demo/tree/main/../../x").status
  end

  # Raw files are text, or an image; never anything a browser would run.
  def test_raw_serves_files_inert
    stage_commit("pic.svg", %(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>), "Add svg")
    stage_commit("page.html", "<script>alert(1)</script>", "Add html")
    res = @request.get("/repos/demo/raw/main/pic.svg")
    assert_equal 200, res.status
    assert_equal "image/svg+xml", res.headers["content-type"]
    assert_includes res.headers["content-security-policy"], "sandbox"
    assert_equal "nosniff", res.headers["x-content-type-options"]
    res = @request.get("/repos/demo/raw/main/page.html")
    assert_equal "text/plain; charset=utf-8", res.headers["content-type"]
    assert_equal "<script>alert(1)</script>", res.body
    assert_includes get("/repos/demo/tree/main/pic.svg"), %(<img src="/repos/demo/raw/main/pic.svg")
  end

  def test_history_is_one_list_with_each_commits_date
    stage_commit("b.rb", "1\n", "Touch b")
    body = get("/repos/demo/commits/main")
    refute_includes body, "Commits on"
    assert_equal 2, body.scan('<div class="log-row">').size
    assert_match %r{<b>Test</b> · <span title="\d{4}-\d\d-\d\dT[^"]*">\d{4}-\d\d-\d\d \d\d:\d\d <span class="off">}, body
  end

  def test_history_lists_commits_and_those_that_touched_a_path
    stage_commit("lib/a.rb", "1\n", "Touch a")
    stage_commit("b.rb", "1\n", "Touch b")
    body = get("/repos/demo/commits/main")
    assert_includes body, ">Touch b<"
    assert_includes body, ">Touch a<"
    assert_includes body, ">initial<"
    only = get("/repos/demo/commits/main/lib")
    assert_includes only, ">Touch a<"
    refute_includes only, ">Touch b<"
    assert_includes only, %(History of <a class="crumb" href="/repos/demo/commits/main">demo</a>)
    assert_equal 302, @request.get("/repos/demo/commits").status
    assert_includes get("/repos/demo/commits/main?page=1"), "Older</span>", "one page, so no older link"
    assert_equal 404, @request.get("/repos/demo/commits/main?page=9").status
  end

  def test_any_commit_has_a_page
    sha = stage_commit("a.txt", "a\n", "Add a\n\nWith a body.")
    body = get("/repos/demo/commit/#{sha}")
    assert_includes body, %(<h1 class="commit-title">Add a</h1>)
    assert_includes body, "With a body."
    assert_includes body, %(data-patch-url="/repos/demo/commit/#{sha}.patch")
    assert_includes get("/repos/demo/commit/#{sha}.patch"), "+a"
    res = @request.get("/repos/demo/commit/#{sha[0, 8]}")
    assert_equal 302, res.status
    assert_equal "/repos/demo/commit/#{sha}", URI(res.headers["location"]).path
    assert_equal 404, @request.get("/repos/demo/commit/#{"1" * 40}").status
  end

  def test_branches_page_lists_every_branch_and_remote
    stage_commit
    add_upstream_branch("feature")
    body = get("/repos/demo/branches")
    assert_includes body, %(href="/repos/demo/tree/main">main</a>)
    assert_includes body, %(href="/repos/demo/tree/feature">feature</a>)
    assert_includes body, %(href="/repos/demo/tree/upstream/feature">feature</a>)
    assert_includes body, %(href="/repos/demo/branches/main")
    refs = JSON.parse(get("/repos/demo/refs.json"))
    assert_equal({ "name" => "main", "kind" => "branch", "default" => true }, refs.first)
    assert_includes refs.map { |r| r["name"] }, "upstream/feature"
  end

  def test_search_finds_lines_and_marks_them
    stage_commit("lib/a.rb", "def Greet\n  greet_world\nend\n", "Add a")
    body = get("/repos/demo/search?q=greet&rev=main")
    assert_includes body, "2 matching lines in 1 file"
    assert_includes body, "def <mark>Greet</mark>"
    assert_includes body, %(href="/repos/demo/tree/main/lib/a.rb?plain=1#L2">2</a>)
    assert_includes get("/repos/demo/search?q=Greet&rev=main"), "1 matching line in 1 file", "capitals match case"
    assert_includes get("/repos/demo/search?q=g.eet_w&regex=1"), "<mark>greet_w</mark>orld"
    assert_includes get("/repos/demo/search?q=nothing+like+this"), "Nothing matches"
    assert_includes get("/repos/demo/search?q=%3Cb%3E"), "Nothing matches <code>&lt;b&gt;</code>"
    assert_includes get("/repos/demo/search?q=greet&path=lib"), "2 matching lines"
    assert_includes get("/repos/demo/search?q=greet&path=other"), "Nothing matches"
  end

  def test_blame_handles_odd_names_and_carriage_returns
    commit(@stage, "café.rb", "a = 1\nb = 2\n", "Add café")
    commit(@stage, "café.rb", "a = 1\nb = \"x\ry\"\n", "Add a CR")
    push(@stage, "main")
    body = get("/repos/demo/blame/main/caf%C3%A9.rb")
    first = rev(@stage, "HEAD~1")
    assert_includes body, %(href="/repos/demo/blame/#{first}/caf%C3%A9.rb" title="Blame prior to this change")
    assert_includes body, %(b = &quot;x<span class="invis" title="carriage return">CR</span>y&quot;)
  end

  def test_blame_says_who_changed_each_line
    commit(@stage, "a.rb", "one\ntwo\n", "First version")
    commit(@stage, "a.rb", "one\n2\n", "Second version")
    push(@stage, "main")
    body = get("/repos/demo/blame/main/a.rb")
    assert_operator body.index(">First version<"), :<, body.index(">Second version<")
    assert_includes body, %(<tr id="L2" class="hunk-start">)
    assert_includes body, %(<td class="code">2</td>)
    first = @repo.branch("main").staged.then { |sha| git("rev-parse", "#{sha}~1", chdir: @repo.path).strip }
    assert_includes body, %(href="/repos/demo/blame/#{first}/a.rb" title="Blame prior to this change")
    assert_equal 404, @request.get("/repos/demo/blame/main/nope.rb").status
  end

  def test_tree_commits_name_the_last_commit_to_touch_each_entry
    commit(@stage, "lib/a.rb", "1\n", "Touch a")
    commit(@stage, "lib/deep/b.rb", "1\n", "Touch b")
    commit(@stage, "gone/x.rb", "1\n", "Add gone")
    git("rm", "--quiet", "-r", "gone", chdir: @stage)
    git("commit", "--quiet", "-m", "Remove gone", chdir: @stage)
    sha = push(@stage, "main") && @repo.branch("main").staged

    root = JSON.parse(get("/repos/demo/tree-commits/#{sha}"))
    assert_equal({ "README" => "initial", "lib" => "Touch b" }, root.transform_values { |c| c["subject"] })
    lib = JSON.parse(get("/repos/demo/tree-commits/#{sha}/lib"))
    assert_equal({ "a.rb" => "Touch a", "deep" => "Touch b" }, lib.transform_values { |c| c["subject"] })
    assert_includes get("/repos/demo/tree/main/lib"), %(data-commits-url="/repos/demo/tree-commits/#{sha}/lib")
  end

  def test_compare_shows_what_one_branch_has_that_another_does_not
    add_upstream_branch("feature")
    body = get("/repos/demo/compare/main...feature")
    assert_includes body, ">feature commit<"
    assert_includes body, "Commits (1)"
    assert_includes body, %(data-patch-url="/repos/demo/compare/main...feature.patch")
    assert_includes get("/repos/demo/compare/main...feature.patch"), "+feature"
    assert_includes get("/repos/demo/compare/feature"), ">feature commit<", "against the default branch"
    assert_includes get("/repos/demo/compare/feature...main"), "has nothing that"
    assert_includes get("/repos/demo/tree/feature"), %(href="/repos/demo/compare/main...feature")
    assert_includes get("/repos/demo/branches"), %(href="/repos/demo/compare/main...feature")
    assert_equal 302, @request.get("/repos/demo/compare?base=main&head=feature").status
    assert_equal "/repos/demo/compare/feature", URI(@request.get("/repos/demo/compare?base=&head=feature").headers["location"]).path
    assert_equal 404, @request.get("/repos/demo/compare/main...nope").status
  end

  def test_hiding_whitespace_keeps_each_files_counts
    commit(@stage, "f.txt", "f\n", "Add f")
    commit(@stage, "g.txt", "g\n", "Add g")
    commit(@stage, "f.txt", "f \n", "Trailing space")
    sha = commit(@stage, "g.txt", "g\nmore\nmore\n", "Grow g")
    push(@stage, "main")
    git("reset", "--quiet", "--soft", "HEAD~2", chdir: @stage)
    sha = git("commit", "--quiet", "-m", "Both", chdir: @stage) && rev(@stage, "HEAD")
    push(@stage, "main", force: true)
    body = get("/repos/demo/commit/#{sha}?w=1")
    assert_includes body, "1 file changed, 2 insertions(+), 0 deletions(-), whitespace ignored"
    assert_includes body, %(data-path="g.txt")
    refute_includes body, %(data-path="f.txt")
    assert_match %r{data-path="g.txt".*data-add="2" data-del="0"}, body
    assert_includes get("/repos/demo/commit/#{sha}"), %(data-path="f.txt")
  end

  def test_whitespace_changes_can_be_hidden
    stage_commit("a.rb", "if x\n  y\nend\n", "Add a")
    stage_commit("a.rb", "if x\n    y\nend\n", "Reindent a")
    sha = @repo.branch("main").staged
    assert_includes get("/repos/demo/commit/#{sha}.patch"), "+    y"
    assert_equal "", get("/repos/demo/commit/#{sha}.patch?w=1")
    body = get("/repos/demo/commit/#{sha}?w=1")
    assert_includes body, "Whitespace changes are hidden"
    assert_includes get("/repos/demo/commit/#{sha}"), %(href="/repos/demo/commit/#{sha}?w=1")
    branch = get("/repos/demo/branches/main?w=1")
    assert_includes branch, %(data-patch-url="/repos/demo/branches/main.patch?w=1")
  end

  # Branch names are the pusher's. Whatever git allows in one stays text on
  # every page: in links, in forms, in the questions they ask.
  def test_branch_names_cannot_inject_markup_or_script
    names = ['x"><svg/onload=alert(1)>', "y');alert(1);('", "q#x%y"]
    names.each { |name| commit(@stage, "f.txt", name, "On #{name}") && push(@stage, "HEAD:refs/heads/#{name}") }
    pages = ["/repos/demo", "/repos/demo/branches", "/", "/repos/demo/branches/#{ERB::Util.url_encode(names[0])}",
             "/repos/demo/tree/#{ERB::Util.url_encode(names[1])}", "/repos/demo/branches/#{ERB::Util.url_encode(names[1])}"]
    pages.each do |page|
      body = get(page)
      refute_includes body, "<svg/onload", page
      refute_includes body, "onsubmit", page
      refute_match(%r{href="(?!data:)[^"]*[<>' ]}, body, page)
    end
    assert_includes get("/repos/demo/branches"), %(href="/repos/demo/branches/x%22%3E%3Csvg/onload%3Dalert%281%29%3E")
    assert_includes get("/repos/demo/branches/q%23x%25y"), %(data-confirm="Discard staged changes on q#x%y?")
    assert_includes get("/repos/demo/branches/y%27%29%3Balert%281%29%3B%28%27"), 'data-confirm="Discard staged changes on y&#39;);alert(1);(&#39;?"'
  end

  # A staged branch is the pusher's to name. Named like a sha, or like a
  # remote's branch, it must not stand in for that commit or that branch.
  def test_staged_branches_cannot_shadow_commits_or_remote_branches
    upstream = @repo.branch("main").upstream
    commit(@stage, "README", "forged\n", "Forge")
    push(@stage, "HEAD:refs/heads/#{upstream}", "HEAD:refs/heads/upstream/main")
    assert_equal "hello\n", get("/repos/demo/raw/#{upstream}/README")
    assert_equal "hello\n", get("/repos/demo/raw/upstream/main/README")
    names = JSON.parse(get("/repos/demo/refs.json")).map { |r| [r["name"], r["kind"]] }
    refute_includes names, ["upstream/main", "branch"]
    assert_includes names, ["upstream/main", "remote"]
  end

  def test_staged_branches_cannot_stand_in_for_a_remote_directory
    upstream_commit("sub/x.txt", "upstream's\n", "Add sub")
    @repo.fetch!
    git("checkout", "--quiet", "-b", "upstream/main/sub", chdir: @stage)
    commit(@stage, "x.txt", "forged\n", "Forge")
    push(@stage, "upstream/main/sub")
    assert_equal "upstream's\n", get("/repos/demo/raw/upstream/main/sub/x.txt")
    branches = get("/repos/demo/branches")
    assert_includes branches, "shadowed"
    refute_includes branches, %(href="/repos/demo/tree/upstream/main/sub")
    refute_includes JSON.parse(get("/repos/demo/refs.json")).map { |r| r["name"] }, "upstream/main/sub"
  end

  # What was pushed cannot take down the page that lists it for review.
  def test_the_repository_page_survives_odd_commits
    git("update-index", "--add", "--cacheinfo", "160000,#{rev(@stage, "HEAD")},README.md", chdir: @stage)
    git("commit", "--quiet", "-m", "A gitlink called README.md", chdir: @stage)
    tree = git("rev-parse", "HEAD^{tree}", chdir: @stage).strip
    parent = rev(@stage, "HEAD")
    odd = "tree #{tree}\nparent #{parent}\nauthor A <a@x> 1700000000 +9999\ncommitter A <a@x> 1700000000 +9999\n\nBad zone\n"
    sha = IO.popen(["git", "hash-object", "-t", "commit", "-w", "--literally", "--stdin"], "r+", chdir: @stage) { |io| io.write(odd); io.close_write; io.read.strip }
    push(@stage, "#{sha}:refs/heads/main")
    assert_includes get("/repos/demo"), %(<table class="pending">)
    assert_includes get("/repos/demo"), ">Bad zone<"
    body = get("/repos/demo/tree/main")
    assert_includes body, "awaiting review"
    assert_includes body, ">README.md<"
    get("/repos/demo/commits/main")
    get("/repos/demo/branches/main")
  end

  def test_tree_commits_cannot_be_spoofed_by_file_names
    evil = "0\x01#{"f" * 40}\x1fEvil\x1fe@x\x1f2020-01-01T00:00:00Z\x1f2020-01-01T00:00:00Z\x1fSpoofed"
    commit(@stage, "a", "1\n", "Touch a")
    commit(@stage, "a ", "1\n", "Touch a-space")
    commit(@stage, evil, "1\n", "Add evil")
    sha = push(@stage, "main") && @repo.branch("main").staged
    found = JSON.parse(get("/repos/demo/tree-commits/#{sha}")).transform_values { |c| c["subject"] }
    assert_equal "Touch a", found["a"]
    assert_equal "Touch a-space", found["a "]
    assert_equal "Add evil", found[evil]
    refute_includes found.values, "Spoofed"
  end

  def test_paths_with_question_marks_and_newlines
    commit(@stage, "q?x.txt", "needle\n", "Add q")
    commit(@stage, "a\nb.txt", "needle\n", "Add newline")
    push(@stage, "main")
    assert_includes get("/repos/demo/tree/main"), %(href="/repos/demo/tree/main/q%3Fx.txt">q?x.txt</a>)
    assert_includes get("/repos/demo/tree/main/q%3Fx.txt"), "1 line"
    body = get("/repos/demo/search?q=needle")
    assert_includes body, "2 matching lines in 2 files"
  end

  def test_search_says_when_git_cannot_or_runs_out_of_time
    stage_commit("a.txt", "needle\n", "Add")
    assert_includes get("/repos/demo/search?q=(&regex=1"), "git could not search for that"
    limit = Outbox::Repo::GREP_TIMEOUT
    Outbox::Repo.send(:remove_const, :GREP_TIMEOUT)
    Outbox::Repo.const_set(:GREP_TIMEOUT, 0.000001)
    assert_includes get("/repos/demo/search?q=needle"), "The search stopped after"
  ensure
    Outbox::Repo.send(:remove_const, :GREP_TIMEOUT)
    Outbox::Repo.const_set(:GREP_TIMEOUT, limit)
  end

  def test_file_finder_lists_every_file
    sha = stage_commit("lib/deep/a.rb", "1\n", "Add a")
    assert_equal ["README", "lib/deep/a.rb"], get("/repos/demo/files/#{sha}").split("\0")
    assert_equal 404, @request.get("/repos/demo/files/main").status
  end

  def test_markdown_files_are_previewed_or_shown_as_code
    stage_commit("docs/guide.md", "# Guide\n\nSee [a](a.md).\n", "Add guide")
    body = get("/repos/demo/tree/main/docs/guide.md")
    assert_includes body, %(data-markdown data-tree-base="/repos/demo/tree/main/docs")
    assert_includes body, %(data-raw-base="/repos/demo/raw/main/docs")
    refute_includes body, "data-file-name"
    plain = get("/repos/demo/tree/main/docs/guide.md?plain=1")
    assert_includes plain, %(data-file-name="docs/guide.md")
    refute_includes plain, "data-markdown"
  end

  def test_tree_url_does_not_draw_binary_files
    sha = stage_commit("logo.bin", "a\0b\0c", "Add binary")
    body = get("/repos/demo/tree/#{sha}/logo.bin")
    assert_includes body, "Binary file not shown."
    refute_includes body, "data-file-name"
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
  def test_a_truncated_diff_says_so
    stage_commit("big.txt", "line\n" * 50, "Big")
    limit = Outbox::Repo::MAX_PATCH_BYTES
    Outbox::Repo.send(:remove_const, :MAX_PATCH_BYTES)
    Outbox::Repo.const_set(:MAX_PATCH_BYTES, 100)
    assert_includes get("/repos/demo/branches/main"), "Diff truncated at"
  ensure
    Outbox::Repo.send(:remove_const, :MAX_PATCH_BYTES)
    Outbox::Repo.const_set(:MAX_PATCH_BYTES, limit)
  end

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
    assert_includes body, %(<h1 class="commit-title">First</h1>)
    assert_includes body, "a.txt"
    refute_includes body, "b.txt", "only this commit's changes"
    assert_includes body, "← oldest"
    assert_includes body, "newer: Second"
    assert_includes body, "/commits/#{second}"

    body = get("/repos/demo/branches/main/commits/#{second}")
    assert_includes body, "commit 2 of 2"
    assert_includes body, "Longer explanation here."
    assert_includes body, "b.txt"
    refute_includes body, '<a class="path" href="#f0" title="a.txt">a.txt</a>'
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
    assert_includes body, 'data-confirm="Force-push feature to upstream? All 2 upstream commits are carried over."'
    patch = get("/repos/demo/branches/feature.patch")
    assert_includes patch, "+two fixed"
    refute_includes patch, "up.txt"

    body = get("/repos/demo")
    assert_includes body, '<span class="badge diverged">rebased</span>'
    assert_includes body, "2 commits to push, rebased onto 1 newer upstream commit; replaces 2 upstream commits"
    assert_includes get("/"), "rebased onto 1 newer upstream commit"
  end

  def test_an_amended_commit_says_what_it_changed_about_the_upstream_one
    stage_commit("a.txt", "a\n", "Keep me")
    stage_commit("b.txt", "b\nb\n", "Old subject")
    @repo.approve!("main")
    File.write(File.join(@stage, "b.txt"), "b\nb\nb\n")
    git("add", "b.txt", chdir: @stage)
    git("commit", "--quiet", "--amend", "-m", "New subject", chdir: @stage)
    push(@stage, "main", force: true)
    @repo.fetch!

    body = get("/repos/demo/branches/main")
    assert_includes body, "message was “Old subject”"
    assert_equal 1, body.scan(">New subject<").size, "the staged commit is listed once"
    refute_includes body, "Reworked from upstream ("
    refute_includes body, "Dropped from upstream"
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
    assert_includes body, 'data-confirm="Force-push feature to upstream? 1 upstream commit will be dropped."'
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
    assert_includes body, 'data-confirm="Delete extra from upstream?"'
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
    assert_includes body, '<a class="path" href="#f0" title="a.txt">a.txt</a>'
    assert_includes body, '<span class="badge hidden">hidden characters</span>'
    assert_includes body, 'title="Zero-width, bidi or control characters on lines +1">hidden characters on 1 line</span>'
    # And so is the browser's header for it (diffs.js).
    assert_match %r{<details class="file" id="f0" open data-path="a.txt" data-new-blob="[0-9a-f]{40}" data-hidden="\+1" data-status="added" data-add="1" data-del="0"(?: data-view-url="[^"]*")?>}, body
    refute_includes body, "​"
  end

  def test_file_sections_carry_what_the_browser_headers_show
    File.write(File.join(@stage, "logo.bin"), "\x00\x01binary")
    File.write(File.join(@stage, "run.sh"), "echo hi\n")
    git("add", "logo.bin", "run.sh", chdir: @stage)
    git("commit", "--quiet", "-m", "Add files", chdir: @stage)
    push(@stage, "main")
    File.write(File.join(@stage, "logo.bin"), "\x00\x02binary")
    File.chmod(0o755, File.join(@stage, "run.sh"))
    git("commit", "--quiet", "-am", "Change them", chdir: @stage)
    push(@stage, "main")

    sha = rev(@stage, "HEAD")
    body = get("/repos/demo/branches/main/commits/#{sha}")
    assert_match %r{<details class="file" id="f0" open data-path="logo.bin" data-old-blob="[0-9a-f]{40}" data-new-blob="[0-9a-f]{40}" data-binary data-status="modified"(?: data-view-url="[^"]*")?>}, body
    assert_match %r{<details class="file" id="f1" open data-path="run.sh" data-old-blob="[0-9a-f]{40}" data-new-blob="[0-9a-f]{40}" data-mode="100644 → 100755" data-status="modified" data-add="0" data-del="0"(?: data-view-url="[^"]*")?>}, body
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
    assert_includes body, '<a class="path" href="#f0" title="f.txt">f.txt</a>'
    assert_includes get("/repos/empty/branches/main/commits/#{sha}.patch"), "+first\n"
  end

  def test_branch_with_slash_in_commit_route
    git("checkout", "--quiet", "-b", "feature/x", chdir: @stage)
    sha = stage_commit("x.txt", "x\n", "Add x", branch: "feature/x")
    body = get("/repos/demo/branches/feature/x/commits/#{sha}")
    assert_includes body, "commit 1 of 1"
    assert_includes body, %(<h1 class="commit-title">Add x</h1>)
  end

  def upstream_sha = @repo.branch("main").upstream.to_s

  def test_approve_and_discard_enqueue_and_redirect
    staged = stage_commit
    res = @request.post("/repos/demo/branches/main/approve", params: { expected: staged, expected_upstream: upstream_sha })
    assert_equal 303, res.status
    assert_equal "http://example.org/repos/demo", res["location"]
    wait_until("approve") { !Outbox.hub.status(@repo).busy? }
    assert_equal staged, rev(@upstream, "main")

    stage_commit("z.txt", "z\n", "Z")
    res = @request.post("/repos/demo/branches/main/discard", params: { expected: rev(@stage, "main"), expected_upstream: upstream_sha })
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
      res = @request.post("/repos/demo/branches/main/#{action}", params: { expected: staged })
      assert_equal 422, res.status
      assert_includes res.body, "missing expected_upstream"
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
      res = @request.post("/repos/demo/branches/main/#{action}", params: { expected: staged, expected_upstream: upstream_sha }, "HTTP_ORIGIN" => "http://evil.example")
      assert_equal 403, res.status
    end
    assert_equal 403, @request.post("/fetch", "HTTP_ORIGIN" => "http://evil.example").status
    assert_equal :ready, status_of
    refute_equal staged, rev(@upstream, "main")
    # The site's own forms carry its origin.
    res = @request.post("/repos/demo/branches/main/discard", params: { expected: staged, expected_upstream: upstream_sha }, "HTTP_ORIGIN" => "http://example.org")
    assert_equal 303, res.status
    wait_until("discard") { !Outbox.hub.status(@repo).busy? }
    assert_equal :synced, status_of
  end

  # --- review comments ----------------------------------------------------

  def auth_env(user) = { "HTTP_AUTHORIZATION" => "Basic #{["#{user}:pw"].pack("m0")}" }

  def test_comments_are_posted_and_shown_on_the_branch_page
    staged = stage_commit("lib/a.rb", "x = 1\ny = 2\n", "Add a")
    res = @request.post("/repos/demo/branches/main/comments", params: { expected: staged, description: "Overall <fine>\r\nmostly" }, **auth_env("jh"))
    assert_equal 303, res.status
    assert_equal "http://example.org/repos/demo/branches/main#comments", res["location"]
    res = @request.post("/repos/demo/branches/main/comments",
                        params: { expected: staged, description: "y?", path: "lib/a.rb", side: "R", start: "2", end: "2" })
    assert_equal 303, res.status

    general, line = @repo.comments(staged)
    assert_equal ["jh", "Overall <fine>\nmostly", staged, nil], [general.author, general.description, general.commit, general.path]
    assert_equal ["reviewer", "lib/a.rb", 2, 2, staged], [line.author, line.path, line.start_line, line.end_line, line.commit]

    body = get("/repos/demo/branches/main")
    assert_includes body, "Comments (2)"
    assert_includes body, "Overall &lt;fine&gt;\nmostly"
    assert_includes body, %(<a href="#f0-R2-R2"><code>lib/a.rb</code> line 2</a>)
    data = JSON.parse(CGI.unescapeHTML(body[/data-comments="([^"]*)"/, 1]))
    assert_equal "/repos/demo/branches/main/comments", data["url"]
    assert_equal staged, data["expected"]
    assert data["removed"]
    assert_equal [{ "path" => "lib/a.rb", "side" => "R", "start" => 2, "end" => 2, "author" => "reviewer", "description" => "y?" }],
                 data["list"].map { |c| c.except("time") }
  end

  def test_comments_on_removed_lines_are_on_upstreams_commit
    stage_commit
    upstream = upstream_sha
    staged = stage_commit("README", "", "Empty the readme")
    res = @request.post("/repos/demo/branches/main/comments", params: { expected: staged, description: "keep it", path: "README", side: "L", start: "1", end: "1" })
    assert_equal 303, res.status
    c, = @repo.comments(staged)
    assert_equal upstream, c.commit
    assert_includes get("/repos/demo/branches/main"), %(<a href="#f0-L1-L1"><code>README</code> line 1</a>)
  end

  def test_a_comment_must_be_about_what_is_staged
    old = stage_commit
    stage_commit("b.txt", "b\n", "B")
    res = @request.post("/repos/demo/branches/main/comments", params: { expected: old, description: "stale" })
    assert_equal 422, res.status
    assert_includes res.body, "changed since you read it"
    assert_equal 422, @request.post("/repos/demo/branches/main/comments", params: { description: "x" }).status
    assert_equal 422, @request.post("/repos/demo/branches/main/comments", params: { expected: rev(@stage, "main"), description: "  " }).status
    assert_equal 422, @request.post("/repos/demo/branches/main/comments",
                                    params: { expected: rev(@stage, "main"), description: "x", path: "a", side: "R", start: "3", end: "1" }).status
    assert_equal 403, @request.post("/repos/demo/branches/main/comments",
                                    params: { expected: rev(@stage, "main"), description: "x" }, "HTTP_ORIGIN" => "http://evil.example").status
    assert_empty @repo.comments(rev(@stage, "main"))
  end

  def test_approve_and_discard_leave_a_verdict
    staged = stage_commit
    @request.post("/repos/demo/branches/main/approve", params: { expected: staged, expected_upstream: upstream_sha }, **auth_env("jh"))
    wait_until("approve") { !Outbox.hub.status(@repo).busy? }
    assert Outbox.hub.status(@repo).last.ok?
    verdict, = @repo.comments(staged)
    assert_equal ["jh", true, staged], [verdict.author, verdict.resolved, verdict.commit]

    discarded = stage_commit("z.txt", "z\n", "Z")
    @request.post("/repos/demo/branches/main/discard", params: { expected: discarded, expected_upstream: upstream_sha })
    wait_until("discard") { !Outbox.hub.status(@repo).busy? }
    verdict, = @repo.comments(discarded)
    assert_equal ["reviewer", false], [verdict.author, verdict.resolved]
    assert_includes verdict.description, "Discarded"
  end

  def test_comments_on_earlier_pushes_stay_findable
    first = stage_commit("lib/a.rb", "x = 1\n", "First try")
    @request.post("/repos/demo/branches/main/comments", params: { expected: first, description: "Rename x", path: "lib/a.rb", side: "R", start: "1", end: "1" })
    second = commit(@stage, "lib/a.rb", "count = 1\n", "Second try")
    push(@stage, "main")

    body = get("/repos/demo/branches/main")
    refute_includes body, "Comments ("
    assert_includes body, "Comments on 1 earlier push (1)"
    assert_includes body, %(<a href="/repos/demo/commit/#{first}"><code>#{first[0, 10]}</code></a>)
    assert_includes body, "Rename x"

    # The commit's own page shows them, linked to its diff.
    page = get("/repos/demo/commit/#{first}")
    assert_includes page, "Review comments (1)"
    assert_includes page, %(<a href="#f0-R1-R1"><code>lib/a.rb</code> line 1</a>)
    assert_includes get("/repos/demo/branches/main/commits/#{first}"), "Rename x"
    refute_includes get("/repos/demo/commit/#{second}"), "Review comments ("
  end

  def test_a_comment_is_announced_on_the_event_stream
    staged = stage_commit
    _, _, body = Outbox::App.call(Rack::MockRequest.env_for("/events"))
    server, client = UNIXSocket.pair
    body.call(server)
    assert_equal 303, @request.post("/repos/demo/branches/main/comments", params: { expected: staged, description: "hi" }).status
    received = +""
    wait_until("the comment to be announced") do
      received << client.read_nonblock(4096, exception: false).to_s if IO.select([client], nil, nil, 0.05)
      received.include?("event: comments\ndata: demo\n\n")
    end
    # Pages compare the comments they show with those they would show now.
    seen = %(data-comments-seen="#{Digest::SHA1.hexdigest(@repo.comments(staged).first.id)[0, 16]}")
    assert_includes get("/repos/demo/branches/main"), seen
    assert_includes get("/repos/demo/branches/main/commits/#{staged}"), seen
  ensure
    client&.close
  end

  def test_comments_are_edited_and_deleted_from_the_page_they_are_on
    staged = stage_commit
    @request.post("/repos/demo/branches/main/comments", params: { expected: staged, description: "Frist" })
    c, = @repo.comments(staged)
    body = get("/repos/demo/branches/main")
    url = "/repos/demo/comments/#{staged}/#{c.id}"
    assert_includes body, %(action="#{url}/edit")
    assert_includes body, %(action="#{url}/delete" data-confirm="Delete this comment?")
    seen = body[/data-comments-seen="(\w+)"/, 1]

    res = @request.post("#{url}/edit", params: { description: "First", back: "/repos/demo/branches/main" }, **auth_env("jh"))
    assert_equal "http://example.org/repos/demo/branches/main#comments", res["location"]
    body = get("/repos/demo/branches/main")
    assert_includes body, "· edited</span>"
    assert_includes body, ">First</div>"
    refute_equal seen, body[/data-comments-seen="(\w+)"/, 1], "an edit changes what the page shows"

    # Somewhere else is not somewhere to be sent.
    res = @request.post("#{url}/delete", params: { back: "https://evil.example/" })
    assert_equal "http://example.org/repos/demo#comments", res["location"]
    assert_empty @repo.comments(staged)
    assert_equal 404, @request.post("#{url}/delete").status
  end

  def test_verdicts_have_no_edit_or_delete
    staged = stage_commit
    @request.post("/repos/demo/branches/main/approve", params: { expected: staged, expected_upstream: upstream_sha })
    wait_until("approve") { !Outbox.hub.status(@repo).busy? }
    verdict, = @repo.comments(staged)
    body = get("/repos/demo/branches/main")
    assert_includes body, "Approved and pushed to upstream."
    refute_includes body, "/comments/#{staged}/#{verdict.id}"
    assert_equal 422, @request.post("/repos/demo/comments/#{staged}/#{verdict.id}/delete").status
  end
end

