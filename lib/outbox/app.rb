# frozen_string_literal: true

require "sinatra/base"
require "json"
require "time"

module Outbox
  class App < Sinatra::Base
    set :views, File.expand_path("../../views", __dir__)
    # Holds the diff viewer bundle, built by `rake assets`. Not committed;
    # pages say so when it is missing.
    PUBLIC_DIR = File.expand_path("../../public", __dir__)
    DIFFS_BUNDLE = File.join(PUBLIC_DIR, "diffs/diffs.js")
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

      def branch_url(repo, branch) = "#{repo_url(repo)}/branches/#{branch}"

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
            "#{pluralize(branch.ahead, "commit")} to push, rebased onto #{pluralize(branch.picked_up, "newer upstream commit")}"
          else
            "#{pluralize(branch.ahead, "commit")} to push; upstream has #{pluralize(branch.behind, "commit")} not in staged"
          end
        end
      end

      # What becomes of the commits upstream has on a diverged branch, from
      # the pairing (Repo::Rewrite): "2 carried over unchanged, 1 changed,
      # 1 dropped", leaving out the kinds there are none of.
      def rewrite_label(rewrite, dropped)
        parts = []
        parts << "#{rewrite.unchanged.size} carried over unchanged" unless rewrite.unchanged.empty?
        parts << "#{rewrite.changed.size} changed" unless rewrite.changed.empty?
        parts << "#{dropped} dropped" if dropped.positive?
        parts.join(", ")
      end

      # The question the force approve button asks, with what the force
      # drops; when a rebase carries every upstream commit over, that it
      # drops nothing. Goes inside a single-quoted script string, so no
      # apostrophes.
      def force_confirm(branch, dropped)
        what =
          if dropped.positive? then "#{pluralize(dropped, "upstream commit")} will be dropped."
          elsif branch.behind == 1 then "The one upstream commit is carried over."
          else "All #{branch.behind} upstream commits are carried over."
          end
        "Force-push #{branch.name} to upstream? #{what}"
      end

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

      def committed_label(time)
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
          "#{author} authored #{h c.date} · #{hv c.committer} &lt;#{hv c.committer_email}&gt; committed #{h c.commit_date}"
        else
          "#{author} committed #{h c.date}"
        end
      end

      # A timestamp from git's %aI/%cI as "2026-10-15 14:28 UTC−7": the
      # clock time of whoever recorded it, with their offset, dimmed. The full
      # timestamp is the tooltip.
      def when_label(iso)
        t = Time.iso8601(iso)
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
      def render_patch(patch, patch_url)
        erb :_patch, layout: false, locals: { patch: patch, patch_url: patch_url }
      end

      def diffs_built? = File.exist?(DIFFS_BUNDLE)

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

      # The sha the reviewer saw, "" for a deleted branch. Required: a
      # request without it would approve whatever happens to be staged.
      def expected_sha!
        params[:expected] or raise ArgumentError, "missing expected: the staged sha that was reviewed"
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

    get "/repos/:name" do
      live!
      @repo = Repo.find!(params[:name])
      @status = hub.status(@repo)
      @branches = @repo.branches
      erb :repo
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

    # Raw patches, as the browser fetches them for the diff viewer and as
    # `git apply` wants them. Defined before the page routes: the splat and
    # :sha would otherwise swallow the ".patch".
    get "/repos/:name/branches/*/commits/:sha.patch" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      staged_commit!(repo, branch, params[:sha])
      send_patch(repo.commit_diff(params[:sha]))
    end

    get "/repos/:name/branches/*.patch" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      send_patch(repo.diff(branch))
    end

    # Must be defined before the branch route, whose splat would otherwise
    # swallow "/commits/<sha>".
    get "/repos/:name/branches/*/commits/:sha" do
      live!
      @repo = Repo.find!(params[:name])
      @branch = @repo.branch(params[:splat].first)
      list, index = staged_commit!(@repo, @branch, params[:sha])
      @commit = @repo.commit_detail(params[:sha])
      @patch = @repo.commit_diff(params[:sha])
      # list is newest first; present as oldest = 1 of N.
      @newer = index.positive? ? list[index - 1] : nil
      @older = list[index + 1]
      @position = list.size - index
      @total = list.size
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
      @patch = @repo.diff(@branch)
      @rebase = @repo.rebase(@branch)
      # Upstream commits that live on in a staged one are marked on that
      # one rather than listed as dropped. The pairing covers every commit
      # when there is one, so the list is then complete.
      @rewrite = @repo.rewrite(@branch)
      @dropped = @rewrite ? @outgoing.reject { |c| @rewrite.carried?(c.sha) } : @outgoing
      @dropped_count = @rewrite ? @dropped.size : @outgoing_count
      @tips = other_tips(@repo.branches, @branch)
      erb :branch
    end

    # Approve and discard are queued on the repo's actor. The outcome shows
    # up on the repo page as the last result. Both must carry the sha the
    # reviewer saw, so a push that lands in between is refused, not approved.
    post "/repos/:name/branches/*/approve" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      hub.approve(repo, branch.name, force: params[:force] == "1", expected: expected_sha!)
      redirect repo_url(repo)
    end

    post "/repos/:name/branches/*/discard" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      hub.discard(repo, branch.name, expected: expected_sha!)
      redirect repo_url(repo)
    end
  end
end
