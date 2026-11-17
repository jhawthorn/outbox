# frozen_string_literal: true

require_relative "test_helper"
require "rack"
require "cgi"
require "json"

# Editing while reviewing: what the branch, commit and file pages offer
# (views/_commit_edit.erb, views/_last_edit.erb, data-edit for diffs.js) and
# the requests they make, through Rack.
class AppEditTest < OutboxTest::RepoCase
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

  AUTH = { "HTTP_AUTHORIZATION" => "Basic #{["jh:secret"].pack("m0")}" }.freeze

  def get(path)
    res = @request.get(path)
    assert_equal 200, res.status, "GET #{path}: #{res.body[0, 300]}"
    res.body
  end

  def post(path, params) = @request.post(path, params:, **AUTH)

  # What the viewer's save bar posts.
  def save(body) = @request.post("/repos/demo/branches/main/files", input: JSON.generate(body), "CONTENT_TYPE" => "application/json", **AUTH)

  def staged = rev(@repo.path, "refs/heads/main")
  def show(sha, file) = git("show", "#{sha}:#{file}", chdir: @repo.path)
  def subjects = git("log", "--format=%s", "upstream/main..main", chdir: @repo.path).lines.map(&:strip)

  # What a page gives the viewer to edit with.
  def edit_data(page) = JSON.parse(CGI.unescapeHTML(page[/ data-edit="([^"]*)"/, 1]))

  def two
    [stage_commit("a.txt", "a\n", "Add a"), stage_commit("b.txt", "b\n", "Add b")]
  end

  def test_a_branch_page_offers_to_edit_its_own_commits_and_their_files
    a, b = two
    page = get("/repos/demo/branches/main")
    assert_includes page, %(<div class="history editable">)
    [a, b].each do |sha|
      assert_includes page, %(data-reword="#{sha}")
      assert_includes page, %(formaction="/repos/demo/branches/main/commits/#{sha}/drop")
    end
    assert_includes page, %(formaction="/repos/demo/branches/main/commits/#{b}/squash")
    refute_includes page, %(formaction="/repos/demo/branches/main/commits/#{a}/squash"), "the oldest has nothing to be squashed into"
    assert_includes page, %(formaction="/repos/demo/branches/main/commits/#{a}/later")
    refute_includes page, %(formaction="/repos/demo/branches/main/commits/#{b}/later")
    assert_includes page, ">\nAdd a</textarea>"

    data = edit_data(page)
    assert_equal "/repos/demo/branches/main/files", data["url"]
    assert_equal b, data["base"]
    assert_nil data["into"]
    assert_equal [b, a], data["commits"].map { |c| c["sha"] }, "newest first"
    assert_equal({ "a.txt" => a, "b.txt" => b }, data["touched"])
    assert_equal 2, page.scan(" data-editable").size
  end

  def test_what_upstream_has_is_not_offered_for_editing
    page = get("/repos/demo/branches/main")
    refute_includes page, %( data-edit=")
    refute_includes page, %(data-reword=")
    refute_includes get("/repos/demo/tree/main/README"), %( data-edit=")
  end

  def test_a_commits_page_edits_that_commit
    a, b = two
    page = get("/repos/demo/branches/main/commits/#{a}")
    assert_includes page, %(<button type="button" data-reword="#{a}">Edit message</button>)
    assert_includes page, %(name="back" value="#{a}")
    refute_includes page, "/later", "there is no list to move it in"
    data = edit_data(page)
    assert_equal [a, a, a], data.values_at("base", "into", "back"), "its files are edited as they are in it, and folded into it"
    refute_nil b
  end

  def test_a_file_on_a_branch_being_reviewed_can_be_edited_where_it_is_browsed
    a, b = two
    page = get("/repos/demo/tree/main/a.txt")
    assert_includes page, "data-edit-file"
    data = edit_data(page)
    assert_equal b, data["base"]
    assert_equal a, data["touched"]["a.txt"]
    refute_includes get("/repos/demo/tree/#{b}/a.txt"), %( data-edit="), "a commit is not a branch to save to"
    assert_includes get("/repos/demo/branches/main"), %(href="/repos/demo/tree/main">Browse files</a>)
  end

  def test_saving_an_edit_into_a_commit
    a, b = two
    res = save(base: b, into: a, files: [{ path: "a.txt", content: "a, fixed\n" }])
    assert_equal 200, res.status, res.body
    answer = JSON.parse(res.body)
    assert_equal "/repos/demo/branches/main", answer["url"]
    assert_equal "Edited a.txt in #{a[0, 7]} “Add a”", answer["description"]
    assert_equal ["Add b", "Add a"], subjects
    assert_equal "a, fixed\n", show("main~1", "a.txt")

    page = get("/repos/demo/branches/main")
    assert_includes page, "<b>jh</b> edited"
    assert_includes page, "Edited a.txt in #{a[0, 7]}"
    assert_includes page, %(action="/repos/demo/branches/main/undo")
  end

  def test_saving_an_edit_as_a_new_commit
    _, b = two
    res = save(base: b, into: nil, message: "Shout b\n", files: [{ path: "b.txt", content: "B\n" }])
    assert_equal 200, res.status, res.body
    assert_equal ["Shout b", "Add b", "Add a"], subjects
    assert_equal "jh <outbox@localhost>", git("log", "-1", "--format=%an <%ae>", "main", chdir: @repo.path).strip
    assert_equal 422, save(base: staged, into: nil, message: "", files: [{ path: "b.txt", content: "b!\n" }]).status
  end

  def test_saving_from_a_commits_page_returns_to_what_became_of_the_commit
    a, = two
    res = save(base: a, into: a, back: a, files: [{ path: "a.txt", content: "A\n" }])
    assert_equal 200, res.status, res.body
    assert_equal "/repos/demo/branches/main/commits/#{rev(@repo.path, "main~1")}", JSON.parse(res.body)["url"]
    assert_equal "A\n", show("main", "a.txt")
  end

  def test_an_edit_that_cannot_be_saved_says_why
    a = stage_commit("a.txt", "one\n", "Add a")
    b = stage_commit("a.txt", "two\n", "Change a")
    res = save(base: b, into: a, files: [{ path: "a.txt", content: "three\n" }])
    assert_equal 422, res.status
    assert_includes JSON.parse(res.body)["error"], "does not apply to #{a[0, 7]} “Add a”"
    assert_equal b, staged
    assert_equal 422, save(base: b, into: b, files: [{ path: "nope.txt", content: "x" }]).status
    assert_equal 422, save(base: b, into: b, files: []).status
    res = @request.post("/repos/demo/branches/main/files", input: "not json", **AUTH)
    assert_equal 422, res.status
    assert_includes res.body, "not JSON"
  end

  def test_rewording_a_commit
    a, b = two
    res = post("/repos/demo/branches/main/commits/#{a}/reword", { "expected" => staged, "message" => "Add a, better\r\n\r\nBecause.\r\n", "back" => a })
    assert_equal 303, res.status, res.body[0, 300]
    reworded = rev(@repo.path, "main~1")
    assert_equal "http://example.org/repos/demo/branches/main/commits/#{reworded}", res.location
    assert_equal "Add a, better\n\nBecause.\n", git("log", "-1", "--format=%B", reworded, chdir: @repo.path).chomp
    assert_equal 422, post("/repos/demo/branches/main/commits/#{reworded}/reword", { "expected" => b, "message" => "x" }).status,
                 "b was made again: the page's tip is no longer the branch's"
    assert_equal 422, post("/repos/demo/branches/main/commits/#{reworded}/reword", { "expected" => staged, "message" => " " }).status
  end

  def test_squashing_folding_moving_and_dropping_commits
    _, b = two
    stage_commit("c.txt", "c\n", "Add c")
    stage_commit("d.txt", "d\n", "Add d")
    at = ->(n) { rev(@repo.path, "main~#{n}") }
    act = ->(sha, action, **extra) { post("/repos/demo/branches/main/commits/#{sha}/#{action}", { "expected" => staged, **extra }) }

    res = act.(b, "earlier")
    assert_equal 303, res.status, res.body[0, 300]
    assert_equal "http://example.org/repos/demo/branches/main", res.location
    assert_equal ["Add d", "Add c", "Add a", "Add b"], subjects
    assert_equal 422, act.(at.(3), "earlier").status, "the oldest has nowhere earlier to go"
    assert_equal 422, act.(staged, "later").status
    act.(at.(3), "later")
    assert_equal ["Add d", "Add c", "Add b", "Add a"], subjects

    c = at.(1)
    res = act.(c, "squash", "back" => c)
    assert_equal "http://example.org/repos/demo/branches/main/commits/#{at.(1)}", res.location, "to the commit it became part of"
    assert_equal ["Add d", "Add b", "Add a"], subjects
    assert_equal "Add b\n\nAdd c\n", git("log", "-1", "--format=%B", "main~1", chdir: @repo.path).chomp

    act.(staged, "fixup")
    assert_equal ["Add b", "Add a"], subjects
    assert_equal "Add b\n\nAdd c\n", git("log", "-1", "--format=%B", "main", chdir: @repo.path).chomp
    assert_equal "d\n", show("main", "d.txt")

    res = act.(staged, "drop", "back" => staged)
    assert_equal "http://example.org/repos/demo/branches/main", res.location
    assert_equal ["Add a"], subjects
  end

  def test_what_is_not_the_branchs_own_or_no_edit_is_refused
    two
    assert_equal 404, post("/repos/demo/branches/main/commits/#{rev(@repo.path, "upstream/main")}/drop", { "expected" => staged }).status
    assert_equal 404, post("/repos/demo/branches/main/commits/#{staged}/explode", { "expected" => staged }).status
    assert_equal 422, post("/repos/demo/branches/main/commits/#{staged}/drop", {}).status
    assert_equal ["Add b", "Add a"], subjects
  end

  def test_an_edit_that_no_longer_applies_changes_nothing
    a = stage_commit("a.txt", "one\n", "Add a")
    b = stage_commit("a.txt", "two\n", "Change a")
    res = post("/repos/demo/branches/main/commits/#{a}/drop", { "expected" => staged })
    assert_equal 422, res.status
    assert_includes res.body, "#{b[0, 7]} “Change a” no longer applies"
    assert_equal b, staged
  end

  def test_undo
    a = stage_commit("a.txt", "a\n", "Add a")
    post("/repos/demo/branches/main/commits/#{a}/reword", { "expected" => staged, "message" => "Reworded" })
    edited = staged
    refute_equal a, edited
    assert_equal 422, post("/repos/demo/branches/main/undo", { "expected" => a }).status
    res = post("/repos/demo/branches/main/undo", { "expected" => edited })
    assert_equal 303, res.status, res.body[0, 300]
    assert_equal a, staged
    refute_includes get("/repos/demo/branches/main"), "action=\"/repos/demo/branches/main/undo\""
  end

  def test_a_hidden_character_in_a_message_is_written_out_where_it_is_edited
    stage_commit("a.txt", "a\n", "Fix\u202E gnihtemos")
    page = get("/repos/demo/branches/main")
    refute_includes page, "\u202E"
    assert_includes page, "Fix&lt;U+202E&gt; gnihtemos</textarea>"
  end

  # A staged branch named like a remote's branch cannot be reached by that
  # name in the code browser, so its files are linked by sha.
  def test_a_branch_named_like_a_remotes_is_browsed_by_sha
    sha = stage_commit("x.txt", "x\n", "Shadow", branch: "HEAD:refs/heads/upstream/main")
    assert_includes get("/repos/demo/branches/upstream/main"), %(href="/repos/demo/tree/#{sha}">Browse files</a>)
  end
end
