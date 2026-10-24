# frozen_string_literal: true

require "open3"

module Outbox
  class Error < StandardError; end
  class GitError < Error; end
  class NotFound < Error; end

  # Thin wrapper around the git binary. Arguments are passed as an array,
  # never through a shell, and git gets a minimal environment rather than
  # inheriting the server's.
  module Git
    # The only variables from the server's environment that git may see.
    # Nothing that could authenticate: the upstream token is handed to the
    # fetch and push commands alone (Repo#remote_env), never inherited.
    # Git's global config is disabled below, so nothing in ~/.gitconfig
    # applies even though HOME is passed.
    PASSTHROUGH = %w[PATH HOME].freeze

    # Commands that talk to upstream can hang forever on a dead connection,
    # and the repo would then show as working until the server restarts.
    # run gives up after REMOTE_TIMEOUT seconds in all; stream, which
    # reports progress, after IDLE_TIMEOUT seconds without any.
    REMOTE_TIMEOUT = 30 * 60
    IDLE_TIMEOUT = 5 * 60

    def self.env
      base = {
        "LANG" => "C.UTF-8",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
      }
      PASSTHROUGH.each { |k| base[k] = ENV[k] if ENV.key?(k) }
      base
    end

    # extra: additional variables for this one invocation (upstream credentials).
    # ok: the exit statuses that are not failures (merge-tree exits 1 for a
    # conflict and still writes its tree). binary: the output as git wrote
    # it, not read as UTF-8 (file contents served raw).
    def self.run(*args, chdir: nil, input: nil, extra: {}, timeout: nil, ok: [0], binary: false)
      opts = { stdin_data: input || "", unsetenv_others: true }
      opts[:chdir] = chdir if chdir
      out, err, status = timeout ? capture_within(timeout, env.merge(extra), args, opts) : Open3.capture3(env.merge(extra), "git", *args, **opts)
      raise GitError, failure_message(args, err, status) unless ok.include?(status.exitstatus)
      binary ? out.b : out.force_encoding(Encoding::UTF_8).scrub
    end

    # Open3.capture3 with a deadline: kills git if it is still running after
    # timeout seconds.
    def self.capture_within(timeout, env, args, opts)
      stdin_data = opts.delete(:stdin_data)
      Open3.popen3(env, "git", *args, **opts) do |stdin, stdout, stderr, wait|
        writer = Thread.new { stdin.write(stdin_data) rescue nil; stdin.close rescue nil }
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        [writer, out, err].each { |t| t.report_on_exception = false }
        unless wait.join(timeout)
          kill(wait)
          raise GitError, "git #{args.first}: timed out after #{timeout}s"
        end
        writer.join
        [out.value, err.value, wait.value]
      end
    end

    def self.kill(wait)
      Process.kill("KILL", wait.pid)
    rescue Errno::ESRCH
      # Already exited.
    end

    # Like run, but yields each line git writes to stderr as it happens. Git
    # separates progress updates with \r, so those are yielded as lines too.
    # Used for long-running network operations so the UI can show progress.
    def self.stream(*args, chdir: nil, extra: {}, idle_timeout: IDLE_TIMEOUT)
      opts = { unsetenv_others: true }
      opts[:chdir] = chdir if chdir
      Open3.popen3(env.merge(extra), "git", *args, **opts) do |stdin, stdout, stderr, wait|
        stdin.close
        reader = Thread.new { stdout.read }
        reader.report_on_exception = false
        all = +""
        partial = +""
        loop do
          chunk = begin
            unless stderr.wait_readable(idle_timeout)
              kill(wait)
              raise GitError, "git #{args.first}: no output for #{idle_timeout}s, gave up"
            end
            stderr.readpartial(4096)
          rescue EOFError
            break
          end
          all << chunk
          partial << chunk
          lines = partial.split(/\r|\n/, -1)
          partial = lines.pop
          lines.each { |l| yield l.strip unless l.strip.empty? }
        end
        yield partial.strip unless partial.strip.empty?
        out = reader.value
        raise GitError, failure_message(args, all, wait.value) unless wait.value.success?
        out.force_encoding(Encoding::UTF_8).scrub
      end
    end

    # Yields each line git writes to stdout as it is written, and stops git
    # as soon as the block breaks (or after timeout seconds), for reading
    # only as much of a long log as is needed.
    def self.each_line(*args, chdir: nil, timeout: nil, sep: "\n")
      opts = { unsetenv_others: true, err: File::NULL }
      opts[:chdir] = chdir if chdir
      deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      Open3.popen2(env, "git", *args, **opts) do |stdin, stdout, wait|
        stdin.close
        begin
          stdout.each_line(sep) do |line|
            yield line.force_encoding(Encoding::UTF_8).scrub
            break if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          end
        ensure
          kill(wait) if wait.alive?
          wait.value
        end
      end
    end

    def self.failure_message(args, err, status)
      detail = err.to_s.force_encoding(Encoding::UTF_8).scrub.split(/\r|\n/).map(&:strip).reject(&:empty?).last(5).join("\n")
      detail = "exit #{status.exitstatus}" if detail.empty?
      "git #{args.first}: #{detail}"
    end
  end
end
