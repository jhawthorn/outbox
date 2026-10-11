# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Outbox
  # The list of repositories and their upstreams, kept in git.
  #
  # The approved copy is a bare repo at $OUTBOX_DATA/config.git holding one
  # file, outbox.conf, in git's own config syntax:
  #
  #   [repo "rails"]
  #       upstream = git@github.com:rails/rails.git
  #
  # That repo is never served. What is served is a staging repo for it,
  # _config.git, whose upstream is the approved copy. Proposing a change is a
  # push to _config and making it real is an approval, the same as for any
  # other repository. After an approval, apply! creates a staging repo for
  # each new entry and re-points one whose upstream changed. Nothing is ever
  # deleted here: a staging repo stays until the operator removes it.
  class Config
    NAME = "_config"
    FILE = "outbox.conf"

    # Relative to the staging repo, so a data directory can move.
    UPSTREAM = "../../config.git"

    IDENTITY = {
      "GIT_AUTHOR_NAME" => "outbox", "GIT_AUTHOR_EMAIL" => "outbox@localhost",
      "GIT_COMMITTER_NAME" => "outbox", "GIT_COMMITTER_EMAIL" => "outbox@localhost",
    }.freeze

    TEMPLATE = <<~CONF
      # Repositories the outbox holds pushes for. One section each:
      #
      #   [repo "rails"]
      #       upstream = git@github.com:rails/rails.git
      #
      # Pushes to <outbox>/rails.git are then held for review and, once
      # approved, sent to the upstream. To change this file, clone
      # <outbox>/_config.git, commit to a branch, push it; the change is
      # reviewed and approved like any other.
    CONF

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
      repos = {}
      problems = []
      begin
        out = Git.run("config", "--blob", "HEAD:#{FILE}", "--list", "-z", chdir: live_path(root))
      rescue GitError => e
        return new(repos: repos, problems: ["#{FILE} could not be read: #{e.message}"])
      end
      out.split("\0").each do |entry|
        key, value = entry.split("\n", 2)
        next unless key.start_with?("repo.") && key.end_with?(".upstream")
        name = key.delete_prefix("repo.").delete_suffix(".upstream")
        next if name.empty?
        if !name.match?(Repo::NAME_RE)
          problems << "#{name.inspect} is not a valid repository name"
        elsif name == NAME
          problems << "#{NAME} is reserved for the configuration itself"
        elsif value.to_s.strip.empty?
          problems << "#{name} has no upstream"
        else
          repos[name] = value.strip
        end
      end
      new(repos: repos, problems: problems)
    end

    # Create a staging repo for each configured entry that lacks one, and
    # re-point any whose upstream changed. Returns the repos created, which
    # still need a first fetch. A repo on disk with no entry is left alone.
    def self.apply!(root = Repo.root)
      config = load(root)
      existing = Repo.all(root).reject(&:config?)
      existing.each do |repo|
        url = config.repos[repo.name]
        repo.upstream_url = url if url && repo.upstream_url != url
      end
      (config.repos.keys - existing.map(&:name)).map { |name| Repo.create(name, config.repos[name], root: root) }
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
      raise ArgumentError, "upstream URL is required" if upstream.to_s.strip.empty?
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

    attr_reader :repos, :problems

    def initialize(repos:, problems:)
      @repos = repos
      @problems = problems
    end
  end
end
