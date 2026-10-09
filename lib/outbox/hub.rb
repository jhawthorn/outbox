# frozen_string_literal: true

module Outbox
  # Lives in the main Ractor. Owns one RepoActor per repository, sends them
  # jobs, and keeps a per-repo Status built from the events they emit. The
  # web layer only ever talks to this.
  class Hub
    class Result
      attr_reader :job, :branch, :ok, :message, :finished_at

      def initialize(job:, branch:, ok:, message:, finished_at:)
        @job = job
        @branch = branch
        @ok = ok
        @message = message
        @finished_at = finished_at
      end

      def ok? = ok
    end

    # Immutable snapshot of what a repo's actor is doing. Replaced wholesale
    # by the event thread, so readers always see a consistent picture.
    class Status
      attr_reader :job, :branch, :progress, :started_at, :queued, :last

      def initialize(job: nil, branch: nil, progress: nil, started_at: nil, queued: 0, last: nil)
        @job = job
        @branch = branch
        @progress = progress
        @started_at = started_at
        @queued = queued
        @last = last
      end

      def running? = !job.nil?
      def busy?    = queued > 0
      def elapsed  = started_at ? (Time.now - started_at).round : 0

      def with(**changes)
        Status.new(job:, branch:, progress:, started_at:, queued:, last:, **changes)
      end
    end

    def initialize
      @events = Ractor::Port.new
      @actors = {}
      @status = {}
      @mutex = Mutex.new
      @drain = Thread.new { drain }
      @drain.name = "outbox-events"
      @drain.report_on_exception = true
    end

    # One fetch per repository at boot: cheap when nothing changed, and it
    # completes any first fetch that a restart interrupted.
    def start_all
      Repo.all.each { |repo| fetch(repo) }
    end

    def status(repo)
      @mutex.synchronize { @status[repo.name] || Status.new }
    end

    def fetch(repo) = enqueue(repo, [:fetch])
    def approve(repo, branch, force: false, expected: nil) = enqueue(repo, [:approve, branch, force, expected])
    def discard(repo, branch, expected: nil) = enqueue(repo, [:discard, branch, expected])

    def remove(repo)
      actor = @mutex.synchronize { @actors.delete(repo.name) }
      if actor
        begin
          actor.send([:stop])
          actor.join
        rescue Ractor::ClosedError, Ractor::RemoteError
          # Already dead; nothing to wait for.
        end
      end
      repo.destroy!
      @mutex.synchronize { @status.delete(repo.name) }
    end

    # Stop every actor and the event thread. Jobs still queued are dropped.
    def shutdown
      actors = @mutex.synchronize { @actors.values.tap { @actors.clear } }
      actors.each do |actor|
        actor.send([:stop])
        actor.join
      rescue Ractor::ClosedError, Ractor::RemoteError
        # Already gone.
      end
      @drain.kill
      @drain.join
    end

    private

    def enqueue(repo, message)
      @mutex.synchronize do
        actor = @actors[repo.name] ||= RepoActor.spawn(repo.name, Repo.root, @events)
        begin
          actor.send(message)
        rescue Ractor::ClosedError
          # The actor died. Replace it and retry once.
          actor = @actors[repo.name] = RepoActor.spawn(repo.name, Repo.root, @events)
          actor.send(message)
        end
        s = @status[repo.name] || Status.new
        @status[repo.name] = s.with(queued: s.queued + 1)
      end
    end

    def drain
      loop do
        name, kind, *rest = @events.receive
        @mutex.synchronize do
          s = @status[name] || Status.new
          @status[name] =
            case kind
            when :started
              s.with(job: rest[0], branch: rest[1], progress: nil, started_at: Time.now)
            when :progress
              s.with(progress: rest[0])
            when :finished
              job, branch, ok, message = rest
              s.with(job: nil, branch: nil, progress: nil, started_at: nil,
                     queued: [s.queued - 1, 0].max,
                     last: Result.new(job:, branch:, ok:, message:, finished_at: Time.now))
            else
              s
            end
        end
      end
    end
  end
end
