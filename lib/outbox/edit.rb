# frozen_string_literal: true

require "tmpdir"

module Outbox
  # Changing a staged branch from the browser while reviewing it: editing
  # its files, into one of its own commits or as a new one, and rewriting
  # those commits (rewording, dropping, reordering, squashing them), as git
  # rebase -i would.
  #
  # Nothing here has a worktree. Files are changed in a throwaway index,
  # each commit is replayed onto the one before it with git merge-tree, and
  # remade with git commit-tree, keeping its author, date and message. The
  # branch then moves only if it is still where the reviewer saw it
  # (update-ref with the old value), as a push does; so an edit is written
  # from the request, like a push from the browser, not queued on the
  # repo's actor. A push that lands first wins, and the edit is refused.
  #
  # Every edit is in the branch's reflog, "outbox: edit by <who>: <what>",
  # which is how the branch page tells the last move was an edit and offers
  # to undo it. It also leaves a review comment on the tip it replaced, so
  # whoever pushed that learns from its review what became of it.
  class Repo
    # Who makes the commits an edit writes. The author of a new commit, and
    # the committer of every commit made or remade; a remade commit keeps
    # its own author. From OUTBOX_AUTHOR ("Name <email>") when the server
    # has one, else the reviewer's username.
    class Identity
      attr_reader :name, :email

      def initialize(name:, email:)
        @name = name
        @email = email
      end

      # "Name <email>", or nil when text is not one.
      def self.parse(text)
        m = /\A\s*([^<>\n]*?)\s*<([^<>\s]+)>\s*\z/.match(text.to_s) or return nil
        m[1].empty? ? nil : new(name: m[1], email: m[2])
      end

      def self.for(reviewer, configured = ENV["OUTBOX_AUTHOR"])
        parse(configured) || new(name: reviewer, email: "outbox@localhost")
      end

      def to_s = "#{name} <#{email}>"
      def committer_env = { "GIT_COMMITTER_NAME" => name, "GIT_COMMITTER_EMAIL" => email }
      def author_env = { "GIT_AUTHOR_NAME" => name, "GIT_AUTHOR_EMAIL" => email }
    end

    # A replay that could not be made cleanly: sha, the commit that no
    # longer applies, and paths, the files it conflicts in.
    class Conflict < GitError
      attr_reader :sha, :paths

      def initialize(message, sha, paths)
        super(message)
        @sha = sha
        @paths = paths
      end
    end

    # A commit as git stores it, read raw: what remaking it elsewhere needs.
    # The message is bytes, as written, in encoding (nil for UTF-8).
    class RawCommit
      attr_reader :sha, :tree, :parents, :author, :author_date, :encoding, :message

      def initialize(sha:, tree:, parents:, author:, author_date:, encoding:, message:)
        @sha = sha
        @tree = tree
        @parents = parents
        @author = author
        @author_date = author_date
        @encoding = encoding
        @message = message
      end

      def parent = parents.first

      # The author as git takes it from the environment, date and all.
      def author_env
        name, email = author
        { "GIT_AUTHOR_NAME" => name, "GIT_AUTHOR_EMAIL" => email, "GIT_AUTHOR_DATE" => author_date }
      end

      def subject = message.dup.force_encoding(Encoding::UTF_8).scrub.lines.first.to_s.strip
    end

    # One step of a replay, as git rebase -i has them: pick (make it again
    # as it was), reword (with message), squash (into the commit made
    # before it, whose message gets this one's, or message, after it),
    # fixup (into the one before, keeping that one's message), drop.
    class Step
      ACTIONS = %i[pick reword squash fixup drop].freeze

      attr_reader :action, :sha, :message

      def initialize(action, sha, message = nil)
        raise ArgumentError, "unknown action #{action.inspect}" unless ACTIONS.include?(action)
        @action = action
        @sha = sha
        @message = message
      end
    end

    # The commits of a branch an edit can rewrite: its own, the ones no
    # remote has, oldest first, and onto, the commit they build on. Empty
    # when the branch has none, and then onto is its tip.
    class Stack
      attr_reader :onto, :commits

      def initialize(onto:, commits:)
        @onto = onto
        @commits = commits
      end

      def include?(sha) = commits.any? { |c| c.sha == sha }
      def empty? = commits.empty?
    end

    # What an edit did: the branch's tip before and after, and in words.
    # rewritten maps each commit replaced to the one made from it; emptied
    # lists those dropped because nothing was left of them.
    class Edit
      attr_reader :branch, :old, :new, :description, :rewritten, :emptied

      def initialize(branch:, old:, new:, description:, rewritten: {}, emptied: [])
        @branch = branch
        @old = old
        @new = new
        @description = description
        @rewritten = rewritten
        @emptied = emptied
      end
    end

    # The last move of a branch, when it was an edit (Edit): who made it,
    # when, what it did, and the tip it replaced.
    class EditRecord
      attr_reader :by, :description, :time, :old, :new

      def initialize(by:, description:, time:, old:, new:)
        @by = by
        @description = description
        @time = time
        @old = old
        @new = new
      end
    end

    # One file an edit changes: the file at path gets content.
    class FileChange
      attr_reader :path, :content

      def initialize(path:, content:)
        @path = path
        @content = content
      end
    end

    # The most commits a stack holds: replaying is a few git commands each.
    STACK_LIMIT = 200

    # Files larger than this are not edited in the browser: the whole file
    # is posted back.
    MAX_EDIT_BYTES = 1_000_000

    EDIT_REFLOG_RE = /\Aoutbox: edit by (?<by>.*?): (?<what>.*)\z/

    # The commits of the branch an edit can rewrite (Stack). Raises
    # ArgumentError, saying why, when they cannot be: a merge among them,
    # a history that builds on nothing a remote has, too many.
    def stack(branch)
      b = resolve(branch)
      raise ArgumentError, "#{b.name} has nothing staged" unless b.staged
      own = {}
      boundary = []
      git("rev-list", "--topo-order", "--parents", "--boundary", "refs/heads/#{b.name}", "--not", "--remotes").each_line do |line|
        sha, *parents = line.split
        sha.start_with?("-") ? boundary << sha.delete_prefix("-") : own[sha] = parents
      end
      return Stack.new(onto: b.staged, commits: []) if own.empty?
      raise ArgumentError, "#{b.name} has #{own.size} commits of its own; at most #{STACK_LIMIT} can be edited here" if own.size > STACK_LIMIT
      if (merge = own.find { |_, parents| parents.size > 1 })
        raise ArgumentError, "#{b.name} has a merge, #{merge[0][0, 10]}, among its own commits; only a straight line of commits can be edited here"
      end
      if own.any? { |_, parents| parents.empty? } || boundary.size != 1
        raise ArgumentError, "#{b.name}'s commits build on nothing a remote has, so there is no commit to replay them onto"
      end
      Stack.new(onto: boundary.first, commits: log(own.size, "--topo-order", "refs/heads/#{b.name}", "--not", "--remotes").reverse)
    end

    # Rewrite the branch's own commits as steps say, oldest first: each of
    # them once, in the order they are to be made. expected is the tip the
    # reviewer saw. Returns the Edit.
    def rewrite!(branch, steps:, expected:, identity:, by:)
      b = resolve(branch)
      check_sha!(b, "changed", "deleted", expected, b.staged)
      s = stack(b)
      named = steps.map(&:sha)
      unless named.uniq.size == named.size && named.sort == s.commits.map(&:sha).sort
        raise ArgumentError, "the plan must name each of #{b.name}'s #{pluralize_commits(s.commits.size)} once"
      end
      tip, rewritten, emptied = replay(s.onto, steps, identity)
      raise ArgumentError, "that leaves #{b.name} as it is" if tip == b.staged
      move!(b.name, tip, b.staged, by:, description: with_emptied(describe_plan(s, steps), emptied), rewritten:, emptied:)
    end

    # Change files (FileChanges) of a branch as they are at base, the
    # commit whose files the reviewer edited: the branch's tip, or one of
    # its own commits. The change is folded into into, one of the branch's
    # own commits, which keeps its message; or, without into, becomes a new
    # commit on top, with message and identity as its author. Either way it
    # is made as a commit on base and put where it goes by a replay, with
    # the commits after it, so a change the later commits cannot take, or
    # that does not apply as far back as into, is refused (Conflict).
    def commit_files!(branch, base:, changes:, identity:, by:, message: nil, into: nil)
      b = resolve(branch)
      raise ArgumentError, "#{b.name} has nothing staged to edit" unless b.staged
      s = stack(b)
      raise ArgumentError, "#{b.name} has no commits of its own to edit" if s.empty?
      unless s.include?(base)
        raise GitError, "#{b.name} was rewritten since you started editing: #{base.to_s[0, 10]} is no longer one of its commits. Look again."
      end
      target = s.commits.find { |c| c.sha == into } or raise ArgumentError, "#{into.to_s[0, 10]} is not one of #{b.name}'s own commits" if into
      raise ArgumentError, "nothing to commit" if changes.empty?
      tree = tree_with(base, changes)
      raise ArgumentError, "that changes nothing" if tree == tree_of(base)
      what = describe_changes(changes)
      change = commit_tree(tree, [base], into ? "outbox: #{what}\n" : clean_message(message), identity.author_env, identity)
      steps = s.commits.flat_map { |c| c.sha == into ? [Step.new(:pick, c.sha), Step.new(:fixup, change)] : [Step.new(:pick, c.sha)] }
      steps << Step.new(:pick, change) unless into
      begin
        tip, rewritten, emptied = replay(s.onto, steps, identity)
      rescue Conflict => e
        raise unless e.sha == change
        files = e.paths.join(", ")
        raise Conflict.new("The change does not apply to #{target.short[0, 7]} “#{target.subject}”: #{files} is different there. " \
                           "Amend a later commit, or make it a new commit.", change, e.paths) if into
        raise Conflict.new("The change does not apply on top of #{b.name}: later commits changed the same lines of #{files}.", change, e.paths)
      end
      rewritten.delete(change)
      where = into ? "in #{target.short[0, 7]} “#{target.subject}”" : "in a new commit"
      move!(b.name, tip, b.staged, by:, description: with_emptied("#{what} #{where}", emptied), rewritten:, emptied:)
    end

    # For each file the branch's own commits change, the newest of them
    # to do so: { path => sha }. Where an edit of the file most likely
    # belongs.
    def touched(stack)
      return {} if stack.empty?
      out = git("log", "-z", "--format=%x01%H", "--name-only", "--no-renames", "#{stack.onto}..#{stack.commits.last.sha}")
      found = {}
      out.split("\x01").each do |record|
        sha, *files = record.split("\0").map(&:strip).reject(&:empty?)
        files.each { |f| found[f] ||= sha }
      end
      found
    end

    # The last move of a branch, if it was an edit (EditRecord), else nil.
    def last_edit(branch)
      out = git("log", "-g", "-n", "2", "--date=unix", "--format=%H%x1f%gs%x1f%gd", "refs/heads/#{branch}", "--", ok: [0, 128])
      latest, before = out.lines.map { |l| l.chomp.split("\x1f", 3) }
      return nil unless latest && before && (m = EDIT_REFLOG_RE.match(latest[1].to_s))
      time = latest[2].to_s[/@\{(\d+)\}\z/, 1]
      EditRecord.new(by: m[:by], description: m[:what], time: time && Time.at(time.to_i), old: before.first, new: latest[0])
    end

    # Put a branch back as it was before its last move, which must be an
    # edit, and the branch still at what the edit made (expected). Takes
    # back the comment the edit left. Returns the EditRecord undone.
    def undo_edit!(branch, expected:, by:)
      rec = last_edit(branch) or raise ArgumentError, "#{branch}'s last change was not an edit made here"
      raise GitError, "#{branch} changed since you looked (saw #{expected.to_s[0, 10]}, now #{rec.new[0, 10]}). Look again." unless rec.new == expected
      ref = "refs/heads/#{branch}"
      git("update-ref", "-m", "outbox: undo by #{reflog_safe(by)}: #{rec.description}", ref, rec.old, rec.new)
      note = comments(rec.old).find { |c| c.editable? && c.description.include?(rec.new) }
      delete_comment!(rec.old, note.id) if note
      rec
    end

    # Whether the file at path in sha can be edited here, and if not, why:
    # nil when it can.
    def uneditable_reason(sha, file)
      entry = tree_entry(sha, file) or return "there is no file #{file}"
      return "it is a symbolic link" if entry[:mode] == "120000"
      return "it is not a file" unless %w[100644 100755].include?(entry[:mode])
      return "it is too large to edit here" if git("cat-file", "-s", entry[:id]).to_i > MAX_EDIT_BYTES
      text = Git.run("cat-file", "blob", entry[:id], chdir: path, binary: true).force_encoding(Encoding::UTF_8)
      return "it is binary" if text.include?("\0")
      "it is not UTF-8 text" unless text.valid_encoding?
    end

    # Lines end in CRLF throughout.
    def self.crlf?(text) = text.include?("\r\n") && text.count("\n") == text.scan("\r\n").size

    # A path a file in a tree can have, as git ls-tree takes one: relative,
    # no empty, "." or ".." parts, no control characters.
    def self.tree_path?(path)
      path = path.to_s
      return false if path.empty? || path.bytesize > 4096 || path.match?(/[\x00-\x1f\x7f]/)
      path.split("/", -1).none? { |s| s.empty? || s == "." || s == ".." }
    end

    private

    def pluralize_commits(n) = n == 1 ? "1 commit" : "#{n} commits"

    # Make each step's commit again on the one before, starting from onto.
    # Returns [tip, { replaced => made }, [emptied]]. A commit whose parent
    # is already what it would build on, left as it is, is kept as it is,
    # sha and all. A commit that a replay leaves with no changes, having had
    # some, is dropped, as git rebase does. Raises Conflict when one does
    # not apply.
    def replay(onto, steps, identity)
      current = onto
      rewritten = {}
      emptied = []
      # The commits that end up in current: the one it was made from, and
      # any squashed or folded into it since.
      group = []
      settle = -> { group.each { |sha| rewritten[sha] = current } }
      steps.each do |step|
        next if step.action == :drop
        c = raw_commit(step.sha)
        tree = c.parent == current ? c.tree : pick_tree(c, current)
        case step.action
        when :pick, :reword
          settle.()
          group = []
          if tree == tree_of(current) && c.tree != (c.parent ? tree_of(c.parent) : nil)
            emptied << c.sha
            next
          end
          current =
            if step.action == :pick && c.parent == current then c.sha
            else
              message = step.action == :reword ? clean_message(step.message) : c.message
              commit_tree(tree, [current], message, c.author_env, identity, encoding: step.action == :reword ? nil : c.encoding)
            end
          group = [c.sha]
        when :squash, :fixup
          raise ArgumentError, "#{c.sha[0, 10]} has no commit before it to be #{step.action == :squash ? "squashed" : "folded"} into" if current == onto
          prev = raw_commit(current)
          extra = step.action == :fixup ? "" : (step.message || c.message).b.gsub("\r\n", "\n").strip
          message = extra.empty? ? prev.message : "#{prev.message.b.rstrip}\n\n#{extra}\n"
          current = commit_tree(tree, prev.parents, message, prev.author_env, identity, encoding: prev.encoding)
          group << c.sha
        end
      end
      settle.()
      [current, rewritten, emptied]
    end

    # The tree of c's change made on current: a three-way merge from c's
    # parent. Raises Conflict naming the files that would not merge.
    def pick_tree(c, current)
      out = git("merge-tree", "--write-tree", "--name-only", "--no-messages", "--merge-base=#{c.parent}", current, c.sha, ok: [0, 1])
      tree, *conflicts = out.lines.map(&:chomp).reject(&:empty?)
      return tree if conflicts.empty?
      conflicts.uniq!
      raise Conflict.new("#{c.sha[0, 7]} “#{c.subject}” no longer applies: it conflicts in #{conflicts.join(", ")}", c.sha, conflicts)
    end

    def raw_commit(sha)
      data = Git.run("cat-file", "commit", sha, chdir: path, binary: true)
      head, message = data.split("\n\n", 2)
      fields = { parents: [] }
      head.each_line(chomp: true) do |line|
        next if line.start_with?(" ") # the rest of a multi-line header (gpgsig)
        key, value = line.split(" ", 2)
        case key
        when "tree" then fields[:tree] = value
        when "parent" then fields[:parents] << value
        when "author" then fields[:author_line] = value
        when "encoding" then fields[:encoding] = value
        end
      end
      m = /\A(?<name>.*) <(?<email>.*)> (?<time>\d+) (?<zone>[+-]\d{4})\z/n.match(fields[:author_line].to_s) or
        raise GitError, "#{sha[0, 10]} has an author line git cannot be given back"
      RawCommit.new(sha:, tree: fields[:tree], parents: fields[:parents], author: [m[:name], m[:email]],
                    author_date: "@#{m[:time]} #{m[:zone]}", encoding: fields[:encoding], message: message.to_s)
    end

    # A new commit object. author: GIT_AUTHOR_* for it; identity commits it.
    # encoding: the message's, when not UTF-8.
    def commit_tree(tree, parents, message, author, identity, encoding: nil)
      args = ["commit-tree", tree, *parents.flat_map { |p| ["-p", p] }, "-F", "-"]
      args = ["-c", "i18n.commitEncoding=#{encoding}", *args] if encoding && !encoding.casecmp?("utf-8")
      git(*args, input: message, extra: author.merge(identity.committer_env)).strip
    end

    def tree_of(sha) = (@trees ||= {})[sha] ||= git("rev-parse", "#{sha}^{tree}").strip

    # { mode:, type:, id: } of what is at path in sha, or nil.
    def tree_entry(sha, file)
      return nil unless Repo.tree_path?(file)
      out = git("ls-tree", "-z", sha, "--", file)
      record = out.split("\0").find { |r| r.split("\t", 2)[1] == file } or return nil
      mode, type, id = record.split("\t", 2).first.split
      { mode:, type:, id: }
    end

    # The tree of sha with changes made to it, in a throwaway index. Each
    # must be a file there that can be edited (uneditable_reason), and keeps
    # its mode, and its CRLF line ends if it had them: an editor in a
    # browser gives back LF.
    def tree_with(sha, changes)
      records = changes.map do |c|
        if (why = uneditable_reason(sha, c.path))
          raise ArgumentError, "#{c.path} cannot be edited here: #{why}"
        end
        content = c.content.gsub("\r\n", "\n")
        content = content.gsub("\n", "\r\n") if Repo.crlf?(git("cat-file", "blob", "#{sha}:#{c.path}"))
        blob = git("hash-object", "-w", "--stdin", input: content).strip
        "#{tree_entry(sha, c.path)[:mode]} #{blob}\t#{c.path}\0"
      end
      Dir.mktmpdir("outbox-edit") do |dir|
        env = { "GIT_INDEX_FILE" => File.join(dir, "index") }
        git("read-tree", sha, extra: env)
        git("update-index", "-z", "--index-info", input: records.join, extra: env)
        git("write-tree", extra: env).strip
      end
    end

    # "Edited a.rb", "Edited 3 files".
    def describe_changes(changes) = changes.size == 1 ? "Edited #{changes.first.path}" : "Edited #{changes.size} files"

    # What a plan does to a stack, in words: "Dropped 1a2b3c4 “Subject”;
    # Reworded 2 commits; Reordered commits".
    def describe_plan(stack, steps)
      named = ->(verb, list, tail = "") do
        next nil if list.empty?
        c = stack.commits.find { |x| x.sha == list.first.sha }
        list.size == 1 ? "#{verb} #{c.short[0, 7]} “#{c.subject}”#{tail}" : "#{verb} #{list.size} commits#{tail}"
      end
      by = steps.group_by(&:action)
      kept = steps.reject { |st| st.action == :drop }.map(&:sha)
      parts = [
        named.("Dropped", by.fetch(:drop, [])),
        named.("Reworded", by.fetch(:reword, [])),
        named.("Squashed", by.fetch(:squash, []) + by.fetch(:fixup, []), " into the commit before"),
        ("Reordered commits" if kept != stack.commits.map(&:sha) & kept),
      ].compact
      parts.empty? ? "Replayed #{pluralize_commits(steps.size)}" : parts.join("; ")
    end

    def with_emptied(description, emptied)
      return description if emptied.empty?
      "#{description} (#{emptied.size == 1 ? "1 commit" : "#{emptied.size} commits"} left empty dropped)"
    end

    # A message as the browser sends it, as git keeps one: LF line ends,
    # no trailing blank lines, one newline at the end.
    def clean_message(text)
      text = text.to_s.gsub("\r\n", "\n").rstrip
      raise ArgumentError, "the commit message is empty" if text.strip.empty?
      "#{text}\n"
    end

    # Reflog messages are one line.
    def reflog_safe(text) = text.to_s.gsub(/[\x00-\x1f]+/, " ").strip

    # Move the branch from old to new, as an edit by by, and leave a comment
    # saying so on old. Returns the Edit.
    def move!(name, new, old, by:, description:, rewritten: {}, emptied: [])
      description = reflog_safe(description)
      begin
        git("update-ref", "-m", "outbox: edit by #{reflog_safe(by)}: #{description}", "refs/heads/#{name}", new, old)
      rescue GitError
        raise GitError, "#{name} moved while the edit was being made, so it was not; look at #{name} again"
      end
      begin
        add_comment!(old, Comment.new(author: by, commit: old,
                                      description: "Edited in the outbox: #{description}. #{name} is now #{new}."))
      rescue GitError
        # The edit stands; only its note is missing.
      end
      Edit.new(branch: name, old:, new:, description:, rewritten:, emptied:)
    end
  end
end
