# frozen_string_literal: true

module Outbox
  # Reading a repository the way a code host shows one: by branch name as
  # well as by sha, its history, its files, searching them, and who last
  # changed each line. Everything here only reads, so it is safe from any
  # thread, like the rest of Repo's reads.
  class Repo
    # A commit as a URL names it: a staged branch ("main"), a remote's
    # branch ("upstream/main", "ruby/master"), a tag, or a sha. kind is
    # :branch, :remote, :tag or :commit; ref the full ref name, nil for a
    # sha.
    class Rev
      attr_reader :name, :sha, :kind, :ref

      def initialize(name:, sha:, kind:, ref: nil)
        @name = name
        @sha = sha
        @kind = kind
        @ref = ref
      end

      def commit? = kind == :commit
      def branch? = kind == :branch
    end

    # One branch or tag in a listing (the branches page, the ref picker):
    # where it points and what its tip commit is.
    class RefInfo
      attr_reader :name, :kind, :remote, :sha, :time, :subject, :author

      def initialize(name:, kind:, remote:, sha:, time:, subject:, author:)
        @name = name
        @kind = kind
        @remote = remote
        @sha = sha
        @time = time
        @subject = subject
        @author = author
      end
    end

    # The refs a URL can name, { name => Rev }, read once per Repo object (one
    # request). Staged branches win over tags, and tags over remote
    # branches, when two have the same name.
    def revs
      @revs ||= begin
        found = {}
        ref_records.each do |ref, sha|
          name, kind = rev_name(ref)
          next unless name
          next if found[name] && REV_PRECEDENCE.index(found[name].kind) <= REV_PRECEDENCE.index(kind)
          found[name] = Rev.new(name:, sha:, kind:, ref:)
        end
        found
      end
    end

    REV_PRECEDENCE = %i[branch tag remote].freeze

    # The commit a URL path starts with, and the rest of the path. Branch
    # names can have slashes, so the longest leading run of segments that
    # names a ref wins; a full sha, or an abbreviated one when no ref has
    # that name, names a commit. nil when nothing does.
    def resolve_path(path)
      segments = path.split("/")
      return nil if segments.empty?
      segments.size.downto(1) do |n|
        name = segments.first(n).join("/")
        rev = revs[name]
        return [rev, segments.drop(n).join("/")] if rev
      end
      sha = commit_sha(segments.first)
      sha ? [Rev.new(name: sha, sha:, kind: :commit), segments.drop(1).join("/")] : nil
    end

    # A Rev by name alone: a ref, or a sha.
    def rev(name)
      return nil if name.to_s.empty?
      revs[name] || ((sha = commit_sha(name)) && Rev.new(name: sha, sha:, kind: :commit))
    end

    # The full sha of a commit given as hex, at least 7 digits, or nil.
    def commit_sha(hex)
      return nil unless hex.to_s.match?(SHA_RE)
      out = git("rev-parse", "--verify", "--quiet", "#{hex}^{commit}", ok: [0, 1]).strip
      out.empty? ? nil : out
    rescue GitError
      nil
    end

    # The branch HEAD names, as a Rev: the default branch. nil before
    # anything has been fetched or pushed.
    def default_rev
      revs[default_branch]
    rescue GitError
      nil
    end

    # Every branch and tag, newest tip first: the staged branches, then each
    # remote's, then tags, as RefInfo. HEAD symrefs are left out.
    def ref_list
      out = git("for-each-ref", "--sort=-committerdate",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(committerdate:unix)%00%(*committerdate:unix)%00%(subject)%00%(*subject)%00%(authorname)%00%(*authorname)",
                "refs/heads", "refs/remotes", "refs/tags")
      out.each_line(chomp: true).filter_map do |line|
        ref, sha, peeled, time, ptime, subject, psubject, author, pauthor = line.split("\0", -1)
        name, kind = rev_name(ref)
        next unless name
        remote = kind == :remote ? name.split("/", 2).first : nil
        tag = !peeled.to_s.empty?
        RefInfo.new(name:, kind:, remote:, sha: tag ? peeled : sha, time: Time.at((tag ? ptime : time).to_i),
                    subject: (tag ? psubject : subject).to_s.scrub, author: (tag ? pauthor : author).to_s.scrub)
      end
    end

    # Commits reachable from sha, newest first, optionally only those that
    # touched path, skip commits in.
    def history(sha, path = "", limit: 50, skip: 0)
      log(limit, "--skip=#{skip.to_i}", sha, "--", *(path.empty? ? [] : [path]))
    end

    # The last commit that touched path in sha's history (the commit itself
    # for the root).
    def last_commit(sha, path = "")
      history(sha, path, limit: 1).first
    end

    # The last commit to touch each name in a directory, as { name =>
    # Commit (subject only) }: what a tree listing shows beside each entry.
    # Read from one walk of the history, newest first, which stops once
    # every name has one or after TREE_COMMITS_TIMEOUT seconds; names not
    # reached by then are left out.
    def tree_commits(sha, path)
      names = tree_entries(sha, path).to_h { |e| [e.name, true] }
      prefix = path.empty? ? "" : "#{path}/"
      found = {}
      commit = nil
      Git.each_line("log", "--format=%x01%H%x1f%an%x1f%ae%x1f%aI%x1f%cI%x1f%s", "--name-only", "-z", sha, "--", *(path.empty? ? [] : [path]),
                    chdir: self.path, timeout: TREE_COMMITS_TIMEOUT, sep: "\0") do |field|
        field = field.chomp("\0")
        if field.include?("\x01")
          paths_before, header = field.split("\x01", 2)
          note(found, names, commit, prefix, paths_before)
          sha_, author, email, date, cdate, subject = header.split("\x1f", 6)
          subject, first_path = subject.to_s.split("\n", 2)
          commit = Commit.new(sha: sha_, short: sha_[0, 10], author:, author_email: email, date:, committer: author,
                              committer_email: email, commit_date: cdate, parents: [], message: subject.to_s)
          note(found, names, commit, prefix, first_path)
        else
          note(found, names, commit, prefix, field)
        end
        break if found.size >= names.size
      end
      found
    end

    TREE_COMMITS_TIMEOUT = 5

    # What head has that base does not, as a code host's compare shows it:
    # the commits, newest first, up to limit, how many there are, and the
    # diff from where they part to head. Returns [commits, count, patch, fork].
    def compare(base, head, limit: 250, ignore_whitespace: false)
      fork = git("merge-base", base, head, ok: [0, 1]).strip
      range = fork.empty? ? [head] : ["#{base}..#{head}"]
      commits = log(limit, *range)
      count = count(*range)
      [commits, count, patch(fork.empty? ? empty_tree : fork, head, MAX_PATCH_BYTES, ignore_whitespace:), fork.empty? ? nil : fork]
    end

    # Every file in a commit, as paths, for finding one by name.
    def file_list(sha)
      raise NotFound, "not a commit id: #{sha.inspect}" unless sha.match?(/\A[0-9a-f]{40,64}\z/)
      git("ls-tree", "-r", "-z", "--name-only", sha).split("\0").map(&:scrub)
    end

    # The contents of a file in a commit, up to MAX_RAW_BYTES. Returns
    # [contents, size].
    def file_contents(sha, path)
      blob = file_blob(sha, path)
      size = git("cat-file", "-s", blob).to_i
      raise NotFound, "#{path} is too large to show (#{size} bytes)" if size > MAX_RAW_BYTES
      [Git.run("cat-file", "blob", blob, chdir: self.path, binary: true), size]
    end

    MAX_RAW_BYTES = 50_000_000

    # One line git grep found: the file, the line number and the line.
    class Match
      attr_reader :path, :line, :text

      def initialize(path:, line:, text:)
        @path = path
        @line = line
        @text = text
      end
    end

    # Lines in a commit's files that contain query, as Matches grouped by
    # path: { path => [Match] }. A fixed string unless regex, ignoring case
    # unless the query has a capital letter. At most GREP_PER_FILE lines a
    # file and GREP_FILES files. Returns [matches, more, truncated]: more
    # the paths that had more lines than shown, truncated whether there
    # were more files.
    def grep(sha, query, regex: false, path: "")
      raise ArgumentError, "nothing to search for" if query.to_s.strip.empty?
      # One file is searched for every line.
      per_file = !path.empty? && object_type(sha, path) == "blob" ? GREP_ONE_FILE : GREP_PER_FILE
      args = ["grep", "-z", "-I", "-n", "--no-color", "--full-name", "--max-count=#{per_file + 1}"]
      args << (regex ? "-E" : "-F")
      args << "-i" unless query.match?(/[[:upper:]]/)
      args += ["-e", query, sha, "--"]
      args << path unless path.empty?
      out = git(*args, ok: [0, 1], timeout: GREP_TIMEOUT)
      found = {}
      more = {}
      truncated = false
      out.each_line(chomp: true) do |line|
        # sha:path\0line\0text with -z
        where, number, text = line.split("\0", 3)
        file = where.to_s.delete_prefix("#{sha}:").scrub
        list = found[file]
        unless list
          if found.size >= GREP_FILES
            truncated = true
            break
          end
          list = found[file] = []
        end
        if list.size >= per_file
          more[file] = true
          next
        end
        list << Match.new(path: file, line: number.to_i, text: text.to_s.scrub)
      end
      [found, more, truncated]
    end

    GREP_PER_FILE = 20
    GREP_ONE_FILE = 2000
    GREP_FILES = 200
    GREP_TIMEOUT = 20

    # A run of lines git blame gives to one commit. previous is where to
    # look before that commit, [sha, path], or nil where it added them.
    class BlameHunk
      attr_reader :commit, :start, :lines, :previous

      def initialize(commit:, start:, lines:, previous: nil)
        @commit = commit
        @start = start
        @lines = lines
        @previous = previous
      end
    end

    # Who last changed each line of a file, as BlameHunks in file order.
    # commit is a Commit without its body (git blame gives the subject).
    def blame(sha, path)
      raise NotFound, "no file #{path} in #{sha[0, 7]}" unless object_type(sha, path) == "blob"
      out = git("blame", "--porcelain", sha, "--", path, timeout: GREP_TIMEOUT)
      commits = {}
      hunks = []
      current = nil
      info = nil
      lineno = nil
      out.each_line do |line|
        if info.nil? || (line.match?(/\A\h{40,64} \d+ \d+/) && !line.start_with?("\t"))
          sha_, _orig, final, count = line.split
          info = commits[sha_] ||= { sha: sha_ }
          lineno = final.to_i
          if count
            current = { sha: sha_, start: lineno, lines: [] }
            hunks << current
          end
        elsif line.start_with?("\t")
          current[:lines] << line[1..].chomp.scrub
          info = nil
        else
          key, value = line.chomp.split(" ", 2)
          info[key] = value.to_s.scrub
        end
      end
      hunks.map do |hunk|
        c = commits[hunk[:sha]]
        commit = Commit.new(sha: c[:sha], short: c[:sha][0, 10], author: c["author"].to_s, author_email: c["author-mail"].to_s.delete("<>"),
                            date: blame_time(c["author-time"], c["author-tz"]), committer: c["committer"].to_s,
                            committer_email: c["committer-mail"].to_s.delete("<>"), commit_date: blame_time(c["committer-time"], c["committer-tz"]),
                            parents: [], message: c["summary"].to_s)
        previous = c["previous"]&.split(" ", 2)
        BlameHunk.new(commit:, start: hunk[:start], lines: hunk[:lines], previous:)
      end
    end

    # The README of a directory, from its entries: README.md before other
    # kinds, any case. nil when there is none.
    def self.readme(entries)
      files = entries.reject(&:dir?).select { |e| e.name.match?(/\Areadme(\.[a-z0-9]+)?\z/i) }
      files.min_by { |e| [README_KINDS.index(File.extname(e.name).downcase) || README_KINDS.size, e.name] }
    end

    README_KINDS = [".md", ".markdown", ".mdown", "", ".txt", ".rdoc", ".rst", ".org"].freeze

    # Whether a file is markdown, by name.
    def self.markdown?(path) = path.match?(/\.(md|markdown|mdown|mkd)\z/i)

    private

    # Records commit against the entry of the directory that file is in,
    # if it is one of names (a name can be gone from the directory now).
    def note(found, names, commit, prefix, file)
      return if commit.nil? || file.nil? || file.empty?
      file = file.strip
      return unless file.start_with?(prefix)
      name = file.delete_prefix(prefix).split("/", 2).first
      found[name] ||= commit if names.key?(name)
    end

    # git blame's time and zone ("1700000000", "+0900") as ISO 8601 in that
    # zone, like git log's %aI.
    def blame_time(time, zone)
      zone = zone.to_s.match?(/\A[+-]\d{4}\z/) ? "#{zone[0, 3]}:#{zone[3, 2]}" : "+00:00"
      Time.at(time.to_i).getlocal(zone).iso8601
    end

    # [name, kind] for a full ref name, or nil for one a URL cannot name.
    def rev_name(ref)
      if ref.start_with?(STAGED_PREFIX)
        [ref.delete_prefix(STAGED_PREFIX), :branch]
      elsif ref.start_with?("refs/tags/")
        [ref.delete_prefix("refs/tags/"), :tag]
      elsif ref.start_with?(REMOTES_PREFIX) && !ref.end_with?("/HEAD")
        [ref.delete_prefix(REMOTES_PREFIX), :remote]
      end
    end

    # [ref, commit sha] for every branch and tag, tags peeled to the commit.
    def ref_records
      git("for-each-ref", "--format=%(refname) %(objectname) %(*objectname)", "refs/heads", "refs/remotes", "refs/tags")
        .each_line.map do |line|
          ref, sha, peeled = line.split
          [ref, peeled || sha]
        end
    end
  end
end
