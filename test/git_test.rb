# frozen_string_literal: true

require_relative "test_helper"

class GitTest < Minitest::Test
  Git = Outbox::Git

  # An alias with a leading "!" runs a shell command, which lets us observe
  # exactly what environment git's children see.
  PRINT_ENV = ["-c", "alias.penv=!env", "penv"].freeze

  def test_run_returns_stdout
    assert_match(/\Agit version /, Git.run("--version"))
  end

  def test_run_raises_git_error_with_the_command_and_stderr
    Dir.mktmpdir do |dir|
      err = assert_raises(Outbox::GitError) { Git.run("rev-parse", "--verify", "HEAD", chdir: dir) }
      assert_match(/\Agit rev-parse: /, err.message)
      assert_includes err.message, "not a git repository"
    end
  end

  def test_subprocess_environment_is_scrubbed
    ENV["OUTBOX_LEAK_TEST"] = "secret"
    out = Git.run(*PRINT_ENV)
    refute_includes out, "OUTBOX_LEAK_TEST="
    assert_includes out, "GIT_TERMINAL_PROMPT=0"
    assert_includes out, "GIT_CONFIG_NOSYSTEM=1"
    assert_includes out, "PATH="
  ensure
    ENV.delete("OUTBOX_LEAK_TEST")
  end

  def test_ssh_variables_from_the_server_are_not_passed_through
    ENV["GIT_SSH_COMMAND"] = "ssh -i /somewhere/private"
    ENV["SSH_AUTH_SOCK"] = "/tmp/agent.sock"
    out = Git.run(*PRINT_ENV)
    refute_includes out, "GIT_SSH_COMMAND="
    refute_includes out, "SSH_AUTH_SOCK="
  ensure
    ENV.delete("GIT_SSH_COMMAND")
    ENV.delete("SSH_AUTH_SOCK")
  end

  def test_extra_environment_applies_to_one_call_only
    out = Git.run(*PRINT_ENV, extra: { "OUTBOX_EXTRA" => "yes" })
    assert_includes out, "OUTBOX_EXTRA=yes"
    refute_includes Git.run(*PRINT_ENV), "OUTBOX_EXTRA="
  end

  def test_stream_yields_stderr_split_on_cr_and_lf
    lines = []
    Git.stream("-c", "alias.prog=!printf 'a\\rb\\nc' >&2", "prog") { |l| lines << l }
    assert_equal %w[a b c], lines
  end

  def test_stream_returns_stdout
    out = Git.stream("-c", "alias.say=!echo hello", "say") { |_| }
    assert_equal "hello\n", out
  end

  def test_stream_raises_with_the_last_stderr_lines
    err = assert_raises(Outbox::GitError) do
      Git.stream("-c", "alias.bad=!echo boom >&2; exit 3", "bad") { |_| }
    end
    assert_includes err.message, "boom"
  end
end
