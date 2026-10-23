# frozen_string_literal: true

require "fileutils"

module Outbox
  # A staging repository: a bare repo that clients push to. Each real remote
  # it tracks is a git remote of the same name, fetched into
  # refs/remotes/<remote>/*. One of them, the push remote (outbox.push in the
  # repo's config), is where approvals go; in this file "upstream" means that
  # one, whatever it is called. The others are only fetched.
  #
  #   refs/heads/<branch>            what has been pushed to the outbox
  #   refs/remotes/<push>/<branch>   what the real remote has (as of last fetch)
  #   refs/remotes/<other>/<branch>  what a fetch-only remote has
  #
  # A branch is "pending" whenever the first two differ. Approving pushes the
  # staged ref to upstream; discarding resets the staged ref back to upstream.
  # Commits any remote has are not a branch's own, and a new branch is shown
  # against the nearest of the repo's bases (outbox.base).
  #
  # Reads (branches, commits, diff) are safe from any thread. Writes (fetch!,
  # approve!, discard!) are only ever called from the repo's RepoActor, which
  # serialises them. Config.apply! also writes, to the remotes alone.
  class Repo
    # No leading "." or "-": those would be path traversal or a git flag.
    NAME_RE = /\A[A-Za-z0-9_][A-Za-z0-9._-]*\z/

    # A remote's name is a ref path component in every clone, so no "/";
    # no "." either, which is kept free for scoping a remote to one repo.
    REMOTE_NAME_RE = /\A[A-Za-z0-9_][A-Za-z0-9_-]*\z/

    # Clones of a staging repo call it origin, and fetch every
    # refs/remotes/<remote>/* beside it, so no remote may be called that.
    RESERVED_REMOTES = %w[origin HEAD].freeze

    # The push remote of a repo created before remotes had names.
    LEGACY_PUSH = "upstream"

    class Branch
      attr_reader :name, :staged, :upstream, :status, :ahead, :behind, :onto, :picked_up, :time

      # ahead: commits approving adds to upstream; behind: commits upstream
      # has that the staged branch lacks. A rebased branch (diverged, and
      # moved onto a commit upstream has on another branch) also has onto,
      # that commit, and picked_up, how many commits it brought in that
      # upstream's version of the branch lacks. Those are not counted as
      # ahead: approving does put them on upstream's copy of the branch,
      # but they are upstream's own work. time: committer date of the tip
      # (staged if there is one, else upstream's).
      def initialize(name:, staged:, upstream:, status:, ahead:, behind:, time:, onto: nil, picked_up: 0)
        @name = name
        @staged = staged
        @upstream = upstream
        @status = status
        @ahead = ahead
        @behind = behind
        @onto = onto
        @picked_up = picked_up
        @time = time
      end

      def pending? = status != :synced
      def needs_force? = status == :diverged
      def rebased? = !onto.nil?
    end

    # A commit with its complete message. The subject is the first line and
    # the body is everything after it, verbatim, so nothing in the message
    # can hide behind a tidy-looking first line.
    class Commit
      attr_reader :sha, :short, :author, :author_email, :date,
                  :committer, :committer_email, :commit_date, :parents, :message

      def initialize(sha:, short:, author:, author_email:, date:,
                     committer:, committer_email:, commit_date:, parents:, message:)
        @sha = sha
        @short = short
        @author = author
        @author_email = author_email
        @date = date
        @committer = committer
        @committer_email = committer_email
        @commit_date = commit_date
        @parents = parents
        @message = message
      end

      def subject = message.lines.first.to_s.chomp
      def body = message.lines.drop(1).join.strip
      def body? = !body.empty?
      def body_lines = body.empty? ? 0 : body.lines.size
      def root? = parents.empty?
      def merge? = parents.size > 1

      # The author is whoever the commit claims wrote it; the committer is
      # whoever actually created the object. They differ after rebases,
      # amends and cherry-picks, and when someone sets one by hand.
      def committer_differs? = committer != author || committer_email != author_email
    end

    # Where a rebased branch went: onto is the commit it now builds on, ref
    # a remote branch that has it, as "remote/branch" (a base when one does),
    # and from the commit upstream's version builds on, or nil when the two
    # histories are unrelated. replay is the tree of upstream's version
    # moved onto the new base by git merge-tree, which is what the staged
    # tip is diffed against, so the diff shows what changed beyond the move;
    # nil when the replay was not possible. conflicts names the files the
    # replay could not merge: in the replay they hold conflict markers, so
    # the diff shows how each was resolved.
    class Rebase
      attr_reader :onto, :ref, :from, :replay, :conflicts

      def initialize(onto:, ref:, from:, replay:, conflicts:)
        @onto = onto
        @ref = ref
        @from = from
        @replay = replay
        @conflicts = conflicts
      end

      def replayed? = !replay.nil?
    end

    # How the staged commits of a diverged branch correspond to the ones
    # upstream has for it, as git range-diff pairs them: each staged commit
    # is the same patch as an upstream one (unchanged), a reworked version
    # of one (changed), or new; each upstream commit is carried over one of
    # those ways or dropped.
    class Rewrite
      attr_reader :unchanged, :changed

      # unchanged, changed: { staged sha => upstream sha }.
      def initialize(unchanged:, changed:)
        @unchanged = unchanged
        @changed = changed
      end

      # :unchanged or :changed with the upstream sha, or nil for a new commit.
      def of(sha)
        return [:unchanged, unchanged[sha]] if unchanged.key?(sha)
        return [:changed, changed[sha]] if changed.key?(sha)
        nil
      end

      def carried = @carried ||= (unchanged.values + changed.values).to_h { |sha| [sha, true] }

      # Whether an upstream commit lives on in a staged one.
      def carried?(sha) = carried.key?(sha)
    end

    # Where a branch's incoming commits start: the commit they build on, and
    # the remote branch it is on, as "remote/branch".
    class Base
      attr_reader :commit, :ref

      def initialize(commit:, ref:)
        @commit = commit
        @ref = ref
      end
    end

    SHA_RE = /\A[0-9a-f]{7,64}\z/
    LOG_FORMAT = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f%P%x1f%B"

    attr_reader :name, :path

    # Where staging repos live. The container sets OUTBOX_DATA=/data; running
    # locally defaults to ./data in the project directory.
    DEFAULT_ROOT = File.expand_path("../../data", __dir__).freeze # expand_path returns a new String

    def self.root = ENV.fetch("OUTBOX_DATA", DEFAULT_ROOT)
    def self.repos_dir(root = self.root) = File.join(root, "repos")

    # The one credential for every https upstream, from the server's
    # environment. nil when unset or blank. Read here in the main Ractor and
    # handed to repo actors, like the data root.
    def self.upstream_token
      token = ENV["OUTBOX_UPSTREAM_TOKEN"].to_s.strip
      token.empty? ? nil : token
    end

    # Remotes are https URLs, authenticated with the token, or local paths.
    # Anything else (ssh, git://) is refused: there is nothing here to
    # authenticate it with, and a failed fetch later would be harder to read
    # than a message now. what names the URL in the message. Returns the
    # problem, or nil.
    def self.upstream_url_problem(url, what = "upstream")
      url = url.to_s.strip
      return "#{what} URL is required" if url.empty?
      return nil if url.match?(%r{\Ahttps?://}i) || url.match?(%r{\A(/|\./|\.\./|file://)})
      "#{what} #{url} must be an https URL (authenticated with OUTBOX_UPSTREAM_TOKEN) or a local path"
    end

    # Whether name can be a branch, by git check-ref-format's rules, without
    # running git: config is checked on every index page.
    def self.branch_name?(name)
      name = name.to_s
      !name.empty? && !name.match?(%r{[\x00-\x20\x7f~^:?*\[\\]|\.\.|@\{|//|\A/|/\z|\.\z|\.lock(\z|/)|(\A|/)\.|\A-|\A@\z})
    end

    # Installed into every staging repo: update limits pushes to branches,
    # post-receive marks that one landed (pushed_at).
    HOOKS = %w[update post-receive].to_h { |name| [name, File.expand_path("hooks/#{name}", __dir__).freeze] }.freeze

    def self.all(root = self.root)
      Dir.glob(File.join(repos_dir(root), "*.git")).sort.map { |p| new(File.basename(p, ".git"), root: root) }
    end

    def self.find(name)
      return nil unless name.to_s.match?(NAME_RE)
      repo = new(name)
      File.directory?(repo.path) ? repo : nil
    end

    def self.find!(name)
      find(name) or raise NotFound, "no repository named #{name.inspect}"
    end

    # A staging repo with one remote, the push remote, called push. Any
    # others come from configure!.
    def self.create(name, upstream_url, root: self.root, push: LEGACY_PUSH)
      raise ArgumentError, "invalid repository name #{name.inspect}" unless name.to_s.match?(NAME_RE)
      raise ArgumentError, "invalid remote name #{push.inspect}" unless push.match?(REMOTE_NAME_RE)
      if (problem = upstream_url_problem(upstream_url))
        raise ArgumentError, problem
      end
      repo = new(name, root: root)
      raise ArgumentError, "repository #{name} already exists" if File.exist?(repo.path)

      FileUtils.mkdir_p(repos_dir(root))
      Git.run("init", "--bare", "--quiet", repo.path)
      begin
        repo.git("config", "http.receivepack", "true")
        repo.git("config", "receive.denyNonFastForwards", "false")
        repo.git("config", "receive.denyDeleteCurrent", "ignore")
        # Bare repos don't keep reflogs by default. We want one per staged
        # branch: it is the push history, and it is how force pushes show.
        repo.git("config", "core.logAllRefUpdates", "true")
        repo.add_remote(push, upstream_url.strip)
        repo.git("config", "outbox.push", push)
        repo.install_hooks
      rescue StandardError
        FileUtils.rm_rf(repo.path)
        raise
      end
      # The initial fetch can take minutes on a big upstream, so it is not
      # done here. The caller starts a Sync for it.
      repo
    end

    def initialize(name, root: self.class.root, upstream_token: self.class.upstream_token)
      @name = name
      @root = root
      @upstream_token = upstream_token
      @path = File.join(self.class.repos_dir(root), "#{name}.git")
    end

    # The staging repo for the outbox's own configuration (Outbox::Config).
    def config? = name == Config::NAME

    # extra: environment for this one command; remote_env for the ones that
    # talk to upstream, nothing for the rest.
    def git(*args, input: nil, extra: {}, timeout: nil, ok: [0])
      Git.run(*args, chdir: path, input: input, extra: extra, timeout: timeout, ok: ok)
    end

    # --- upstream credentials ----------------------------------------------

    # Git runs GIT_ASKPASS directly, no shell, with the prompt as its one
    # argument, and the program answers with the token from this
    # environment. Only fetch and push get it: the commands that read the
    # local repo never talk to upstream.
    ASKPASS = File.expand_path("../../bin/outbox-askpass", __dir__).freeze

    def remote_env
      return {} unless @upstream_token
      { "GIT_ASKPASS" => ASKPASS, "OUTBOX_UPSTREAM_TOKEN" => @upstream_token }
    end

    # --- remotes ------------------------------------------------------------

    # The remote approvals go to. A repo from before remotes had names has no
    # outbox.push, and its one remote is called upstream.
    def push_remote = settings[:push]

    # Every remote, { name => url }, the push remote first.
    def remotes = settings[:remotes]

    # The bases, as "remote/branch", in the order configured. Empty when
    # none are, and then the push remote's default branch is the base.
    def configured_bases = settings[:bases]

    def upstream_url = remotes[push_remote].to_s

    # Whether fetching and pushing need the token.
    def remote_upstream? = remotes.values.any? { |url| url.match?(%r{\Ahttps?://}i) }

    # Make the remotes and bases what the configuration says (Config.apply!
    # keeps them current; git needs the URLs here to fetch and push).
    # remotes is { name => url }. A push remote that only changes its name
    # is renamed, refs and all, so what upstream has is known throughout.
    # Remotes no longer listed are removed with their refs, which a fetch
    # would bring back. Returns whether there is anything new to fetch: a
    # remote added or pointed somewhere else.
    def configure!(push:, remotes:, bases:)
      current = self.remotes.dup
      old = push_remote
      if old != push && current.key?(old) && !current.key?(push)
        git("remote", "rename", old, push)
        current[push] = current.delete(old)
      end
      fetch_needed = false
      remotes.each do |name, url|
        if !current.key?(name)
          add_remote(name, url)
          fetch_needed = true
        elsif current[name] != url
          git("remote", "set-url", name, url)
          fetch_needed = true
        end
      end
      (current.keys - remotes.keys).each { |name| git("remote", "remove", name) }
      git("config", "outbox.push", push) unless settings[:push_set] && old == push
      unless configured_bases == bases
        git("config", "--unset-all", "outbox.base", ok: [0, 5])
        bases.each { |b| git("config", "--add", "outbox.base", b) }
      end
      @settings = nil
      fetch_needed
    end

    # Each remote's branches under refs/remotes/<name>/, never its tags.
    def add_remote(name, url)
      git("remote", "add", name, url)
      git("config", "remote.#{name}.fetch", "+refs/heads/*:refs/remotes/#{name}/*")
      git("config", "remote.#{name}.tagOpt", "--no-tags")
    end

    def destroy!
      FileUtils.rm_rf(path)
    end

    # Pushes may only update refs/heads/*. Enforced by git itself via the
    # update hook, so it holds for any server that runs receive-pack here.
    # The post-receive hook touches PUSHED_MARKER after every push.
    def install_hooks
      HOOKS.each do |name, source|
        target = File.join(path, "hooks", name)
        next if File.exist?(target) && File.read(target) == File.read(source)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
        File.chmod(0o755, target)
      end
    end

    PUSHED_MARKER = "outbox-pushed"

    # When the last push landed, to the nanosecond, as the post-receive hook
    # left it; nil before the first. Only a stat, so cheap enough to ask of
    # every repo every second (PushWatcher). Not last_push_at, which reads
    # the reflogs and is what the pages show.
    def pushed_at
      File.mtime(File.join(path, PUSHED_MARKER))
    rescue SystemCallError
      nil
    end

    # --- refs ---------------------------------------------------------------

    STAGED_PREFIX = "refs/heads/"
    REMOTES_PREFIX = "refs/remotes/"

    def upstream_prefix = "#{REMOTES_PREFIX}#{push_remote}/"

    # Where upstream's copy of a branch is kept.
    def upstream_ref(branch) = "#{upstream_prefix}#{branch}"

    def staged_refs = all_refs[0]
    def upstream_refs = all_refs[1]

    # Both ref namespaces in one git call. Returns [staged, upstream], each
    # a hash of branch name to sha. The third element is a hash of branch
    # name to the commit time of its tip (staged if there is one, else
    # upstream's), as an integer.
    def all_refs
      staged = {}
      upstream = {}
      times = {}
      prefix = upstream_prefix
      out = git("for-each-ref", "--format=%(refname) %(objectname) %(committerdate:unix)", STAGED_PREFIX.chomp("/"), prefix.chomp("/"))
      out.each_line do |line|
        ref, sha, time = line.split
        if ref.start_with?(STAGED_PREFIX)
          name = ref.delete_prefix(STAGED_PREFIX)
          staged[name] = sha
          times[name] = time.to_i
        elsif ref.start_with?(prefix)
          name = ref.delete_prefix(prefix)
          next if name == "HEAD"
          upstream[name] = sha
          times[name] ||= time.to_i
        end
      end
      [staged, upstream, times]
    end

    # Most recently committed first, ties by name.
    def branches
      staged, upstream, times = all_refs
      names = (staged.keys | upstream.keys).sort_by { |n| [-times[n], n] }
      names.map { |n| branch_info(n, staged[n], upstream[n], times[n]) }
    end

    def branch(name)
      staged, upstream, times = all_refs
      raise NotFound, "no branch named #{name.inspect}" if staged[name].nil? && upstream[name].nil?
      branch_info(name, staged[name], upstream[name], times[name])
    end

    def pending_branches = branches.select(&:pending?)

    # When something was last pushed to this outbox, or nil if nothing has
    # been. Read from the staged branches' reflogs, where receive-pack logs
    # "push"; fetches and approvals log their own messages and don't count.
    def last_push_at
      out = git("log", "-g", "--branches", "--grep-reflog=^push$", "-n", "1", "--format=%ct").strip
      Time.at(out.to_i) unless out.empty?
    end

    # --- sync with upstream -------------------------------------------------

    # Fetch every remote, upstream first. Branches with nothing staged follow
    # upstream; branches with staged changes are left alone (they show up as
    # diverged if upstream moved underneath them). HEAD follows upstream's
    # default branch. The other remotes are fetched after all that, so one
    # that fails leaves upstream's side done. Yields git's progress lines if
    # a block is given.
    def fetch!(&progress)
      install_hooks
      before = upstream_refs
      fetch_remotes([push_remote], &progress)
      after = upstream_refs
      staged = staged_refs

      after.each do |branch, sha|
        old = before[branch]
        untouched = staged[branch].nil? ? old.nil? : staged[branch] == old
        git("update-ref", "-m", "outbox: follow upstream", "refs/heads/#{branch}", sha) if untouched && staged[branch] != sha
      end

      (before.keys - after.keys).each do |branch|
        next unless staged[branch] == before[branch]
        git("update-ref", "-m", "outbox: follow upstream", "-d", "refs/heads/#{branch}", staged[branch])
      end

      follow_upstream_head! unless after.empty?
      others = remotes.keys - [push_remote]
      fetch_remotes(others, &progress) unless others.empty?
      optimize_for_clones!
    end

    # Clients clone from this repo over the git daemon. Without a
    # reachability bitmap, upload-pack walks every object on each clone;
    # with one it mostly copies the pack. A fetch leaves the objects in
    # whatever packs upstream sent, and gc --auto may be a long way off, so
    # build the bitmap (and commit-graph) the first time it is missing.
    # Later fetches only add small packs, which gc --auto folds in.
    def optimize_for_clones!
      return if Dir.glob(File.join(path, "objects", "pack", "*.bitmap")).any?
      return if upstream_refs.empty?
      git("repack", "-a", "-d", "--write-bitmap-index", "--quiet")
      git("commit-graph", "write", "--reachable", "--changed-paths")
    end

    # Point HEAD at the staged copy of whatever upstream's HEAD names, so the
    # outbox has the same default branch as the repo it mirrors. This is the
    # branch new clones check out and the base new branches are diffed
    # against. `git init` already gave HEAD a name, and upstream may well
    # have an old branch by that name too, so HEAD cannot be trusted just
    # because it resolves: ask upstream every time, and follow it if the
    # default branch changes.
    def follow_upstream_head!
      # Asks upstream which branch HEAD names, so it needs the credentials.
      git("remote", "set-head", push_remote, "--auto", extra: remote_env, timeout: Git::REMOTE_TIMEOUT)
      target = git("symbolic-ref", upstream_ref("HEAD")).strip
      branch = target.delete_prefix(upstream_prefix)
      git("symbolic-ref", "HEAD", "refs/heads/#{branch}")
    end

    # --- review -------------------------------------------------------------

    # expected: the staged sha the reviewer looked at ("" for a deletion).
    # If the branch has moved since, refuse: approving must mean approving
    # exactly what was reviewed, not whatever got pushed afterwards.
    def approve!(name, force: false, expected: nil)
      b = branch(name)
      check_expected!(b, expected)
      ref = "refs/heads/#{name}"
      case b.status
      when :synced
        raise GitError, "#{name} is already in sync with upstream"
      when :diverged
        raise GitError, "#{name} has diverged from upstream; approving requires force" unless force
        push("--force-with-lease=#{ref}:#{b.upstream}", "#{b.staged}:#{ref}")
      when :deleted
        push("--force-with-lease=#{ref}:#{b.upstream}", ":#{ref}")
      when :new
        push("--force-with-lease=#{ref}:", "#{b.staged}:#{ref}")
      when :ready
        push("--force-with-lease=#{ref}:#{b.upstream}", "#{b.staged}:#{ref}")
      end
      # git push updates the remote-tracking ref itself, but be explicit.
      if b.staged
        git("update-ref", upstream_ref(name), b.staged)
      else
        git("update-ref", "-d", upstream_ref(name))
      end
      b
    end

    def discard!(name, expected: nil)
      b = branch(name)
      check_expected!(b, expected)
      if b.upstream
        git("update-ref", "-m", "outbox: discard", "refs/heads/#{name}", b.upstream, b.staged.to_s)
      else
        git("update-ref", "-m", "outbox: discard", "-d", "refs/heads/#{name}", b.staged)
      end
      b
    end

    # The three methods below take a Branch, or a branch name for convenience.
    # Callers that already hold a Branch should pass it so the refs are read
    # once per request rather than once per call.

    # Commits that approving would add to upstream.
    def commits(branch, limit: 200)
      b = resolve(branch)
      log(limit, *incoming_revs(b))
    end

    # How many commits #commits would list without its limit.
    def commit_count(branch)
      count(*incoming_revs(resolve(branch)))
    end

    # The commit the incoming commits build on: upstream's tip when ready, the
    # merge-base when diverged, the commit a rebased branch was moved onto,
    # where it forked off the nearest base when new. nil when there is no
    # such commit (nothing staged, or an empty or unrelated upstream).
    def base(branch)
      b = resolve(branch)
      return Base.new(commit: commit_detail(b.onto), ref: ref_with(b.onto)) if b.rebased?
      case b.status
      when :ready, :diverged
        sha = fork_point(b)
        Base.new(commit: commit_detail(sha), ref: "#{push_remote}/#{b.name}")
      when :new
        ref, sha = nearest_base(b.staged)
        Base.new(commit: commit_detail(sha), ref: ref) if sha
      end
    rescue GitError
      nil
    end

    # What a new branch can be shown against, as "remote/branch": the
    # configured bases that have been fetched, else upstream's default
    # branch, if that has.
    def bases
      wanted = configured_bases + ["#{push_remote}/#{default_branch}"]
      have = git("for-each-ref", "--format=%(refname:lstrip=2)", *wanted.map { |b| "#{REMOTES_PREFIX}#{b}" }).split("\n")
      found = configured_bases & have
      found.empty? ? wanted.last(1) & have : found
    end

    # The base a new branch builds on, the one that leaves it the fewest
    # commits of its own, and the commit it forks off that base at. On a tie
    # (a branch off a commit two bases share) the first listed wins. nil
    # when it shares no history with any.
    def nearest_base(sha)
      best = bases.filter_map do |b|
        ref = "#{REMOTES_PREFIX}#{b}"
        fork = git("merge-base", ref, sha, ok: [0, 1]).strip
        [b, fork, count("#{ref}..#{sha}")] unless fork.empty?
      end
      best.min_by { |_, _, own| own }&.first(2)
    end

    # Lines added and deleted by each of the first limit incoming commits,
    # as { sha => [added, deleted] }. Binary files count as nothing.
    def commit_stats(branch, limit: 200)
      stats(limit, *incoming_revs(resolve(branch)))
    end

    # The same for the outgoing commits (#outgoing_commits).
    def outgoing_commit_stats(branch, limit: 200)
      stats(limit, *outgoing_revs(resolve(branch)))
    end

    # Commits on upstream that approving would remove (diverged or deleted).
    def outgoing_commits(branch, limit: 200)
      log(limit, *outgoing_revs(resolve(branch)))
    end

    def outgoing_commit_count(branch)
      count(*outgoing_revs(resolve(branch)))
    end

    # Everything approving this branch would change on upstream, as one
    # patch: from what upstream has now to the staged tip. For a new branch,
    # from where it forked off the default branch.
    def diff(branch, max_bytes: MAX_PATCH_BYTES)
      b = resolve(branch)
      from, to = diff_endpoints(b)
      return Diff::Patch.new(stat: "", text: "") if from.nil?
      patch(from, to, max_bytes)
    end

    # Where a rebased branch went (Rebase), or nil when the branch is not
    # one. Runs the replay, so ask once per page and keep the answer.
    def rebase(branch)
      b = resolve(branch)
      return nil unless b.rebased?
      from = fork_point(b)
      replay, conflicts = replay_onto(b.onto, from, b.upstream) if from
      Rebase.new(onto: commit_detail(b.onto), ref: ref_with(b.onto), from: from && commit_detail(from),
                 replay: replay, conflicts: conflicts || [])
    end

    # How the staged commits of a diverged branch correspond to upstream's
    # (Rewrite). nil when the branch is not diverged, and when either side
    # has more than REWRITE_LIMIT commits: pairing compares every commit
    # with every other, and past that a dropped list and no badges is
    # better than a page that takes a minute.
    def rewrite(branch)
      b = resolve(branch)
      return nil unless b.status == :diverged
      return nil if b.ahead > REWRITE_LIMIT || b.behind > REWRITE_LIMIT
      unchanged = {}
      changed = {}
      old = "refs/heads/#{b.name}..#{upstream_ref(b.name)}"
      new = "#{b.onto || b.upstream}..refs/heads/#{b.name}"
      git("range-diff", "--no-color", "--no-patch", "--abbrev=64", old, new).each_line do |line|
        next unless (m = RANGE_DIFF_RE.match(line))
        case m[:mark]
        when "=" then unchanged[m[:new]] = m[:old]
        when "!" then changed[m[:new]] = m[:old]
        end
      end
      Rewrite.new(unchanged: unchanged, changed: changed)
    end

    REWRITE_LIMIT = 200

    # One line of git range-diff's summary: a numbered commit on each side,
    # or dashes where there is none, and between them = (same patch),
    # ! (changed), < (only old) or > (only new).
    RANGE_DIFF_RE = /\A\s*(?:\d+|-):\s+(?<old>\h+|-+)\s+(?<mark>[=!<>])\s+(?:\d+|-):\s+(?<new>\h+|-+)\s/

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

    # One file's contents by blob id, for expanding the unchanged lines
    # around a hunk. Blob ids come from the index lines of a patch.
    def blob(id)
      raise NotFound, "not a blob id: #{id.inspect}" unless id.match?(/\A[0-9a-f]{40,64}\z/)
      raise NotFound, "no blob #{id}" unless git("cat-file", "-t", id).strip == "blob"
      raise NotFound, "blob #{id} is too large to show" if git("cat-file", "-s", id).to_i > MAX_BLOB_BYTES
      git("cat-file", "blob", id).scrub
    rescue GitError
      raise NotFound, "no blob #{id}"
    end

    MAX_BLOB_BYTES = 5_000_000

    # The id of the blob at path in a commit, for showing a file as it was
    # then. Anything in the repo can be named, as with blob.
    def file_blob(sha, path)
      raise NotFound, "not a commit id: #{sha.inspect}" unless sha.match?(/\A[0-9a-f]{40,64}\z/)
      raise NotFound, "no file named #{path.inspect}" if path.empty?
      entry = git("ls-tree", "-z", sha, "--", path).split("\0").first
      _mode, type, id = entry&.split(/[ \t]/, 4)
      raise NotFound, "no file #{path} in #{sha[0, 7]}" unless type == "blob" && entry.end_with?("\t#{path}")
      id
    rescue GitError
      raise NotFound, "no file #{path} in #{sha[0, 7]}"
    end

    private

    def resolve(branch) = branch.is_a?(Branch) ? branch : branch(branch)

    def fetch_remotes(names, &progress)
      if progress
        Git.stream("fetch", "--prune", "--progress", "--multiple", *names, chdir: path, extra: remote_env, &progress)
      else
        git("fetch", "--prune", "--quiet", "--multiple", *names, extra: remote_env, timeout: Git::REMOTE_TIMEOUT)
      end
    end

    # outbox.push, outbox.base and every remote's URL, read in one git call
    # and kept for the life of this object, which is one request or one job
    # of the repo's actor. configure! starts over.
    def settings
      @settings ||= begin
        push = nil
        bases = []
        remotes = {}
        out = git("config", "-z", "--get-regexp", '^(outbox\.(push|base)|remote\..*\.url)$', ok: [0, 1])
        out.split("\0").each do |entry|
          key, value = entry.split("\n", 2)
          value = value.to_s.strip
          case key
          when "outbox.push" then push = value
          when "outbox.base" then bases << value
          else remotes[key.delete_prefix("remote.").delete_suffix(".url")] = value
          end
        end
        push_set = !push.nil?
        push ||= LEGACY_PUSH
        remotes = { push => remotes[push] }.merge(remotes) if remotes.key?(push)
        { push:, push_set:, bases:, remotes: }
      end
    end

    def push(*args) = git("push", "--quiet", push_remote, *args, extra: remote_env, timeout: Git::REMOTE_TIMEOUT)

    def check_expected!(b, expected)
      return if expected.nil?
      actual = b.staged.to_s
      return if actual == expected
      was = expected.empty? ? "deleted" : expected[0, 10]
      now = actual.empty? ? "deleted" : actual[0, 10]
      raise GitError, "#{b.name} changed since you reviewed it (reviewed #{was}, now #{now}). Review it again."
    end

    def branch_info(name, staged, upstream, time)
      status, ahead, behind =
        if upstream.nil?
          [:new, count("refs/heads/#{name}", "--not", "--remotes"), 0]
        elsif staged.nil?
          [:deleted, 0, count(upstream_ref(name), "--not", "--branches")]
        elsif staged == upstream
          [:synced, 0, 0]
        else
          behind, ahead = git("rev-list", "--left-right", "--count",
                              "#{upstream_ref(name)}...refs/heads/#{name}").split.map(&:to_i)
          [behind.zero? ? :ready : :diverged, ahead, behind]
        end
      onto = nil
      picked_up = 0
      if status == :diverged
        # Rebased when the staged commits build on one commit upstream has
        # (on some other branch, or it would not be diverged) and that is
        # not where upstream's version of the branch builds: the commits
        # between are upstream's, picked up by the move, not the branch's.
        own, bases = own_commits(name)
        if bases.size == 1 && own.size < ahead
          onto = bases.first
          picked_up = ahead - own.size
          ahead = own.size
        end
      end
      Branch.new(name:, staged:, upstream:, status:, ahead:, behind:, onto:, picked_up:, time: Time.at(time))
    end

    # The staged commits upstream has nowhere, newest first, and the commits
    # they build on, which upstream does have: one for a straight line of
    # commits, several when they merge upstream branches, none when the
    # history is unrelated to upstream's.
    def own_commits(name)
      own = []
      bases = []
      git("rev-list", "--boundary", "refs/heads/#{name}", "--not", "--remotes").each_line do |line|
        sha = line.strip
        sha.start_with?("-") ? bases << sha.delete_prefix("-") : own << sha
      end
      [own, bases]
    end

    # Where upstream's version of a branch and the staged one part ways, or
    # nil when they share no history.
    def fork_point(b)
      git("merge-base", b.upstream, b.staged).strip
    rescue GitError
      nil
    end

    # A remote branch that has the commit, as "remote/branch": the first
    # base that does, else upstream's default branch, else the first by
    # name. nil when none does.
    def ref_with(sha)
      names = git("for-each-ref", "--contains", sha, "--format=%(refname:lstrip=2)", REMOTES_PREFIX.chomp("/")).split
      names.reject! { |n| n.end_with?("/HEAD") }
      (bases + ["#{push_remote}/#{default_branch}"]).find { |b| names.include?(b) } || names.first
    end

    # Upstream's version of a rebased branch moved onto its new base: what
    # tip changed since from, replayed onto onto by one three-way merge.
    # Returns the tree and the paths that conflicted, where the tree holds
    # the markers. (git merge-tree exits 1 for a conflicted merge and still
    # writes the tree.) nil when the merge could not be done at all.
    def replay_onto(onto, from, tip)
      out = git("merge-tree", "--write-tree", "--name-only", "--merge-base=#{from}", onto, tip, ok: [0, 1])
      tree, *rest = out.lines.map(&:strip)
      conflicts = rest.take_while { |line| !line.empty? }
      [tree, conflicts]
    rescue GitError
      nil
    end

    # Rebased branches list the commits of their own; the ones the move
    # picked up are upstream's.
    def incoming_revs(b)
      return ["refs/heads/#{b.name}", "--not", "--remotes"] if b.rebased?
      case b.status
      when :new then ["refs/heads/#{b.name}", "--not", "--remotes"]
      when :ready, :diverged then ["#{upstream_ref(b.name)}..refs/heads/#{b.name}"]
      else nil
      end
    end

    def outgoing_revs(b)
      case b.status
      when :deleted  then [upstream_ref(b.name), "--not", "--branches"]
      when :diverged then ["refs/heads/#{b.name}..#{upstream_ref(b.name)}"]
      end
    end

    # { sha => [added, deleted] } for the first limit commits in revs.
    def stats(limit, *revs)
      return {} if revs.compact.empty?
      stats = {}
      git("log", "-n", limit.to_s, "--format=%x00%H", "--numstat", *revs).split("\0").reject(&:empty?).each do |record|
        sha, *lines = record.lines
        added = deleted = 0
        lines.each do |line|
          a, d = line.split("\t", 3)
          added += a.to_i
          deleted += d.to_i
        end
        stats[sha.strip] = [added, deleted]
      end
      stats
    end

    def count(*revs)
      return 0 if revs.compact.empty?
      git("rev-list", "--count", *revs).to_i
    end

    # Commits are NUL-separated because the full message is included and
    # may contain anything.
    def log(limit, *revs)
      return [] if revs.compact.empty?
      out = git("log", "-z", "-n", limit.to_s, "--format=#{LOG_FORMAT}", *revs)
      out.split("\0").map do |record|
        sha, short, author, author_email, date, committer, committer_email, commit_date, parents, message =
          record.split("\x1f", 10)
        Commit.new(sha:, short:, author:, author_email:, date:, committer:, committer_email:, commit_date:,
                   parents: parents.split, message: message.to_s.chomp)
      end
    end

    def diff_endpoints(b)
      # For a rebased branch, upstream's tip to ours would also show
      # everything the new base brought in, which is upstream's own work.
      # Start from upstream's version replayed onto the new base instead
      # (Rebase#replay), so the diff is what changed beyond the move:
      # nothing for a plain rebase, the amendment for an amend, the
      # resolution for a conflict. The plain diff when the replay is not
      # possible.
      return [rebase(b).replay || b.upstream, b.staged] if b.rebased?
      case b.status
      when :ready, :diverged
        # Upstream's tip to ours: what approving puts there. When ready,
        # upstream is an ancestor and this is just the staged commits. When
        # diverged, approving force-pushes over upstream's tip, so an amended
        # commit shows as the amendment and anything only upstream has shows
        # as removed. Diffing from the merge-base would show the whole
        # rewritten branch instead.
        [b.upstream, b.staged]
      when :new
        [nearest_base(b.staged)&.last || empty_tree, b.staged]
      else
        [nil, nil]
      end
    end

    def patch(from, to, max_bytes)
      stat = git("diff", "--shortstat", "-M", from, to).strip
      text = git("diff", "-M", "--full-index", from, to)
      truncated = false
      if text.bytesize > max_bytes
        text = text.byteslice(0, max_bytes)
        text = text[0..text.rindex("\n")] if text.include?("\n")
        text = text.scrub
        truncated = true
      end
      Diff::Patch.new(stat:, text:, truncated:)
    end

    def default_branch
      git("symbolic-ref", "HEAD").strip.delete_prefix("refs/heads/")
    end

    def empty_tree
      git("hash-object", "-t", "tree", "/dev/null").strip
    end
  end
end
