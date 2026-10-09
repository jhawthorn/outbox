module Outbox
  # A background fetch of a repository's upstream. One per repository at a
  # time; the most recent one is kept so the UI can show progress or the
  # error from the last attempt.
  class Sync
    REGISTRY = {}
    REGISTRY_MUTEX = Mutex.new

    attr_reader :repo, :state, :progress, :error, :started_at, :finished_at

    # Start a sync for the repo, or return the one already running.
    def self.start(repo)
      REGISTRY_MUTEX.synchronize do
        current = REGISTRY[repo.name]
        return current if current&.running?
        REGISTRY[repo.name] = new(repo).tap(&:start)
      end
    end

    def self.for(repo)
      REGISTRY_MUTEX.synchronize { REGISTRY[repo.name] }
    end

    def self.forget(repo)
      REGISTRY_MUTEX.synchronize { REGISTRY.delete(repo.name) }
    end

    # Called once at boot. Fetching is cheap when nothing changed, and it
    # completes any first fetch that a restart interrupted.
    def self.start_all
      Repo.all.each { |repo| start(repo) }
    end

    def initialize(repo)
      @repo = repo
      @state = :queued
      @progress = "starting"
      @error = nil
      @started_at = Time.now
      @finished_at = nil
    end

    def running? = %i[queued running].include?(state)
    def failed?  = state == :failed
    def done?    = state == :done

    def elapsed
      ((finished_at || Time.now) - started_at).round
    end

    def start
      @thread = Thread.new { run }
      @thread.name = "sync:#{repo.name}"
      @thread.report_on_exception = false
    end

    private

    def run
      @state = :running
      repo.fetch! { |line| @progress = line }
      repo.set_default_head! unless repo.head_valid?
      @progress = "done"
      @state = :done
    rescue StandardError => e
      @error = e.message
      @state = :failed
    ensure
      @finished_at = Time.now
    end
  end
end
