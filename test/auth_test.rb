# frozen_string_literal: true

require_relative "test_helper"
require "rack"

class AuthTest < Minitest::Test
  OK = ->(_env) { [200, { "content-type" => "text/plain" }, ["ok"]] }

  def request(git_open: false)
    Rack::MockRequest.new(Outbox::Auth.new(OK, password: "s3cret", git_open: git_open))
  end

  def basic(user, password) = "Basic #{["#{user}:#{password}"].pack("m0")}"

  def test_requires_a_password_to_construct
    assert_raises(ArgumentError) { Outbox::Auth.new(OK, password: "") }
    assert_raises(ArgumentError) { Outbox::Auth.new(OK, password: nil) }
  end

  def test_rejects_without_credentials
    res = request.get("/")
    assert_equal 401, res.status
    assert_equal 'Basic realm="outbox"', res["www-authenticate"]
  end

  def test_rejects_wrong_password
    assert_equal 401, request.get("/", "HTTP_AUTHORIZATION" => basic("outbox", "nope")).status
    assert_equal 401, request.get("/", "HTTP_AUTHORIZATION" => "Bearer s3cret").status
  end

  def test_accepts_correct_password_with_any_username
    assert_equal 200, request.get("/", "HTTP_AUTHORIZATION" => basic("outbox", "s3cret")).status
    assert_equal 200, request.get("/repos/x", "HTTP_AUTHORIZATION" => basic("anyone", "s3cret")).status
  end

  def test_git_paths_require_the_password_by_default
    assert_equal 401, request.get("/demo.git/info/refs?service=git-upload-pack").status
    assert_equal 200, request.get("/demo.git/info/refs", "HTTP_AUTHORIZATION" => basic("x", "s3cret")).status
  end

  def test_git_open_leaves_git_paths_open_and_ui_closed
    r = request(git_open: true)
    assert_equal 200, r.get("/demo.git/info/refs?service=git-upload-pack").status
    assert_equal 200, r.post("/demo.git/git-receive-pack").status
    assert_equal 401, r.get("/").status
    assert_equal 401, r.get("/repos/demo").status
    assert_equal 401, r.post("/repos/demo/branches/main/approve").status
    assert_equal 401, r.get("/demo.gitx/").status
  end
end
