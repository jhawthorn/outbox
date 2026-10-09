# frozen_string_literal: true

require_relative "test_helper"
require "rack"

class GitHttpTest < OutboxTest::RepoCase
  def setup
    super
    @app_calls = 0
    app = lambda do |_env|
      @app_calls += 1
      [200, { "content-type" => "text/plain" }, ["app"]]
    end
    @request = Rack::MockRequest.new(Outbox::GitHttp.new(app, Outbox::Repo.repos_dir))
  end

  def test_advertises_refs_for_fetch
    res = @request.get("/demo.git/info/refs?service=git-upload-pack")
    assert_equal 200, res.status
    assert_equal "application/x-git-upload-pack-advertisement", res["content-type"]
    assert_includes res.body, "# service=git-upload-pack"
    assert_includes res.body, "refs/heads/main"
    assert_equal 0, @app_calls
  end

  def test_advertises_refs_for_push
    res = @request.get("/demo.git/info/refs?service=git-receive-pack")
    assert_equal 200, res.status, "http.receivepack must be enabled on staging repos"
    assert_equal "application/x-git-receive-pack-advertisement", res["content-type"]
    assert_includes res.body, "# service=git-receive-pack"
  end

  def test_unknown_repo_is_404_without_running_git
    res = @request.get("/nope.git/info/refs?service=git-upload-pack")
    assert_equal 404, res.status
    assert_equal 0, @app_calls
  end

  def test_other_paths_fall_through_to_the_app
    assert_equal "app", @request.get("/").body
    assert_equal "app", @request.get("/repos/demo").body
    assert_equal "app", @request.get("/repos/demo/branches/main").body
    assert_equal 3, @app_calls
  end

  def test_repo_names_that_could_escape_the_root_fall_through
    assert_equal "app", @request.get("/-x.git/info/refs").body
    assert_equal "app", @request.get("/.hidden.git/info/refs").body
    assert_equal "app", @request.get("/a%2F..%2Fb.git/info/refs").body
    assert_equal 3, @app_calls
  end
end
