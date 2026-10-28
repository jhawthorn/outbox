# frozen_string_literal: true

require "sinatra/base"
require "json"
require "time"
require "erb"
require "digest"

module Outbox
  class App < Sinatra::Base
    set :views, File.expand_path("../../views", __dir__)
    # Holds the diff viewer bundle, built by `rake assets`. Not committed;
    # pages say so when it is missing.
    PUBLIC_DIR = File.expand_path("../../public", __dir__)
    DIFFS_BUNDLE = File.join(PUBLIC_DIR, "diffs/diffs.js")
    # Everything else the pages do in the browser: the ref picker, finding
    # files, keyboard shortcuts, markdown. Pages work without it.
    BROWSE_BUNDLE = File.join(PUBLIC_DIR, "diffs/browse.js")
    set :public_folder, PUBLIC_DIR
    # Sinatra's default reaction to a failed check is to drop the session,
    # which with no sessions is nothing at all. Deny instead, so a form
    # posted from another site (browsers send remembered basic auth with
    # it) cannot approve or discard anything.
    set :protection, reaction: :deny
    set :show_exceptions, false
    set :raise_errors, false
    set :logging, false

    STATUS_LABELS = {
      synced:   "in sync",
      ready:    "ready",
      new:      "new branch",
      deleted:  "deleted",
      diverged: "diverged",
    }.freeze

    helpers do
      def h(text) = Rack::Utils.escape_html(text.to_s)

      # Escape for HTML and make invisible characters visible as their code
      # point. Used for text the server renders: paths, subjects, messages.
      # Diff bodies are rendered in the browser; files containing such
      # characters get a badge instead (Diff::File#hidden_lines).
      def hv(text)
        h(text).gsub(Diff::INVISIBLE_RE) do |c|
          %(<span class="invis" title="hidden character">U+#{c.ord.to_s(16).upcase.rjust(4, "0")}</span>)
        end
      end

      def hub = Outbox.hub

      # Marks the page being rendered as live: it listens on /events and
      # fetches itself again when something it shows changes (the script at
      # the end of views/layout.erb). Called before anything is read, so the
      # page reflects at least the changes up to the seq it records.
      def live! = @seq = hub.seq

      # The error page is never live, even when the page that failed would
      # have been (live! runs before anything that can fail).
      def error_page(code)
        status code
        @seq = nil
        @message = env["sinatra.error"].message
        erb :error
      end

      def job_label(status)
        case status.job
        when :fetch   then "Fetching upstream"
        when :approve then "Pushing #{status.branch} to upstream"
        when :discard then "Discarding #{status.branch}"
        else status.job.to_s
        end
      end

      def repo_url(repo) = "/repos/#{repo.name}"

      # The branches awaiting review, with what can be done about each: the
      # repository's home, since reviewing is what the outbox is for.
      def review_url(repo) = repo_url(repo)

      # The code, on the default branch unless another is being browsed.
      def code_url(repo) = "#{repo_url(repo)}/code"

      # Branch names are the pusher's, and may hold anything git allows,
      # quotes and angle brackets included: escaped like any path.
      def branch_url(repo, branch) = "#{repo_url(repo)}/branches/#{url_path(branch)}"

      def clone_url(repo) = "#{request.base_url}/#{repo.name}.git"

      def config_clone_url = "#{request.base_url}/#{Config::NAME}.git"

      # A rebased branch is diverged to git, and to the approve button, but
      # "rebased" is what the reviewer wants to know.
      def status_label(branch) = branch.rebased? ? "rebased" : STATUS_LABELS.fetch(branch.status, branch.status.to_s)

      def short(sha) = sha ? sha[0, 10] : "—"

      def summary(branch)
        case branch.status
        when :synced   then "nothing staged"
        when :ready    then "#{pluralize(branch.ahead, "commit")} to push"
        when :new      then "#{pluralize(branch.ahead, "commit")} (new branch)"
        when :deleted  then "branch will be deleted upstream (#{pluralize(branch.behind, "commit")} only reachable from it)"
        when :diverged
          if branch.rebased?
            "#{pluralize(branch.ahead, "commit")} to push, rebased onto #{pluralize(branch.picked_up, "newer upstream commit")}; " \
              "replaces #{pluralize(branch.behind, "upstream commit")}"
          else
            "#{pluralize(branch.ahead, "commit")} to push; upstream has #{pluralize(branch.behind, "commit")} not in staged"
          end
        end
      end

      # What becomes of the commits upstream has on a diverged branch, from
      # the pairing (Repo::Rewrite): "2 carried over unchanged, 1 changed,
      # 1 dropped", leaving out the kinds there are none of
      # except dropped, which is always said.
      def rewrite_label(rewrite, dropped)
        parts = []
        parts << "#{rewrite.unchanged.size} carried over unchanged" unless rewrite.unchanged.empty?
        parts << "#{rewrite.changed.size} changed" unless rewrite.changed.empty?
        parts << (dropped.positive? ? "#{dropped} dropped" : "none dropped")
        parts.join(", ")
      end

      # The question the force approve button asks, with what the force
      # drops; when a rebase carries every upstream commit over, that it
      # drops nothing.
      def force_confirm(branch, dropped)
        what =
          if dropped.positive? then "#{pluralize(dropped, "upstream commit")} will be dropped."
          elsif branch.behind == 1 then "The one upstream commit is carried over."
          else "All #{branch.behind} upstream commits are carried over."
          end
        "Force-push #{branch.name} to upstream? #{what}"
      end

      # The force approve button says what it deletes.
      def force_label(dropped) = dropped.positive? ? "Force approve (drops #{pluralize(dropped, "commit")})" : "Force approve"

      def pluralize(n, singular, plural = "#{singular}s") = "#{n} #{n == 1 ? singular : plural}"

      def time_ago(time)
        seconds = [Time.now - time, 0].max.to_i
        case seconds
        when 0...60       then "just now"
        when 60...3600    then "#{pluralize(seconds / 60, "minute")} ago"
        when 3600...86400 then "#{pluralize(seconds / 3600, "hour")} ago"
        else                   "#{pluralize(seconds / 86400, "day")} ago"
        end
      end

      # Where the staged and upstream tips are, as "staged <sha> · upstream <sha>",
      # saying in words which side is missing instead of showing a blank.
      def tips_label(branch)
        staged = %(staged <code>#{short(branch.staged)}</code>)
        upstream = %(upstream <code>#{short(branch.upstream)}</code>)
        case branch.status
        when :new     then "#{staged} · not on upstream yet"
        when :deleted then "deleted here · #{upstream}"
        else               "#{staged} · #{upstream}"
        end
      end

      # A commit's time as git gave it (%cI), or nil when it cannot be read:
      # a commit can say anything about its zone, and one page's worth of
      # bad dates must not take the page down.
      def commit_time(iso)
        Time.iso8601(iso.to_s)
      rescue ArgumentError
        nil
      end

      def committed_label(time)
        return %(<span class="muted">an unreadable date</span>) if time.nil?
        %(<span title="#{h time.utc.strftime("%Y-%m-%d %H:%M:%S UTC")}">#{time_ago(time)}</span>)
      end

      def duration(seconds)
        seconds < 60 ? "#{seconds}s" : "#{seconds / 60}m #{seconds % 60}s"
      end

      # "N", or "latest N of M" when the list was cut off at its limit.
      def commit_total(shown, total) = shown < total ? "latest #{shown} of #{total}" : total.to_s

      # Other branches whose tip is this commit, by sha. Both the staged and
      # the upstream tip count; a branch is listed once per commit.
      def other_tips(branches, branch)
        tips = Hash.new { |h, k| h[k] = [] }
        branches.each do |b|
          next if b.name == branch.name
          [b.staged, b.upstream].compact.uniq.each { |sha| tips[sha] << b.name }
        end
        tips
      end

      def commit_url(repo, branch, commit) = "#{branch_url(repo, branch)}/commits/#{commit.sha}"

      def identity_line(c)
        author = "#{hv c.author} &lt;#{hv c.author_email}&gt;"
        if c.committer_differs?
          "#{author} authored #{when_label(c.date)} · #{hv c.committer} &lt;#{hv c.committer_email}&gt; committed #{when_label(c.commit_date)}"
        else
          "#{author} committed #{when_label(c.date)}"
        end
      end

      # A timestamp from git's %aI/%cI as "2026-10-15 14:28 UTC−7": the
      # clock time of whoever recorded it, with their offset, dimmed. The full
      # timestamp is the tooltip.
      def when_label(iso)
        t = commit_time(iso) or return h(iso)
        %(<span title="#{h iso}">#{t.strftime("%Y-%m-%d %H:%M")} <span class="off">#{utc_offset_label(t.utc_offset)}</span></span>)
      end

      def utc_offset_label(seconds)
        return "UTC" if seconds.zero?
        hours, minutes = (seconds.abs / 60).divmod(60)
        "UTC#{seconds.negative? ? "\u2212" : "+"}#{hours}#{format(":%02d", minutes) unless minutes.zero?}"
      end

      def identity(name, email) = "#{hv name} <i>&lt;#{hv email}&gt;</i>"

      # What the second line of a commit shows, if anything: the committer
      # when they differ from the author, and when the commit was made when
      # that is a different time. Compared as displayed, so two clocks that
      # agree to the minute don't produce a line repeating the first.
      def committer_line(c)
        who = c.committer_differs? ? identity(c.committer, c.committer_email) : ""
        at = when_label(c.commit_date)
        return nil if who.empty? && at == when_label(c.date)
        [who, at]
      end

      # [commit, before, share] for each commit, newest first: how much of the
      # branch's total change (lines added plus deleted) came before it, and
      # how much it adds, both as percentages.
      def change_shares(commits, stats)
        sizes = commits.map { |c| stats.fetch(c.sha, [0, 0]).sum }
        total = sizes.sum
        before = 0
        rows = commits.zip(sizes).reverse.map do |c, size|
          row = [c, total.zero? ? 0 : 100.0 * before / total, total.zero? ? 0 : 100.0 * size / total]
          before += size
          row
        end
        rows.reverse
      end

      # What a reworked commit changed about the upstream one it replaces,
      # beyond its patch: its old message, author and date. Empty when it
      # differs only in its patch.
      def rework_notes(new, old)
        notes = []
        notes << "message was “#{old.subject}”" unless new.message == old.message
        notes << "author was #{old.author}" unless new.author == old.author && new.author_email == old.author_email
        notes << "dated #{when_label(old.date)} upstream" unless new.date == old.date
        notes
      end

      def file_status_label(file)
        case file.status
        when :added   then "added"
        when :deleted then "deleted"
        when :renamed then "renamed"
        when :copied  then "copied"
        end
      end

      # Renders the summary and one placeholder per file; the browser fetches
      # patch_url and draws the diffs (assets/diffs.js).
      # rev is the commit whose files the summary links to, if any.
      # comments, on a branch page: what diffs.js needs to draw its line
      # comments and offer a form on the lines selected (line_comments_data).
      def render_patch(patch, patch_url, rev = nil, comments: nil)
        patch_url = "#{patch_url}?w=1" if ignore_whitespace?
        erb :_patch, layout: false, locals: { patch: patch, patch_url: patch_url, rev: rev, comments: comments }
      end

      # The branch page's line comments, for the diff viewer, and where a new
      # one is posted. removed says whether lines on the old side can take one.
      def line_comments_data
        return nil unless @branch.staged
        list = @comment_places.map do |c, (path, side)|
          { path:, side:, start: c.start_line, end: c.end_line, author: c.author, time: c.time.utc.iso8601, description: c.description }
        end
        { url: "#{branch_url(@repo, @branch.name)}/comments", expected: @branch.staged, removed: !@removed_commit.nil?, list: }
      end

      def diffs_built? = File.exist?(DIFFS_BUNDLE)

      # Whether the reader asked for diffs without whitespace changes (?w=1).
      def ignore_whitespace? = params[:w] == "1"

      # This page's URL with ?w= set or not.
      def whitespace_url(on)
        query = request.GET.except("w")
        query["w"] = "1" if on
        query.empty? ? request.path : "#{request.path}?#{Rack::Utils.build_query(query)}"
      end

      def browse_built? = File.exist?(BROWSE_BUNDLE)

      # What a search result highlights: the query as a Ruby regexp, ignoring
      # case as git grep did. nil when it cannot be one (git's extended
      # regexps are not quite Ruby's), and then nothing is highlighted.
      def search_pattern(query, regex)
        flags = query.match?(/[[:upper:]]/) ? nil : Regexp::IGNORECASE
        Regexp.new(regex ? query : Regexp.escape(query), flags, timeout: 0.05)
      rescue RegexpError
        nil
      end

      # A line of a result, escaped, with what matched in <mark>.
      def mark_matches(text, pattern)
        return hv(text) unless pattern
        out = +""
        pos = 0
        text.scan(pattern) do
          m = Regexp.last_match
          next if m[0].empty?
          out << hv(text[pos...m.begin(0)]) << "<mark>" << hv(m[0]) << "</mark>"
          pos = m.end(0)
        end
        out << hv(text[pos..])
      rescue Regexp::TimeoutError
        hv(text)
      end

      # A path in a URL, each segment escaped and the slashes kept. Branch
      # names have slashes too, and are written the same way.
      # Everything but unreserved characters is percent-encoded, so the
      # result is safe in any attribute and never ends early at a "?" or "#".
      def url_path(path) = path.to_s.split("/", -1).map { |s| ERB::Util.url_encode(s) }.join("/")

      # Files and directories share one URL shape: /tree/<rev>/<path>, where
      # rev is a branch, a remote's branch, a tag or a sha (Repo#resolve_path).
      def tree_url(repo, rev, path = "") = browse_url(repo, "tree", rev, path)
      def raw_url(repo, rev, path) = browse_url(repo, "raw", rev, path)
      def blame_url(repo, rev, path) = browse_url(repo, "blame", rev, path)
      def history_url(repo, rev, path = "") = browse_url(repo, "commits", rev, path)
      def search_url(repo) = "#{repo_url(repo)}/search"

      def browse_url(repo, kind, rev, path)
        [repo_url(repo), kind, url_path(rev), *(path.to_s.empty? ? [] : [url_path(path)])].join("/")
      end

      # Any commit in the repository, with what it changed.
      def show_commit_url(repo, sha) = "#{repo_url(repo)}/commit/#{sha}"

      # The breadcrumbs of a path inside a commit: the repository, then each
      # directory as a link; the last name, which is the page itself, is not.
      # kind is the page the links go to: "tree", or "commits" for history.
      def path_crumbs(repo, rev, path, kind: "tree")
        names = path.split("/")
        link = ->(text, upto) { %(<a class="crumb" href="#{browse_url(repo, kind, rev, upto)}">#{text}</a>) }
        root = names.empty? ? %(<b>#{h repo.name}</b>) : link.(h(repo.name), "")
        links = names.each_index.map do |i|
          i == names.size - 1 ? %(<b>#{hv names[i]}</b>) : link.(hv(names[i]), names[0..i].join("/"))
        end
        [root, *links].join(%(<span class="sep">/</span>))
      end

      # A rev as the ref picker shows it: the branch or tag name, or a short
      # sha.
      def rev_label(rev) = rev.commit? ? rev.sha[0, 10] : rev.name

      REV_KIND_LABELS = { branch: "branch", remote: "remote branch", tag: "tag", commit: "commit" }.freeze

      # Where a page under a rev can go for another rev: the same URL with
      # {rev} in its place.
      def rev_template(kind, path) = browse_url(@repo, kind, "rev", path).sub("/#{kind}/rev", "/#{kind}/{rev}")

      # The tabs at the top of a repository's pages.
      def repo_tabs(active)
        pending = @repo.pending_branches.size
        rev = @rev && !@rev.commit? ? @rev.name : nil
        code = rev || @repo.default_rev&.name
        tabs = [
          ["review", "Review", review_url(@repo), pending],
          ["code", "Code", code ? tree_url(@repo, code) : code_url(@repo), nil],
          ["commits", "Commits", rev ? history_url(@repo, rev) : "#{repo_url(@repo)}/commits", nil],
          ["branches", "Branches", "#{repo_url(@repo)}/branches", nil],
        ]
        tabs.map do |key, label, url, count|
          badge = count&.positive? ? %( <span class="count-pill">#{count}</span>) : ""
          # The label holds room for its bold self, so the tabs keep still
          # when the active one changes.
          %(<a class="tab#{" active" if key == active}" href="#{url}"#{%( aria-current="page") if key == active}><span class="label" data-label="#{label}">#{label}</span>#{badge}</a>)
        end.join
      end

      # A file's contents, when the page shows it as text: the size and line
      # count, and whether it is binary, an image or markdown.
      IMAGE_TYPES = {
        ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
        ".webp" => "image/webp", ".avif" => "image/avif", ".bmp" => "image/bmp", ".ico" => "image/x-icon",
        ".svg" => "image/svg+xml",
      }.freeze

      def image?(path) = IMAGE_TYPES.key?(File.extname(path).downcase)

      # How a file's bytes are served: as what they are, and never as
      # anything a browser would run. An SVG, say, is sandboxed.
      def raw_headers(type, immutable:)
        headers "Content-Type" => type,
                "X-Content-Type-Options" => "nosniff",
                "Content-Security-Policy" => "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox",
                "Content-Disposition" => "inline",
                "Cache-Control" => immutable ? "private, max-age=31536000, immutable" : "no-cache"
      end

      # Reads the directory for the code browser
      # (views/_tree.erb).
      def load_tree(rev, path)
        @rev = rev
        @sha = rev.sha
        @path = path
        @entries = @repo.tree_entries(@sha, @path)
        @last = @repo.last_commit(@sha, @path)
      end

      # The rev a URL path starts with, and the rest of the path.
      def resolve_path!(repo, splat)
        rev, rest = repo.resolve_path(splat.to_s)
        raise NotFound, "no branch, tag or commit named #{splat.to_s.split("/").first.inspect}" unless rev
        [rev, rest]
      end

      # "12 bytes", "3.4 KB", "1.2 MB".
      def byte_size(n)
        return pluralize(n, "byte") if n < 1000
        units = %w[KB MB GB]
        value = n.to_f
        unit = units.shift
        value /= 1000
        (value /= 1000; unit = units.shift) while value >= 1000 && !units.empty?
        format("%.#{value < 10 ? 1 : 0}f %s", value, unit)
      end

      def branch_patch_url(repo, branch) = "#{branch_url(repo, branch)}.patch"

      def commit_patch_url(repo, branch, sha) = "#{branch_url(repo, branch)}/commits/#{sha}.patch"

      # The commit must be part of what is staged on the branch; anything
      # else in the repo (upstream history, other branches) is not shown.
      # Returns the commit list and the commit's index in it, newest first.
      def staged_commit!(repo, branch, sha)
        list = repo.commits(branch, limit: 1000)
        index = list.index { |c| c.sha == sha }
        raise NotFound, "that commit is not part of what is staged on #{branch.name}" unless index
        [list, index]
      end

      # The staged and upstream shas the reviewer saw, "" for a branch that
      # is deleted or not on upstream. Required: a request without them would
      # act on whatever happens to be there, not on the diff that was shown.
      def expected_shas!
        {
          expected: params.fetch("expected") { raise ArgumentError, "missing expected: the staged sha that was reviewed" },
          expected_upstream: params.fetch("expected_upstream") do
            raise ArgumentError, "missing expected_upstream: the upstream sha that was reviewed"
          end
        }
      end

      def show_path(name, splat)
        @repo = Repo.find!(name)
        rev, path = resolve_path!(@repo, splat)
        case @repo.object_type(rev.sha, path)
        when "blob"
          @rev = rev
          @sha = rev.sha
          @path = path
          @blob = @repo.file_blob(@sha, @path)
          @size = @repo.git("cat-file", "-s", @blob).to_i
          @image = image?(@path)
          @last = @repo.last_commit(@sha, @path)
          if @size <= Repo::MAX_BLOB_BYTES && !@image
            contents = @repo.blob(@blob)
            @binary = contents.include?("\0")
            @lines = contents.count("\n") + (contents.empty? || contents.end_with?("\n") ? 0 : 1)
            @markdown = !@binary && Repo.markdown?(@path)
            @plain = params[:plain] == "1"
            @source = contents if @markdown && !@plain
          else
            @binary = true
          end
          erb :file
        when "tree"
          load_tree(rev, path)
          erb :tree
        else
          raise NotFound, "no file or directory #{path} in #{rev_label(rev)}"
        end
      end

      def tree_commits(name, sha, path)
        repo = Repo.find!(name)
        raise NotFound, "not a commit id: #{sha.inspect}" unless sha.match?(/\A[0-9a-f]{40,64}\z/)
        found, complete = repo.tree_commits(sha, path.delete_suffix("/"))
        content_type :json
        # A walk cut short may find more another time.
        headers "Cache-Control" => complete ? "private, max-age=31536000, immutable" : "no-cache"
        JSON.generate(found.transform_values { |c| { sha: c.sha, subject: c.subject, author: c.author, date: c.commit_date } })
      end

      # The two revs of a compare URL: "base...head", or a head alone
      # against the default branch.
      def compare_revs!(repo, spec)
        base_name, head_name = spec.include?("...") ? spec.split("...", 2) : [repo.default_rev&.name, spec]
        base = repo.rev(base_name.to_s) or raise NotFound, "no branch, tag or commit named #{base_name.inspect}"
        head = repo.rev(head_name.to_s) or raise NotFound, "no branch, tag or commit named #{head_name.inspect}"
        [base, head]
      end

      def compare_url(repo, base, head) = "#{repo_url(repo)}/compare/#{url_path(base)}...#{url_path(head)}"

      # The tip of each branch, as RefInfo by branch name: what is staged, or
      # for a branch deleted here, what upstream has. Says what each branch
      # in the review list is about.
      def latest_commits(repo)
        upstream = "#{repo.push_remote}/"
        found = {}
        repo.ref_list.each do |r|
          if r.kind == :branch then found[r.name] = r
          elsif r.kind == :remote && r.name.start_with?(upstream) then found[r.name.delete_prefix(upstream)] ||= r
          end
        end
        found
      end

      # Where to go after an edit or a delete: the page it was done from,
      # if that is one of this repository's, else the repository's.
      def back_within(repo)
        back = params[:back].to_s
        back.start_with?("#{repo_url(repo)}/") && !back.include?("//") ? back : repo_url(repo)
      end

      def comment_url(repo, sha, c) = "#{repo_url(repo)}/comments/#{sha}/#{c.id}"

      # A hash of the comments a page shows, so a live page can tell when
      # they've changed.
      def comments_seen(comments) = Digest::SHA1.hexdigest(comments.map(&:version).sort.join(" "))[0, 16]

      # Who is reviewing, for the comments they leave: the username they gave
      # the password with. Any name does for the password, so this is only
      # what they call themselves.
      def reviewer
        auth = Rack::Auth::Basic::Request.new(env)
        user = auth.provided? && auth.basic? ? auth.username.to_s.strip : ""
        user.empty? ? "reviewer" : user
      end

      # Where a posted comment goes (Comment): the staged tip, and a file
      # and lines in it if the form names them. Lines on side L are in the
      # commit the diff starts from.
      def comment_location(repo, branch)
        path = params[:path].to_s
        return { commit: branch.staged } if path.empty?
        return { commit: branch.staged, path: path } if params[:start].to_s.empty?
        start_line, end_line = Integer(params[:start], 10), Integer(params.fetch(:end, params[:start]), 10)
        raise ArgumentError, "bad line range #{start_line}-#{end_line}" unless start_line.positive? && end_line >= start_line
        commit =
          case params[:side]
          when "R" then branch.staged
          when "L" then repo.removed_lines_commit(branch) or raise ArgumentError, "removed lines on #{branch.name} cannot be commented on"
          else raise ArgumentError, "side must be L or R"
          end
        { commit:, path:, start_line:, end_line: }
      end

      # The comments the branch page shows, and where in its diff each line
      # comment goes: [comments, { comment => [path, side] }].
      def review_comments(repo, branch, removed_commit)
        return [[], {}] unless branch.staged
        comments = repo.comments(branch.staged)
        places = {}
        comments.each do |c|
          next unless c.line?
          side = if c.commit == branch.staged then "R" elsif removed_commit && c.commit == removed_commit then "L" end
          places[c] = [c.path, side] if side
        end
        [comments, places]
      end

      def send_patch(patch)
        content_type "text/plain", charset: "utf-8"
        patch.text
      end
    end

    error NotFound do
      error_page 404
    end

    error GitError, ArgumentError do
      error_page 422
    end

    error do
      error_page 500
    end

    PWA_DIR = File.expand_path("../../pwa", __dir__)
    PWA_FILES = %w[icon-192.png icon-512.png icon-maskable-512.png apple-touch-icon.png].freeze

    MANIFEST = JSON.generate(
      name: "outbox",
      short_name: "outbox",
      description: "Review pushes before they go upstream",
      id: "/",
      start_url: "/",
      scope: "/",
      display: "standalone",
      background_color: "#0d1117",
      theme_color: "#0d1117",
      icons: [
        { src: "/pwa/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
        { src: "/pwa/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
        { src: "/pwa/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
      ],
    ).freeze

    get "/manifest.webmanifest" do
      content_type "application/manifest+json"
      MANIFEST
    end

    # Pages are live and behind a password, so the worker caches nothing but
    # an offline page, shown when the network is unreachable.
    get "/sw.js" do
      content_type "text/javascript"
      headers "Cache-Control" => "no-cache"
      send_file File.join(PWA_DIR, "sw.js")
    end

    get "/offline" do
      erb :offline
    end

    get "/pwa/:file" do
      halt 404 unless PWA_FILES.include?(params[:file])
      headers "Cache-Control" => "private, max-age=86400"
      send_file File.join(PWA_DIR, params[:file])
    end

    # The body of /events. A Rack 3 streaming body: puma writes the headers,
    # calls this with the socket, and leaves the connection to it, so the
    # request thread is free again at once. (Each in its place would hold
    # the thread for as long as the page stays open.)
    class EventStream
      def initialize(hub) = @hub = hub
      def call(stream) = @hub.subscribe(stream)
    end

    # Server-sent events naming each repository that changes. See Notifier.
    get "/events" do
      content_type "text/event-stream"
      headers "cache-control" => "no-cache",
              "x-accel-buffering" => "no" # a proxy must not buffer the stream
      body EventStream.new(hub)
    end

    get "/" do
      live!
      @repos = Repo.all.map { |r| [r, r.branches, hub.status(r), r.last_push_at] }
      # Repos with something to review first, then the rest; within each, the
      # most recently pushed first, and never-pushed ones by name.
      @repos = @repos.sort_by { |r, branches, _, pushed| [branches.any?(&:pending?) ? 0 : 1, pushed ? -pushed.to_i : 0, r.name] }
      @problems = Config.load.problems
      # Fetches of https upstreams fail without the token; say so up front
      # rather than once per repo.
      @needs_token = Repo.upstream_token.nil? && @repos.any? { |r, _, _, _| !r.config? && r.remote_upstream? }
      erb :index
    end

    post "/fetch" do
      hub.fetch_all
      redirect "/"
    end

    # A repository's home is what awaits review in it.
    get "/repos/:name" do
      live!
      @repo = Repo.find!(params[:name])
      @status = hub.status(@repo)
      @branches = @repo.branches
      @latest = latest_commits(@repo)
      erb :review
    end

    # The old address of the review list.
    get "/repos/:name/review" do
      redirect repo_url(Repo.find!(params[:name]))
    end

    # The code: the default branch's files, once there is one.
    get "/repos/:name/code" do
      @repo = Repo.find!(params[:name])
      rev = @repo.default_rev
      redirect tree_url(@repo, rev.name) if rev
      @status = hub.status(@repo)
      erb :code_empty
    end

    post "/repos/:name/fetch" do
      repo = Repo.find!(params[:name])
      hub.fetch(repo)
      redirect(params[:back] || repo_url(repo))
    end

    post "/repos/:name/dismiss" do
      repo = Repo.find!(params[:name])
      hub.dismiss(repo)
      redirect(params[:back] || repo_url(repo))
    end

    # File contents by blob id, which the diff viewer loads to expand the
    # unchanged lines between hunks.
    get "/repos/:name/blobs/:id" do
      content_type "text/plain", charset: "utf-8"
      headers "Cache-Control" => "private, max-age=31536000, immutable"
      Repo.find!(params[:name]).blob(params[:id])
    end

    # An image by blob id, for the diff viewer to show both sides of a
    # changed one. The name after the id is the file's, for its type.
    get "/repos/:name/blobs/:id/*" do
      type = IMAGE_TYPES[File.extname(params[:splat].first).downcase] or raise NotFound, "not an image"
      contents = Repo.find!(params[:name]).raw_blob(params[:id])
      raw_headers(type, immutable: true)
      contents
    end

    # A file or a directory as it is in a commit, at one URL shape whichever
    # the path is: /tree/<rev>/<path>, the commit's root when the path is
    # empty. rev is a branch, a remote's branch ("upstream/main"), a tag or
    # a sha. A file is drawn in the browser by assets/diffs.js from the blob.
    get "/repos/:name/tree/*" do
      show_path(params[:name], params[:splat].first)
    end

    # GitHub's URL for a file, for links pasted from there.
    get "/repos/:name/blob/*" do
      redirect "#{repo_url(Repo.find!(params[:name]))}/tree/#{url_path(params[:splat].first)}"
    end

    # A file's bytes. Text is served as text, images as images, and nothing
    # is served as anything a browser would run: an SVG, say, is sandboxed.
    get "/repos/:name/raw/*" do
      repo = Repo.find!(params[:name])
      rev, path = resolve_path!(repo, params[:splat].first)
      contents, = repo.file_contents(rev.sha, path)
      type = IMAGE_TYPES[File.extname(path).downcase]
      type ||= contents.include?("\0") ? "application/octet-stream" : "text/plain; charset=utf-8"
      raw_headers(type, immutable: rev.commit?)
      contents
    end

    # The last commit to touch each entry of a directory, which the tree
    # listing fills in once it is drawn (assets/browse.js).
    get "/repos/:name/tree-commits/:sha" do
      tree_commits(params[:name], params[:sha], "")
    end

    get "/repos/:name/tree-commits/:sha/*" do
      tree_commits(params[:name], params[:sha], params[:splat].first)
    end

    # Every file in a commit, NUL-separated, for the file finder.
    get "/repos/:name/files/:sha" do
      repo = Repo.find!(params[:name])
      content_type "text/plain", charset: "utf-8"
      headers "Cache-Control" => "private, max-age=31536000, immutable"
      repo.file_list(params[:sha]).join("\0")
    end

    # The branches and tags the ref picker offers, default branch first.
    get "/repos/:name/refs.json" do
      repo = Repo.find!(params[:name])
      default = repo.default_rev&.name
      list = repo.ref_list
      # A staged branch named like a remote's branch or a tag, or like a
      # path inside one, cannot be reached by that name, so it is not offered.
      list.select! { |r| r.kind != :branch || repo.addressable?(r) }
      refs = list.sort_by.with_index { |r, i| [r.name == default ? 0 : 1, REV_PRECEDENCE_ORDER.index(r.kind), i] }
      content_type :json
      JSON.generate(refs.map { |r| { name: r.name, kind: r.kind, default: r.name == default } })
    end

    REV_PRECEDENCE_ORDER = %i[branch tag remote].freeze

    get "/repos/:name/blame/*" do
      @repo = Repo.find!(params[:name])
      @rev, @path = resolve_path!(@repo, params[:splat].first)
      @sha = @rev.sha
      @hunks = @repo.blame(@sha, @path)
      erb :blame
    end

    # History: the default branch's, or a rev's, or only the commits that
    # touched a path.
    HISTORY_PAGE = 50

    get "/repos/:name/commits" do
      repo = Repo.find!(params[:name])
      rev = repo.default_rev or raise NotFound, "#{repo.name} has no commits yet"
      redirect history_url(repo, rev.name)
    end

    get "/repos/:name/commits/*" do
      @repo = Repo.find!(params[:name])
      @rev, @path = resolve_path!(@repo, params[:splat].first)
      @sha = @rev.sha
      @page = [params[:page].to_i, 1].max
      list = @repo.history(@sha, @path, limit: HISTORY_PAGE + 1, skip: (@page - 1) * HISTORY_PAGE)
      @more = list.size > HISTORY_PAGE
      @commits = list.first(HISTORY_PAGE)
      raise NotFound, "nothing in the history of #{@path.empty? ? rev_label(@rev) : @path}" if @commits.empty? && @page > 1
      erb :history
    end

    # Any commit in the repository, branch or none.
    get "/repos/:name/commit/:sha.patch" do
      repo = Repo.find!(params[:name])
      sha = repo.commit_sha(params[:sha]) or raise NotFound, "no commit #{params[:sha]}"
      send_patch(repo.commit_diff(sha, ignore_whitespace: ignore_whitespace?))
    end

    get "/repos/:name/commit/:sha" do
      @repo = Repo.find!(params[:name])
      sha = @repo.commit_sha(params[:sha]) or raise NotFound, "no commit #{params[:sha]}"
      redirect show_commit_url(@repo, sha) unless sha == params[:sha]
      @commit = @repo.commit_detail(sha)
      @patch = @repo.commit_diff(sha, ignore_whitespace: ignore_whitespace?)
      @rev = Repo::Rev.new(name: sha, sha:, kind: :commit)
      @comments = @repo.comments(sha)
      erb :show_commit
    end

    # What one rev has that another does not: /compare/<base>...<head>, or
    # /compare/<head> against the default branch. Names cannot hold "..",
    # so the "..." is unambiguous.
    get "/repos/:name/compare/*.patch" do
      repo = Repo.find!(params[:name])
      base, head = compare_revs!(repo, params[:splat].first)
      send_patch(repo.compare(base.sha, head.sha, ignore_whitespace: ignore_whitespace?)[2])
    end

    get "/repos/:name/compare" do
      repo = Repo.find!(params[:name])
      if params[:head].to_s.empty?
        redirect "#{repo_url(repo)}/branches"
      elsif params[:base].to_s.empty?
        redirect "#{repo_url(repo)}/compare/#{url_path(params[:head].to_s)}"
      else
        redirect "#{repo_url(repo)}/compare/#{url_path(params[:base].to_s)}...#{url_path(params[:head].to_s)}"
      end
    end

    get "/repos/:name/compare/*" do
      @repo = Repo.find!(params[:name])
      @base, @head = compare_revs!(@repo, params[:splat].first)
      @rev = @head
      @commits, @count, @patch, @fork = @repo.compare(@base.sha, @head.sha, ignore_whitespace: ignore_whitespace?)
      @stats = {}
      erb :compare
    end

    get "/repos/:name/branches" do
      @repo = Repo.find!(params[:name])
      @status = {}
      @repo.branches.each { |b| @status[b.name] = b }
      @refs = @repo.ref_list
      @default = @repo.default_rev&.name
      erb :branches
    end

    get "/repos/:name/search" do
      @repo = Repo.find!(params[:name])
      @rev = params[:rev].to_s.empty? ? @repo.default_rev : @repo.rev(params[:rev])
      raise NotFound, "no branch, tag or commit named #{params[:rev].inspect}" unless @rev
      @sha = @rev.sha
      @query = params[:q].to_s
      @regex = params[:regex] == "1"
      @path = params[:path].to_s.delete_prefix("/").delete_suffix("/")
      begin
        @matches, @more, @truncated = @repo.grep(@sha, @query, regex: @regex, path: @path) unless @query.strip.empty?
      rescue GitError => e
        @search_error = e.message.delete_prefix("git grep: ")
      end
      erb :search
    end

    # Raw patches, as the browser fetches them for the diff viewer and as
    # `git apply` wants them. Defined before the page routes: the splat and
    # :sha would otherwise swallow the ".patch".
    get "/repos/:name/branches/*/commits/:sha.patch" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      staged_commit!(repo, branch, params[:sha])
      send_patch(repo.commit_diff(params[:sha], ignore_whitespace: ignore_whitespace?))
    end

    get "/repos/:name/branches/*.patch" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      send_patch(repo.diff(branch, ignore_whitespace: ignore_whitespace?))
    end

    # Must be defined before the branch route, whose splat would otherwise
    # swallow "/commits/<sha>".
    get "/repos/:name/branches/*/commits/:sha" do
      live!
      @repo = Repo.find!(params[:name])
      @branch = @repo.branch(params[:splat].first)
      list, index = staged_commit!(@repo, @branch, params[:sha])
      @commit = @repo.commit_detail(params[:sha])
      @patch = @repo.commit_diff(params[:sha], ignore_whitespace: ignore_whitespace?)
      # list is newest first; present as oldest = 1 of N.
      @newer = index.positive? ? list[index - 1] : nil
      @older = list[index + 1]
      @position = list.size - index
      @total = list.size
      @comments = @repo.comments(params[:sha])
      @comments_seen = comments_seen(@comments)
      erb :commit
    end

    get "/repos/:name/branches/*" do
      live!
      @repo = Repo.find!(params[:name])
      @branch = @repo.branch(params[:splat].first)
      @commits = @repo.commits(@branch)
      @outgoing = @repo.outgoing_commits(@branch)
      @commit_count = @repo.commit_count(@branch)
      @stats = @repo.commit_stats(@branch)
      # Only drawn when the list reaches all the way down to it.
      @base = @repo.base(@branch) if @commits.size == @commit_count
      @outgoing_count = @repo.outgoing_commit_count(@branch)
      @outgoing_stats = @repo.outgoing_commit_stats(@branch)
      @patch = @repo.diff(@branch, ignore_whitespace: ignore_whitespace?)
      @rebase = @repo.rebase(@branch)
      # Upstream commits that live on in a staged one are marked on that
      # one rather than listed as dropped. The pairing covers every commit
      # when there is one, so the list is then complete.
      @rewrite = @repo.rewrite(@branch)
      @dropped = @rewrite ? @outgoing.reject { |c| @rewrite.carried?(c.sha) } : @outgoing
      @dropped_count = @rewrite ? @dropped.size : @outgoing_count
      @upstream_commits = @outgoing.to_h { |c| [c.sha, c] }
      @tips = other_tips(@repo.branches, @branch)
      @removed_commit = @repo.removed_lines_commit(@branch, rebase: @rebase) if @branch.staged
      @comments, @comment_places = review_comments(@repo, @branch, @removed_commit)
      @earlier_comments = @repo.earlier_comments(@branch)
      @comments_seen = comments_seen(@comments + @earlier_comments.flat_map(&:last))
      erb :branch
    end

    # Approve and discard are queued on the repo's actor. The outcome shows
    # up on the repository's pages as the last result. Both must carry the sha the
    # reviewer saw, so a push that lands in between is refused, not approved.
    post "/repos/:name/branches/*/approve" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      hub.approve(repo, branch.name, force: params[:force] == "1", reviewer: reviewer, **expected_shas!)
      redirect review_url(repo)
    end

    post "/repos/:name/branches/*/discard" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      hub.discard(repo, branch.name, reviewer: reviewer, **expected_shas!)
      redirect review_url(repo)
    end

    # A review comment on what is staged: on the whole of it, or on lines
    # of a file in its diff (side R the staged tip's lines, L upstream's).
    # Written straight away, not queued: it moves no branch, only the notes
    # ref, and Repo#add_comment! copes with another writer.
    post "/repos/:name/branches/*/comments" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      expected = params.fetch("expected") { raise ArgumentError, "missing expected: the staged sha the comment is about" }
      raise ArgumentError, "#{branch.name} has nothing staged to comment on" unless branch.staged
      raise GitError, "#{branch.name} changed since you read it (read #{short(expected)}, now #{short(branch.staged)}). Read it again." unless expected == branch.staged
      text = params[:description].to_s.gsub("\r\n", "\n").strip
      raise ArgumentError, "the comment is empty" if text.empty?
      repo.add_comment!(branch.staged, Comment.new(author: reviewer, description: text, **comment_location(repo, branch)))
      hub.commented(repo)
      redirect "#{branch_url(repo, branch.name)}#comments"
    end

    # Editing and deleting a comment, by the commit it is on and its id
    # (Comment#id). Back to the page it was done from, given as back.
    post "/repos/:name/comments/:sha/:id/edit" do
      repo = Repo.find!(params[:name])
      text = params[:description].to_s.gsub("\r\n", "\n").strip
      raise ArgumentError, "the comment is empty" if text.empty?
      repo.edit_comment!(params[:sha], params[:id], text, author: reviewer)
      hub.commented(repo)
      redirect "#{back_within(repo)}#comments"
    end

    post "/repos/:name/comments/:sha/:id/delete" do
      repo = Repo.find!(params[:name])
      repo.delete_comment!(params[:sha], params[:id])
      hub.commented(repo)
      redirect "#{back_within(repo)}#comments"
    end
  end
end
