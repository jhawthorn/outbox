# frozen_string_literal: true

module Outbox
  # The body of the Ractor that owns one repository. It is the only place
  # that mutates the repo. It receives jobs on its default port and reports
  # what happens on the shared events port the Hub created.
  #
  # Jobs:    [:fetch]  [:approve, branch, force, expected, expected_upstream]  [:discard, branch, expected, expected_upstream]  [:stop]
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
        branch, force, expected, expected_upstream = args
        repo.approve!(branch, force: force, expected: expected, expected_upstream: expected_upstream)
        "pushed #{branch} to upstream"
      when :discard
        branch, expected, expected_upstream = args
        repo.discard!(branch, expected: expected, expected_upstream: expected_upstream)
        "discarded staged changes on #{branch}"
      else
        raise ArgumentError, "unknown job #{job.inspect}"
      end
    end
  end
end
