require "open3"

module Outbox
  # Rack middleware that serves git smart-HTTP for /<name>.git/* by delegating
  # to `git http-backend` as a CGI. Everything else falls through to the app.
  class GitHttp
    PATH_RE = %r{\A/([A-Za-z0-9][A-Za-z0-9._-]*)\.git(/.*)?\z}
    CHUNK = 64 * 1024

    def initialize(app, root)
      @app = app
      @root = root
    end

    def call(env)
      m = PATH_RE.match(env["PATH_INFO"])
      return @app.call(env) unless m

      repo_dir = File.join(@root, "#{m[1]}.git")
      return not_found unless File.directory?(repo_dir)

      serve(env)
    end

    private

    def not_found
      [404, { "content-type" => "text/plain" }, ["repository not found\n"]]
    end

    def serve(env)
      # http-backend only serves the local repo; it never talks to upstream,
      # so it gets no SSH or credential variables at all.
      cgi = {
        "PATH" => ENV["PATH"],
        "LANG" => "C.UTF-8",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_PROJECT_ROOT" => @root,
        "GIT_HTTP_EXPORT_ALL" => "1",
        "PATH_INFO" => env["PATH_INFO"],
        "REQUEST_METHOD" => env["REQUEST_METHOD"],
        "QUERY_STRING" => env["QUERY_STRING"].to_s,
        "CONTENT_TYPE" => env["CONTENT_TYPE"].to_s,
        "REMOTE_ADDR" => env["REMOTE_ADDR"].to_s,
        "SERVER_PROTOCOL" => env["SERVER_PROTOCOL"].to_s,
      }
      cgi["CONTENT_LENGTH"] = env["CONTENT_LENGTH"] if env["CONTENT_LENGTH"]
      cgi["HTTP_CONTENT_ENCODING"] = env["HTTP_CONTENT_ENCODING"] if env["HTTP_CONTENT_ENCODING"]
      cgi["HTTP_GIT_PROTOCOL"] = env["HTTP_GIT_PROTOCOL"] if env["HTTP_GIT_PROTOCOL"]

      stdin, stdout, stderr, wait = Open3.popen3(cgi, "git", "http-backend", unsetenv_others: true)

      writer = Thread.new do
        input = env["rack.input"]
        while (chunk = input.read(CHUNK))
          stdin.write(chunk)
        end
      rescue IOError, Errno::EPIPE
        # backend closed early; fine
      ensure
        stdin.close unless stdin.closed?
      end

      drain = Thread.new do
        while (line = stderr.gets)
          $stderr.puts("git http-backend: #{line}")
        end
      end

      status = 200
      headers = {}
      while (line = stdout.gets)
        line = line.chomp
        break if line.empty?
        key, value = line.split(":", 2)
        next unless value
        key = key.strip.downcase
        value = value.strip
        if key == "status"
          status = value.to_i
        else
          headers[key] = value
        end
      end

      body = Body.new(stdout, [writer, drain], wait, stderr)
      [status, headers, body]
    end

    class Body
      def initialize(io, threads, wait, stderr)
        @io = io
        @threads = threads
        @wait = wait
        @stderr = stderr
      end

      def each
        while (chunk = @io.read(CHUNK))
          yield chunk
        end
      ensure
        close
      end

      def close
        @io.close unless @io.closed?
        @threads.each(&:join)
        @stderr.close unless @stderr.closed?
        @wait.value
      end
    end
  end
end
