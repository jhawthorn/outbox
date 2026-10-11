# frozen_string_literal: true

Warning[:experimental] = false

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/outbox"

module OutboxTest
  GIT_ENV = {
    "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
    "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com",
    "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
    "GIT_TERMINAL_PROMPT" => "0",
  }.freeze

  # Git helpers for tests. These drive git directly, independent of the code
  # under test, so a bug in Outbox::Git can't hide a bug elsewhere.
  module GitHelpers
    def git(*args, chdir: nil)
      opts = chdir ? { chdir: chdir } : {}
      out, err, status = Open3.capture3(GIT_ENV, "git", *args, **opts)
      flunk "git #{args.join(" ")} failed:\n#{err}" unless status.success?
      out
    end

    def ref_exists?(repo_dir, ref)
      _, _, status = Open3.capture3(GIT_ENV, "git", "rev-parse", "--verify", "--quiet", ref, chdir: repo_dir)
      status.success?
    end

    def rev(repo_dir, ref)
      git("rev-parse", "--verify", "--quiet", ref, chdir: repo_dir).strip
    end

    # A bare repo with one commit on main, plus a working clone to make more
    # commits in. Returns [bare, work].
    def make_upstream(name, dir: @dir)
      bare = File.join(dir, "#{name}.git")
      work = File.join(dir, "#{name}-work")
      git("init", "--quiet", "--bare", "-b", "main", bare)
      git("init", "--quiet", "-b", "main", work)
      git("remote", "add", "origin", bare, chdir: work)
      commit(work, "README", "hello\n", "initial")
      push(work, "main")
      [bare, work]
    end

    def commit(work, file, content, message)
      FileUtils.mkdir_p(File.dirname(File.join(work, file)))
      File.write(File.join(work, file), content)
      git("add", "--", file, chdir: work)
      git("commit", "--quiet", "-m", message, chdir: work)
      rev(work, "HEAD")
    end

    def push(work, *refspecs, force: false)
      git("push", "--quiet", *(force ? ["--force"] : []), "origin", *refspecs, chdir: work)
    end

    def wait_until(what, timeout: 10)
      deadline = Time.now + timeout
      until yield
        flunk "timed out waiting for #{what}" if Time.now > deadline
        sleep 0.02
      end
    end
  end

  # Base for tests that need a staging repo: a temp data dir, one upstream
  # with an initial commit, a fetched Outbox::Repo named "demo", and a
  # working clone of the staging repo to push from.
  class RepoCase < Minitest::Test
    include GitHelpers

    def setup
      @dir = Dir.mktmpdir("outbox-unit")
      @saved_root = ENV["OUTBOX_DATA"]
      ENV["OUTBOX_DATA"] = File.join(@dir, "data")
      @upstream, @up_work = make_upstream("upstream")
      @repo = Outbox::Repo.create("demo", @upstream)
      @repo.fetch!
      @stage = File.join(@dir, "stage")
      git("clone", "--quiet", @repo.path, @stage)
    end

    def teardown
      if @saved_root
        ENV["OUTBOX_DATA"] = @saved_root
      else
        ENV.delete("OUTBOX_DATA")
      end
      FileUtils.rm_rf(@dir)
    end

    # Create a branch on upstream with one commit beyond main and fetch it
    # into the staging repo. Returns the commit sha.
    def add_upstream_branch(name)
      git("checkout", "--quiet", "-b", name, "main", chdir: @up_work)
      sha = commit(@up_work, "#{name}.txt", "#{name}\n", "#{name} commit")
      push(@up_work, name)
      git("checkout", "--quiet", "main", chdir: @up_work)
      @repo.fetch!
      sha
    end

    def stage_commit(file = "staged.txt", content = "staged\n", message = "Staged change", branch: "main")
      sha = commit(@stage, file, content, message)
      push(@stage, branch)
      sha
    end

    def upstream_commit(file = "up.txt", content = "upstream\n", message = "Upstream change")
      sha = commit(@up_work, file, content, message)
      push(@up_work, "main")
      sha
    end

    def status_of(branch = "main") = @repo.branch(branch).status
  end
end
