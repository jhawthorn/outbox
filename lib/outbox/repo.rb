# frozen_string_literal: true

require "fileutils"

module Outbox
  # A staging repository: a bare repo that clients push to. The real remote is
  # configured as the "upstream" remote, tracked under refs/remotes/upstream/*.
  #
  #   refs/heads/<branch>            what has been pushed to the outbox
  #   refs/remotes/upstream/<branch> what the real remote has (as of last fetch)
  #
  # A branch is "pending" whenever those two differ. Approving pushes the staged
  # ref to upstream; discarding resets the staged ref back to upstream.
  #
  # Reads (branches, commits, diff) are safe from any thread. Writes (fetch!,
  # approve!, discard!) are only ever called from the repo's RepoActor, which
  # serialises them.
  class Repo
    NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    class Branch
      attr_reader :name, :staged, :upstream, :status, :ahead, :behind

      def initialize(name:, staged:, upstream:, status:, ahead:, behind:)
        @name = name
        @staged = staged
        @upstream = upstream
        @status = status
        @ahead = ahead
        @behind = behind
      end

      def pending? = status != :synced
      def needs_force? = status == :diverged
    end

    # A commit with its complete message. The subject is the first line and
    # the body is everything after it, verbatim, so nothing in the message
    # can hide behind a tidy-looking first line.
    class Commit
      attr_reader :sha, :short, :author, :author_email, :date, :parents, :message

      def initialize(sha:, short:, author:, author_email:, date:, parents:, message:)
        @sha = sha
        @short = short
        @author = author
        @author_email = author_email
        @date = date
        @parents = parents
        @message = message
      end

      def subject = message.lines.first.to_s.chomp
      def body = message.lines.drop(1).join.strip
      def body? = !body.empty?
      def body_lines = body.empty? ? 0 : body.lines.size
      def root? = parents.empty?
      def merge? = parents.size > 1
    end

    SHA_RE = /\A[0-9a-f]{7,64}\z/
    LOG_FORMAT = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%B"

    attr_reader :name, :path

    # Where staging repos live. The container sets OUTBOX_DATA=/data; running
    # locally defaults to ./data in the project directory.
    DEFAULT_ROOT = File.expand_path("../../data", __dir__).freeze # expand_path returns a new String

    def self.root = ENV.fetch("OUTBOX_DATA", DEFAULT_ROOT)
    def self.repos_dir(root = self.root) = File.join(root, "repos")

    def self.all
      Dir.glob(File.join(repos_dir, "*.git")).sort.map { |p| new(File.basename(p, ".git")) }
    end

    def self.find(name)
      return nil unless name.to_s.match?(NAME_RE)
      repo = new(name)
      File.directory?(repo.path) ? repo : nil
    end

    def self.find!(name)
      find(name) or raise NotFound, "no repository named #{name.inspect}"
    end

    def self.create(name, upstream_url)
      raise ArgumentError, "invalid repository name #{name.inspect}" unless name.to_s.match?(NAME_RE)
      raise ArgumentError, "upstream URL is required" if upstream_url.to_s.strip.empty?
      repo = new(name)
      raise ArgumentError, "repository #{name} already exists" if File.exist?(repo.path)

      FileUtils.mkdir_p(repos_dir)
      Git.run("init", "--bare", "--quiet", repo.path)
      begin
        repo.git("config", "http.receivepack", "true")
        repo.git("config", "receive.denyNonFastForwards", "false")
        repo.git("config", "receive.denyDeleteCurrent", "ignore")
        repo.git("remote", "add", "upstream", upstream_url.strip)
        repo.git("config", "remote.upstream.fetch", "+refs/heads/*:refs/remotes/upstream/*")
        repo.git("config", "remote.upstream.tagOpt", "--no-tags")
        repo.generate_deploy_key
      rescue StandardError
        FileUtils.rm_rf(repo.path)
        raise
      end
      # The initial fetch can take minutes on a big upstream, so it is not
      # done here. The caller starts a Sync for it.
      repo
    end

    def initialize(name, root: self.class.root)
      @name = name
      @root = root
      @path = File.join(self.class.repos_dir(root), "#{name}.git")
    end

    def git(*args, input: nil)
      Git.run(*args, chdir: path, input: input, extra: git_env)
    end

    # --- upstream credentials ----------------------------------------------
    #
    # Each repo gets its own SSH keypair, generated here and never leaving
    # the data directory. The public half is added to the upstream as a
    # deploy key with write access, so a key can only ever touch one repo.
    # Nothing from the host's ~/.ssh is involved.

    def deploy_key_path = File.join(path, "deploy_key")

    def public_key
      File.read("#{deploy_key_path}.pub").strip
    rescue Errno::ENOENT
      nil
    end

    def generate_deploy_key
      out, err, status = Open3.capture3(
        { "PATH" => ENV["PATH"] },
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "outbox deploy key: #{name}", "-f", deploy_key_path,
        unsetenv_others: true,
      )
      raise GitError, "ssh-keygen: #{err.strip}" unless status.success?
      out
    rescue Errno::ENOENT
      # No ssh-keygen on this machine. Pushes fall back to whatever SSH the
      # environment provides, and the UI says so.
      nil
    end

    # When a deploy key exists, every git command for this repo uses it and
    # nothing else. GIT_SSH (unlike GIT_SSH_COMMAND) is executed directly by
    # git without a shell; the wrapper reads the key path from the
    # environment and execs ssh with separate arguments.
    SSH_WRAPPER = File.expand_path("../../bin/outbox-ssh", __dir__).freeze

    def git_env
      return {} unless File.exist?(deploy_key_path)
      {
        "GIT_SSH" => SSH_WRAPPER,
        "OUTBOX_SSH_KEY" => deploy_key_path,
        "OUTBOX_KNOWN_HOSTS" => File.join(@root, "known_hosts"),
      }
    end

    def upstream_url
      git("config", "remote.upstream.url").strip
    end

    def destroy!
      FileUtils.rm_rf(path)
    end

    # --- refs ---------------------------------------------------------------

    def staged_refs = refs("refs/heads/")
    def upstream_refs = refs("refs/remotes/upstream/")

    def refs(prefix)
      out = git("for-each-ref", "--format=%(refname) %(objectname)", prefix.chomp("/"))
      out.each_line.with_object({}) do |line, h|
        ref, sha = line.split
        short = ref.delete_prefix(prefix)
        next if short == "HEAD"
        h[short] = sha
      end
    end

    def branches
      staged = staged_refs
      upstream = upstream_refs
      (staged.keys | upstream.keys).sort.map { |n| branch_info(n, staged[n], upstream[n]) }
    end

    def branch(name)
      staged = staged_refs[name]
      upstream = upstream_refs[name]
      raise NotFound, "no branch named #{name.inspect}" if staged.nil? && upstream.nil?
      branch_info(name, staged, upstream)
    end

    def pending_branches = branches.select(&:pending?)

    # --- sync with upstream -------------------------------------------------

    # Fetch upstream. Branches with nothing staged follow upstream; branches
    # with staged changes are left alone (they show up as diverged if upstream
    # moved underneath them). Yields git's progress lines if a block is given.
    def fetch!(&progress)
      before = upstream_refs
      if progress
        Git.stream("fetch", "--prune", "--progress", "upstream", chdir: path, extra: git_env, &progress)
      else
        git("fetch", "--prune", "--quiet", "upstream")
      end
      after = upstream_refs
      staged = staged_refs

      after.each do |branch, sha|
        old = before[branch]
        untouched = staged[branch].nil? ? old.nil? : staged[branch] == old
        git("update-ref", "refs/heads/#{branch}", sha) if untouched && staged[branch] != sha
      end

      (before.keys - after.keys).each do |branch|
        next unless staged[branch] == before[branch]
        git("update-ref", "-d", "refs/heads/#{branch}", staged[branch])
      end
    end

    # True when HEAD points at a branch that exists. A freshly created repo's
    # HEAD points at a branch that may not exist upstream, which makes clones
    # from the outbox warn and check out nothing.
    def head_valid?
      git("rev-parse", "--verify", "--quiet", "HEAD")
      true
    rescue GitError
      false
    end

    def set_default_head!
      git("remote", "set-head", "upstream", "--auto")
      target = git("symbolic-ref", "refs/remotes/upstream/HEAD").strip
      branch = target.delete_prefix("refs/remotes/upstream/")
      git("symbolic-ref", "HEAD", "refs/heads/#{branch}")
    rescue GitError
      # Empty upstream, or one that does not advertise HEAD. Leave the default.
    end

    # --- review -------------------------------------------------------------

    def approve!(name, force: false)
      b = branch(name)
      ref = "refs/heads/#{name}"
      case b.status
      when :synced
        raise GitError, "#{name} is already in sync with upstream"
      when :diverged
        raise GitError, "#{name} has diverged from upstream; approving requires force" unless force
        git("push", "--quiet", "upstream", "--force-with-lease=#{ref}:#{b.upstream}", "#{ref}:#{ref}")
      when :deleted
        git("push", "--quiet", "upstream", "--force-with-lease=#{ref}:#{b.upstream}", ":#{ref}")
      when :new
        git("push", "--quiet", "upstream", "--force-with-lease=#{ref}:", "#{ref}:#{ref}")
      when :ready
        git("push", "--quiet", "upstream", "--force-with-lease=#{ref}:#{b.upstream}", "#{ref}:#{ref}")
      end
      # git push updates the remote-tracking ref itself, but be explicit.
      if b.staged
        git("update-ref", "refs/remotes/upstream/#{name}", b.staged)
      else
        git("update-ref", "-d", "refs/remotes/upstream/#{name}")
      end
      b
    end

    def discard!(name)
      b = branch(name)
      if b.upstream
        git("update-ref", "refs/heads/#{name}", b.upstream)
      else
        git("update-ref", "-d", "refs/heads/#{name}", b.staged)
      end
      b
    end

    # Commits that approving would add to upstream.
    def commits(name, limit: 200)
      b = branch(name)
      log(limit, *incoming_revs(b))
    end

    # Commits on upstream that approving would remove (diverged or deleted).
    def outgoing_commits(name, limit: 200)
      b = branch(name)
      case b.status
      when :deleted  then log(limit, "refs/remotes/upstream/#{name}", "--not", "--branches")
      when :diverged then log(limit, "refs/heads/#{name}..refs/remotes/upstream/#{name}")
      else []
      end
    end

    # Everything approving this branch would change on upstream, as one patch.
    def diff(name, max_bytes: MAX_PATCH_BYTES)
      b = branch(name)
      from, to = diff_endpoints(b)
      return Diff::Patch.new(stat: "", text: "") if from.nil?
      patch(from, to, max_bytes)
    end

    # One commit, with its full message. The sha must already be known to
    # belong to this repo (callers look it up in a commits list first).
    def commit_detail(sha)
      raise ArgumentError, "not a commit sha: #{sha.inspect}" unless sha.match?(SHA_RE)
      log(1, sha).first or raise NotFound, "no commit #{sha}"
    end

    # What one commit changed relative to its first parent (or to nothing,
    # for a root commit).
    def commit_diff(sha, max_bytes: MAX_PATCH_BYTES)
      c = commit_detail(sha)
      patch(c.parents.first || empty_tree, c.sha, max_bytes)
    end

    MAX_PATCH_BYTES = 2_000_000

    private

    def branch_info(name, staged, upstream)
      status, ahead, behind =
        if upstream.nil?
          [:new, count("refs/heads/#{name}", "--not", "--remotes=upstream"), 0]
        elsif staged.nil?
          [:deleted, 0, count("refs/remotes/upstream/#{name}", "--not", "--branches")]
        elsif staged == upstream
          [:synced, 0, 0]
        else
          behind, ahead = git("rev-list", "--left-right", "--count",
                              "refs/remotes/upstream/#{name}...refs/heads/#{name}").split.map(&:to_i)
          [behind.zero? ? :ready : :diverged, ahead, behind]
        end
      Branch.new(name:, staged:, upstream:, status:, ahead:, behind:)
    end

    def count(*revs)
      git("rev-list", "--count", *revs).to_i
    end

    def incoming_revs(b)
      case b.status
      when :new then ["refs/heads/#{b.name}", "--not", "--remotes=upstream"]
      when :ready, :diverged then ["refs/remotes/upstream/#{b.name}..refs/heads/#{b.name}"]
      else nil
      end
    end

    # Commits are NUL-separated because the full message is included and
    # may contain anything.
    def log(limit, *revs)
      return [] if revs.compact.empty?
      out = git("log", "-z", "-n", limit.to_s, "--format=#{LOG_FORMAT}", *revs)
      out.split("\0").map do |record|
        sha, short, author, author_email, date, parents, message = record.split("\x1f", 7)
        Commit.new(sha:, short:, author:, author_email:, date:, parents: parents.split,
                   message: message.to_s.chomp)
      end
    end

    def diff_endpoints(b)
      case b.status
      when :ready, :diverged
        # Three-dot: only what the staged branch adds since it forked from upstream.
        [git("merge-base", b.upstream, b.staged).strip, b.staged]
      when :new
        [nearest_upstream_base(b.staged), b.staged]
      else
        [nil, nil]
      end
    end

    def patch(from, to, max_bytes)
      stat = git("diff", "--shortstat", "-M", from, to).strip
      text = git("diff", "-M", from, to)
      truncated = false
      if text.bytesize > max_bytes
        text = text.byteslice(0, max_bytes)
        text = text[0..text.rindex("\n")] if text.include?("\n")
        text = text.scrub
        truncated = true
      end
      Diff::Patch.new(stat:, text:, truncated:)
    end

    # For a brand-new branch, diff against the closest point on any upstream
    # branch; fall back to the empty tree when upstream is empty or unrelated.
    def nearest_upstream_base(sha)
      bases = upstream_refs.values.uniq.first(50).filter_map do |up|
        git("merge-base", up, sha).strip
      rescue GitError
        nil
      end
      return empty_tree if bases.empty?
      # Pick the most recent base (the branch it was actually forked from).
      bases.uniq.max_by { |base| git("show", "-s", "--format=%ct", base).to_i }
    end

    def empty_tree
      git("hash-object", "-t", "tree", "/dev/null").strip
    end
  end
end
