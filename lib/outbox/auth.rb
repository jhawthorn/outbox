# frozen_string_literal: true

require "rack/auth/basic"

module Outbox
  # HTTP basic auth for the whole service. The username is ignored; only the
  # password matters. With git_open, requests to /<name>.git/* pass without
  # credentials so agents on the network can clone and push.
  class Auth
    def initialize(app, password:, git_open: false)
      raise ArgumentError, "password must not be empty" if password.to_s.empty?
      @app = app
      @password = password
      @git_open = git_open
    end

    def call(env)
      return @app.call(env) if @git_open && GitHttp::PATH_RE.match?(env["PATH_INFO"])

      request = Rack::Auth::Basic::Request.new(env)
      if request.provided? && request.basic? && valid?(request.credentials)
        @app.call(env)
      else
        [401, { "content-type" => "text/plain", "www-authenticate" => 'Basic realm="outbox"' }, ["Authentication required\n"]]
      end
    end

    private

    def valid?(credentials)
      _, password = credentials
      !password.nil? && Rack::Utils.secure_compare(password, @password)
    end
  end
end
