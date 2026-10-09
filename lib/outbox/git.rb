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
    PASSTHROUGH = %w[PATH HOME GIT_SSH_COMMAND SSH_AUTH_SOCK GIT_CONFIG_GLOBAL].freeze

    def self.env
      base = {
        "LANG" => "C.UTF-8",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_CONFIG_NOSYSTEM" => "1",
      }
      PASSTHROUGH.each { |k| base[k] = ENV[k] if ENV.key?(k) }
      base
    end

    def self.run(*args, chdir: nil, input: nil)
      opts = { stdin_data: input || "", unsetenv_others: true }
      opts[:chdir] = chdir if chdir
      out, err, status = Open3.capture3(env, "git", *args, **opts)
      raise GitError, failure_message(args, err, status) unless status.success?
      out.force_encoding(Encoding::UTF_8).scrub
    end

    # Like run, but yields each line git writes to stderr as it happens. Git
    # separates progress updates with \r, so those are yielded as lines too.
    # Used for long-running network operations so the UI can show progress.
    def self.stream(*args, chdir: nil)
      opts = { unsetenv_others: true }
      opts[:chdir] = chdir if chdir
      Open3.popen3(env, "git", *args, **opts) do |stdin, stdout, stderr, wait|
        stdin.close
        reader = Thread.new { stdout.read }
        all = +""
        partial = +""
        loop do
          chunk = begin
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

    def self.failure_message(args, err, status)
      detail = err.to_s.force_encoding(Encoding::UTF_8).scrub.split(/\r|\n/).map(&:strip).reject(&:empty?).last(5).join("\n")
      detail = "exit #{status.exitstatus}" if detail.empty?
      "git #{args.first}: #{detail}"
    end
  end
end
