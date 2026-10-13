# frozen_string_literal: true

require "sinatra/base"

module Outbox
  class App < Sinatra::Base
    set :views, File.expand_path("../../views", __dir__)
    # Holds the diff viewer bundle, built by `rake assets`. Not committed;
    # pages say so when it is missing.
    PUBLIC_DIR = File.expand_path("../../public", __dir__)
    DIFFS_BUNDLE = File.join(PUBLIC_DIR, "diffs/diffs.js")
    set :public_folder, PUBLIC_DIR
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

      def status_label(status) = STATUS_LABELS.fetch(status, status.to_s)

      def short(sha) = sha ? sha[0, 10] : "—"

      def summary(branch)
        case branch.status
        when :synced   then "nothing staged"
        when :ready    then "#{pluralize(branch.ahead, "commit")} to push"
        when :new      then "#{pluralize(branch.ahead, "new commit")}, branch does not exist upstream"
        when :deleted  then "branch will be deleted upstream (#{pluralize(branch.behind, "commit")} only reachable from it)"
        when :diverged then "#{pluralize(branch.ahead, "commit")} to push; upstream has #{pluralize(branch.behind, "commit")} not in staged"
        end
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

      def duration(seconds)
        seconds < 60 ? "#{seconds}s" : "#{seconds / 60}m #{seconds % 60}s"
      end

      # "N", or "latest N of M" when the list was cut off at its limit.
      def commit_total(shown, total) = shown < total ? "latest #{shown} of #{total}" : total.to_s

      def commit_url(repo, branch, commit) = "#{branch_url(repo, branch)}/commits/#{commit.sha}"

      def identity_line(c)
        author = "#{hv c.author} &lt;#{hv c.author_email}&gt;"
        if c.committer_differs?
          "#{author} authored #{h c.date} · #{hv c.committer} &lt;#{hv c.committer_email}&gt; committed #{h c.commit_date}"
        else
          "#{author} committed #{h c.date}"
        end
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

      def send_patch(patch)
        content_type "text/plain", charset: "utf-8"
        patch.text
      end
    end

    error NotFound do
      status 404
      @message = env["sinatra.error"].message
      erb :error
    end

    error GitError, ArgumentError do
      status 422
      @message = env["sinatra.error"].message
      erb :error
    end

    error do
      status 500
      @message = env["sinatra.error"].message
      erb :error
    end

    get "/" do
      @repos = Repo.all.map { |r| [r, r.branches, hub.status(r), r.last_push_at] }
      # Repos with something to review first, then the rest; within each, the
      # most recently pushed first, and never-pushed ones by name.
      @repos = @repos.sort_by { |r, branches, _, pushed| [branches.any?(&:pending?) ? 0 : 1, pushed ? -pushed.to_i : 0, r.name] }
      @problems = Config.load.problems
      # Fetches of https upstreams fail without the token; say so up front
      # rather than once per repo.
      @needs_token = Repo.upstream_token.nil? && @repos.any? { |r, _, _, _| !r.config? && r.remote_upstream? }
      @refresh = @repos.any? { |_, _, status, _| status.busy? }
      erb :index
    end

    post "/fetch" do
      hub.fetch_all
      redirect "/"
    end

    get "/repos/:name" do
      @repo = Repo.find!(params[:name])
      @status = hub.status(@repo)
      @branches = @repo.branches
      @refresh = @status.busy?
      erb :repo
    end

    post "/repos/:name/fetch" do
      repo = Repo.find!(params[:name])
      hub.fetch(repo)
      redirect(params[:back] || repo_url(repo))
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
      @repo = Repo.find!(params[:name])
      @branch = @repo.branch(params[:splat].first)
      @commits = @repo.commits(@branch)
      @outgoing = @repo.outgoing_commits(@branch)
      @commit_count = @repo.commit_count(@branch)
      @outgoing_count = @repo.outgoing_commit_count(@branch)
      @patch = @repo.diff(@branch)
      erb :branch
    end

    # Approve and discard are queued on the repo's actor. The outcome shows
    # up on the repo page as the last result. Both carry the sha the
    # reviewer saw, so a push that lands in between is refused, not approved.
    post "/repos/:name/branches/*/approve" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      hub.approve(repo, branch.name, force: params[:force] == "1", expected: params[:expected])
      redirect repo_url(repo)
    end

    post "/repos/:name/branches/*/discard" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      hub.discard(repo, branch.name, expected: params[:expected])
      redirect repo_url(repo)
    end
  end
end
