# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Outbox
  # The list of repositories and the remotes each one tracks, kept in git.
  #
  # The approved copy is a bare repo at $OUTBOX_DATA/config.git holding one
  # file, outbox.conf, in git's own config syntax (TEMPLATE explains it):
  #
  #   [remote "you"]
  #       url = https://github.com/you/${name}.git
  #   [remote "rails"]
  #       url = https://github.com/rails/${name}.git
  #
  #   [repo "rails"]
  #       push = you
  #       fetch = rails
  #       base = rails/main
  #
  # That repo is never served. What is served is a staging repo for it,
  # _config.git, whose upstream is the approved copy. Proposing a change is a
  # push to _config and making it real is an approval, the same as for any
  # other repository. After an approval, apply! creates a staging repo for
  # each new entry and brings the remotes of existing ones in line. Nothing
  # is ever deleted here: a staging repo stays until the operator removes it.
  class Config
    NAME = "_config"
    FILE = "outbox.conf"

    # Relative to the staging repo, so a data directory can move.
    UPSTREAM = "../../config.git"

    IDENTITY = {
      "GIT_AUTHOR_NAME" => "outbox", "GIT_AUTHOR_EMAIL" => "outbox@localhost",
      "GIT_COMMITTER_NAME" => "outbox", "GIT_COMMITTER_EMAIL" => "outbox@localhost",
    }.freeze

    TEMPLATE = <<~'CONF'
      # Repositories the outbox holds pushes for. Remotes are named once,
      # with ${name} standing for each repository's name, and every
      # repository says which of them it tracks:
      #
      #   [remote "you"]
      #       url = https://github.com/you/${name}.git
      #   [remote "rails"]
      #       url = https://github.com/rails/${name}.git
      #
      #   [repo "rails"]
      #       push = you
      #       fetch = rails
      #       base = rails/main
      #
      # Pushes to <outbox>/rails.git are held for review and, once approved,
      # sent to the push remote. Each fetch remote (any number) is only
      # fetched. A clone sees every remote's branches as <remote>/<branch>.
      # Each base (any number) is somewhere new work starts: a new branch is
      # shown against the one it builds on, the first listed on a tie, and
      # without any, against the push remote's default branch.
      #
      # Urls are https URLs (the server's OUTBOX_UPSTREAM_TOKEN
      # authenticates them) or local paths. A url without ${name} serves one
      # repository only. upstream = <url> in place of push is the older
      # form, a push remote called upstream.
      #
      # To change this file, clone <outbox>/_config.git, commit to a branch,
      # push it; the change is reviewed and approved like any other.
    CONF

    # One repository's entry: its remotes as { name => url }, the push
    # remote first, which of them approvals go to, and its bases as
    # "remote/branch".
    class Entry
      attr_reader :push, :remotes, :bases

      def initialize(push:, remotes:, bases:)
        @push = push
        @remotes = remotes
        @bases = bases
      end

      def push_url = remotes.fetch(push)
    end

    def self.live_path(root = Repo.root) = File.join(root, "config.git")

    def self.staging(root = Repo.root) = Repo.new(NAME, root: root)

    # Create the approved repo (with an initial, empty config) and its staging
    # repo if they are missing. The staging repo still needs a first fetch.
    def self.ensure!(root = Repo.root)
      live = live_path(root)
      unless File.exist?(File.join(live, "HEAD"))
        FileUtils.mkdir_p(live)
        Git.run("init", "--bare", "--quiet", "-b", "main", live)
        blob = Git.run("hash-object", "-w", "--stdin", chdir: live, input: TEMPLATE).strip
        tree = Git.run("mktree", chdir: live, input: "100644 blob #{blob}\t#{FILE}\n").strip
        commit = Git.run("commit-tree", tree, "-m", "Initial configuration", chdir: live, extra: IDENTITY).strip
        Git.run("update-ref", "refs/heads/main", commit, chdir: live)
      end
      repo = staging(root)
      File.directory?(repo.path) ? repo : Repo.create(NAME, UPSTREAM, root: root)
    end

    # The approved configuration. Entries that cannot be used are reported in
    # problems rather than raised: the fix is another change to the config,
    # which needs the UI to be up.
    def self.load(root = Repo.root)
      begin
        out = Git.run("config", "--blob", "HEAD:#{FILE}", "--list", "-z", chdir: live_path(root))
      rescue GitError => e
        return new(repos: {}, problems: ["#{FILE} could not be read: #{e.message}"])
      end
      remote_keys = {}
      repo_keys = {}
      out.split("\0").each do |entry|
        key, value = entry.split("\n", 2)
        section, rest = key.split(".", 2)
        sub, _, var = rest.to_s.rpartition(".")
        next if sub.empty?
        keys = case section
               when "remote" then remote_keys
               when "repo" then repo_keys
               else next
               end
        ((keys[sub] ||= {})[var] ||= []) << value.to_s.strip
      end

      problems = []
      urls = remotes(remote_keys, problems)
      repos = {}
      repo_keys.each do |name, vars|
        if !name.match?(Repo::NAME_RE)
          problems << "#{name.inspect} is not a valid repository name"
        elsif name == NAME
          problems << "#{NAME} is reserved for the configuration itself"
        elsif (entry = entry(name, vars, urls, problems))
          repos[name] = entry
        end
      end
      shared_urls(repos, urls, problems)
      new(repos: repos, problems: problems)
    end

    # The [remote] sections that can be used, as { name => url, with ${name}
    # left in }. The rest are reported in problems.
    def self.remotes(remote_keys, problems)
      urls = {}
      remote_keys.each do |name, vars|
        url = vars.fetch("url", [])
        if !name.match?(Repo::REMOTE_NAME_RE)
          problems << "#{name.inspect} is not a valid remote name"
        elsif Repo::RESERVED_REMOTES.include?(name)
          problems << "#{name} is reserved: clones of the outbox use it"
        elsif url.size > 1
          problems << "remote #{name} has more than one url"
        elsif url.first.to_s.empty?
          problems << "remote #{name} has no url"
        else
          urls[name] = url.first
        end
      end
      urls
    end

    # One [repo] section as an Entry, or nil with the reasons in problems.
    def self.entry(name, vars, urls, problems)
      legacy = vars.fetch("upstream", [])
      push = vars.fetch("push", []).reject(&:empty?)
      fetch = vars.fetch("fetch", []).reject(&:empty?)
      bases = vars.fetch("base", []).reject(&:empty?)
      before = problems.size
      remotes = {}

      if legacy.any? && push.any?
        problems << "#{name} has both upstream and push; give one"
      elsif legacy.any?
        push_name = Repo::LEGACY_PUSH
        if legacy.last.empty?
          problems << "#{name} has no upstream"
        elsif (problem = Repo.upstream_url_problem(legacy.last))
          problems << "#{name}: #{problem}"
        else
          remotes[push_name] = legacy.last
        end
      elsif push.size > 1
        problems << "#{name} has more than one push remote"
      elsif push.empty?
        problems << "#{name} has no push remote"
      else
        push_name = push.first
      end

      listed = [push_name, *fetch].compact
      listed.each_with_index do |remote, i|
        if listed.index(remote) != i
          problems << "#{name} lists remote #{remote} twice"
        elsif legacy.any? && remote == push_name
          next # upstream = <url>, checked above
        elsif !urls.key?(remote)
          problems << "#{name}: no remote named #{remote}"
        elsif (problem = Repo.upstream_url_problem(urls[remote].gsub("${name}", name), "remote #{remote}"))
          problems << "#{name}: #{problem}"
        else
          remotes[remote] = urls[remote].gsub("${name}", name)
        end
      end

      bases.each_with_index do |base, i|
        remote, _, branch = base.partition("/")
        if bases.index(base) != i
          problems << "#{name} lists base #{base} twice"
        elsif !listed.include?(remote) || !Repo.branch_name?(branch)
          problems << "#{name}: base #{base} is not a branch of one of its remotes, as remote/branch"
        end
      end

      return nil if problems.size > before
      Entry.new(push: push_name, remotes: { push_name => remotes[push_name] }.merge(remotes), bases: bases)
    end

    # A url without ${name} is one repository, so two repos using it would
    # both be that one: each is reported and dropped.
    def self.shared_urls(repos, urls, problems)
      urls.each do |remote, url|
        next if url.include?("${name}")
        users = repos.select { |_, entry| entry.remotes.key?(remote) && entry.remotes[remote] == url }.keys
        next if users.size < 2
        problems << "remote #{remote} has no ${name} in its url, so only one repository can use it, not #{users.join(", ")}"
        users.each { |name| repos.delete(name) }
      end
    end

    # Create a staging repo for each configured entry that lacks one, and
    # bring the remotes and bases of the others in line (Repo#configure!).
    # Returns the repos with something new to fetch: the ones created, and
    # the ones given a remote or pointed somewhere else. A repo on disk with
    # no entry is left alone.
    def self.apply!(root = Repo.root)
      config = load(root)
      existing = Repo.all(root).reject(&:config?)
      changed = existing.select do |repo|
        entry = config.repos[repo.name]
        entry && repo.configure!(push: entry.push, remotes: entry.remotes, bases: entry.bases)
      end
      created = (config.repos.keys - existing.map(&:name)).map do |name|
        entry = config.repos[name]
        repo = Repo.create(name, entry.push_url, root: root, push: entry.push)
        repo.configure!(push: entry.push, remotes: entry.remotes, bases: entry.bases)
        repo
      end
      created + changed
    end

    # Change the approved configuration directly, without review. For the
    # operator's CLI; everyone else goes through _config. Yields the path of
    # a checked-out outbox.conf, then commits and pushes it.
    def self.edit(root = Repo.root, message:)
      Dir.mktmpdir("outbox-config") do |dir|
        work = File.join(dir, "work")
        Git.run("clone", "--quiet", live_path(root), work)
        yield File.join(work, FILE)
        Git.run("add", "--", FILE, chdir: work)
        Git.run("commit", "--quiet", "-m", message, chdir: work, extra: IDENTITY)
        Git.run("push", "--quiet", "origin", "HEAD:main", chdir: work)
      end
    end

    def self.add(name, upstream, root = Repo.root)
      raise ArgumentError, "invalid repository name #{name.inspect}" unless name.to_s.match?(Repo::NAME_RE)
      raise ArgumentError, "#{NAME} is reserved" if name == NAME
      if (problem = Repo.upstream_url_problem(upstream))
        raise ArgumentError, problem
      end
      edit(root, message: "Add #{name}") do |file|
        Git.run("config", "-f", file, "repo.#{name}.upstream", upstream.strip)
      end
    end

    # Drops the entry and destroys the staging repo. The only way a staging
    # repo is deleted; approving a config change never is.
    def self.remove(name, root = Repo.root)
      repo = Repo.find(name) or raise NotFound, "no repository named #{name.inspect}"
      raise ArgumentError, "#{NAME} cannot be removed" if repo.config?
      if load(root).repos.key?(name)
        edit(root, message: "Remove #{name}") do |file|
          Git.run("config", "-f", file, "--remove-section", "repo.#{name}")
        end
      end
      repo.destroy!
    end

    private_class_method :remotes, :entry, :shared_urls

    attr_reader :repos, :problems

    def initialize(repos:, problems:)
      @repos = repos
      @problems = problems
    end
  end
end
