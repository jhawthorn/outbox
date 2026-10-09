# frozen_string_literal: true

require "sinatra/base"

module Outbox
  class App < Sinatra::Base
    set :views, File.expand_path("../../views", __dir__)
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

      def pluralize(n, word) = "#{n} #{word}#{n == 1 ? "" : "s"}"

      # Deep link to the deploy keys page when the upstream is on GitHub.
      def github_keys_url(upstream)
        m = upstream.match(%r{github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?\z})
        m && "https://github.com/#{m[1]}/#{m[2]}/settings/keys"
      end

      def duration(seconds)
        seconds < 60 ? "#{seconds}s" : "#{seconds / 60}m #{seconds % 60}s"
      end

      def diff_html(diff)
        diff.each_line.map do |line|
          cls = case line
                when /\A(diff --git|index |--- |\+\+\+ |new file|deleted file|similarity|rename |old mode|new mode|Binary)/ then "meta"
                when /\A@@/ then "hunk"
                when /\A\+/ then "add"
                when /\A-/  then "del"
                else "ctx"
                end
          %(<span class="#{cls}">#{h(line.chomp)}</span>\n)
        end.join
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
      @repos = Repo.all.map { |r| [r, r.branches, hub.status(r)] }
      @refresh = @repos.any? { |_, _, status| status.busy? }
      erb :index
    end

    post "/repos" do
      repo = Repo.create(params[:name].to_s.strip, params[:upstream].to_s.strip)
      hub.fetch(repo)
      redirect repo_url(repo)
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

    post "/repos/:name/destroy" do
      repo = Repo.find!(params[:name])
      raise GitError, "#{repo.name} is busy; wait for it to finish" if hub.status(repo).busy?
      hub.remove(repo)
      redirect "/"
    end

    get "/repos/:name/branches/*" do
      @repo = Repo.find!(params[:name])
      @branch = @repo.branch(params[:splat].first)
      @commits = @repo.commits(@branch.name)
      @outgoing = @repo.outgoing_commits(@branch.name)
      @stat, @diff = @repo.diff(@branch.name)
      erb :branch
    end

    # Approve and discard are queued on the repo's actor. The outcome shows
    # up on the repo page as the last result.
    post "/repos/:name/branches/*/approve" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      hub.approve(repo, branch.name, force: params[:force] == "1")
      redirect repo_url(repo)
    end

    post "/repos/:name/branches/*/discard" do
      repo = Repo.find!(params[:name])
      branch = repo.branch(params[:splat].first)
      hub.discard(repo, branch.name)
      redirect repo_url(repo)
    end
  end
end
