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

    # Boot: make sure the configuration repos exist, bring repos/ in line
    # with the approved configuration, then fetch every repository once.
    # Cheap when nothing changed, and it completes any first fetch that a
    # restart interrupted.
    def start_all
      Config.ensure!
      created = reconcile.map(&:name)
      Repo.all.each { |repo| fetch(repo) unless created.include?(repo.name) }
    end

    # Apply the approved configuration: create staging repos for new
    # entries and start their first fetch. Runs at boot and after every
    # approval on the config repo.
    def reconcile
      created = Config.apply!
      created.each { |repo| fetch(repo) }
      created
    end

    def status(repo)
      @mutex.synchronize { @status[repo.name] || Status.new }
    end

    def fetch(repo) = enqueue(repo, [:fetch])

    # Fetch every repository that is not already working. A busy repo has a
    # fetch of its own in flight or queued behind something that will leave
    # it fetched anyway, so another would only lengthen its queue. Returns
    # the repos a fetch was queued for.
    def fetch_all
      Repo.all.reject { |repo| status(repo).busy? }.each { |repo| fetch(repo) }
    end
    def approve(repo, branch, force: false, expected: nil) = enqueue(repo, [:approve, branch, force, expected])
    def discard(repo, branch, expected: nil) = enqueue(repo, [:discard, branch, expected])

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
        actor = @actors[repo.name] ||= spawn_actor(repo.name)
        begin
          actor.send(message)
        rescue Ractor::ClosedError
          # The actor died. Replace it and retry once.
          actor = @actors[repo.name] = spawn_actor(repo.name)
          actor.send(message)
        end
        s = @status[repo.name] || Status.new
        @status[repo.name] = s.with(queued: s.queued + 1)
      end
    end

    def spawn_actor(name) = RepoActor.spawn(name, Repo.root, Repo.upstream_token, @events)

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
        apply_config if name == Config::NAME && kind == :finished && rest[0] == :approve && rest[2]
      end
    end

    # An approved change to the configuration takes effect here, on the
    # event thread. A failure is shown on the config repo's page, as a
    # failed job would be, since the fix is another change to the config.
    def apply_config
      reconcile
    rescue StandardError => e
      @mutex.synchronize do
        s = @status[Config::NAME] || Status.new
        @status[Config::NAME] = s.with(last: Result.new(job: :apply, branch: nil, ok: false, message: e.message, finished_at: Time.now))
      end
    end
  end
end
