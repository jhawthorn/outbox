# frozen_string_literal: true

module Outbox
  # The body of the Ractor that owns one repository. It is the only place
  # that mutates the repo. It receives jobs on its default port and reports
  # what happens on the shared events port the Hub created.
  #
  # Jobs:    [:fetch]  [:approve, branch, force]  [:discard, branch]  [:stop]
  # Events:  [name, :started, job, branch]
  #          [name, :progress, line]
  #          [name, :finished, job, branch, ok, message]
  module RepoActor
    def self.spawn(name, root, events)
      Ractor.new(name, root, events) { |n, r, e| Outbox::RepoActor.run(n, r, e) }
    end

    def self.run(name, root, events)
      repo = Repo.new(name, root: root)
      loop do
        job, *args = Ractor.receive
        break if job == :stop

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
        repo.set_default_head! unless repo.head_valid?
        "fetched upstream"
      when :approve
        branch, force = args
        repo.approve!(branch, force: force)
        "pushed #{branch} to upstream"
      when :discard
        repo.discard!(args[0])
        "discarded staged changes on #{args[0]}"
      else
        raise ArgumentError, "unknown job #{job.inspect}"
      end
    end
  end
end
