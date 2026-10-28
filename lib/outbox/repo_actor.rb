# frozen_string_literal: true

module Outbox
  # The body of the Ractor that owns one repository. It is the only place
  # that mutates the repo. It receives jobs on its default port and reports
  # what happens on the shared events port the Hub created.
  #
  # Jobs:    [:fetch]  [:approve, branch, force, expected, expected_upstream, reviewer]
  #          [:discard, branch, expected, expected_upstream, reviewer]  [:stop]
  # Events:  [name, :started, job, branch]
  #          [name, :progress, line]
  #          [name, :finished, job, branch, ok, message]
  module RepoActor
    # root and token come from the main Ractor rather than being read from
    # ENV in here.
    def self.spawn(name, root, token, events)
      Ractor.new(name, root, token, events) { |n, r, t, e| Outbox::RepoActor.run(n, r, t, e) }
    end

    def self.run(name, root, token, events)
      loop do
        job, *args = Ractor.receive
        break if job == :stop

        # A Repo per job: it keeps the repo's remotes as it first reads
        # them, and an approved configuration change can alter them between
        # jobs.
        repo = Repo.new(name, root: root, upstream_token: token)
        branch = args[0]
        events << [name, :started, job, branch]
        begin
          message = perform(repo, job, args) { |line| events << [name, :progress, line] }
          events << [name, :finished, job, branch, true, message]
        rescue StandardError => e
          events << [name, :finished, job, branch, false, e.message]
        end
      end
    end

    def self.perform(repo, job, args, &progress)
      case job
      when :fetch
        repo.fetch!(&progress)
        "fetched upstream"
      when :approve
        branch, force, expected, expected_upstream, reviewer = args
        b = repo.approve!(branch, force: force, expected: expected, expected_upstream: expected_upstream)
        "pushed #{branch} to upstream#{verdict(repo, b, reviewer, true)}"
      when :discard
        branch, expected, expected_upstream, reviewer = args
        b = repo.discard!(branch, expected: expected, expected_upstream: expected_upstream)
        "discarded staged changes on #{branch}#{verdict(repo, b, reviewer, false)}"
      else
        raise ArgumentError, "unknown job #{job.inspect}"
      end
    end

    # The review comment an approval or a discard leaves on what was
    # reviewed, so whoever pushed it can read the outcome from git: resolved
    # true or false, as git-appraise records an accepted or rejected change.
    # The job has already happened by now, so failing to record it is said
    # in the message rather than failing the job.
    def self.verdict(repo, b, reviewer, approved)
      sha = b.staged || b.upstream
      return "" if reviewer.nil? || sha.nil?
      text =
        if !approved then "Discarded."
        elsif b.staged then "Approved and pushed to upstream."
        else "Approved deleting #{b.name} from upstream."
        end
      repo.add_comment!(sha, Comment.new(author: reviewer, description: text, commit: sha, resolved: approved))
      ""
    rescue StandardError => e
      " (could not record it as a review comment: #{e.message})"
    end
  end
end
