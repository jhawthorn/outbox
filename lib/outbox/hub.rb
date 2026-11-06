# frozen_string_literal: true

module Outbox
  # Lives in the main Ractor. Owns one RepoActor per repository, sends them
  # jobs, and keeps a per-repo Status built from the events they emit. The
  # web layer only ever talks to this. Every change it makes or sees, its
  # own jobs and pushes the PushWatcher notices, goes out to open pages
  # through the Notifier. It also fetches without being asked: after every
  # push, and every repository FETCH_EVERY after its last fetch.
  class Hub
    FETCH_EVERY = 30 * 60
    # How often the timer looks for repositories due a fetch.
    FETCH_CHECK = 60

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
    # fetches_queued counts the fetches sent and not yet started, and
    # fetched_at is when the last fetch finished, whether or not it worked.
    class Status
      attr_reader :job, :branch, :progress, :started_at, :queued, :last, :fetches_queued, :fetched_at

      def initialize(job: nil, branch: nil, progress: nil, started_at: nil, queued: 0, last: nil, fetches_queued: 0, fetched_at: nil)
        @job = job
        @branch = branch
        @progress = progress
        @started_at = started_at
        @queued = queued
        @last = last
        @fetches_queued = fetches_queued
        @fetched_at = fetched_at
      end

      def running? = !job.nil?
      def busy?    = queued > 0
      def elapsed  = started_at ? (Time.now - started_at).round : 0

      def with(**changes)
        Status.new(job:, branch:, progress:, started_at:, queued:, last:, fetches_queued:, fetched_at:, **changes)
      end
    end

    # push_check: how often the PushWatcher looks. fetch_every and
    # fetch_check: as FETCH_EVERY and FETCH_CHECK.
    def initialize(push_check: PushWatcher::INTERVAL, fetch_every: FETCH_EVERY, fetch_check: FETCH_CHECK)
      @events = Ractor::Port.new
      @actors = {}
      @status = {}
      @mutex = Mutex.new
      @started_at = Time.now
      @fetch_every = fetch_every
      @drain = Thread.new { drain }
      @drain.name = "outbox-events"
      @drain.report_on_exception = true
      @notifier = Notifier.new
      @timer_stop = Thread::Queue.new
      @timer = Thread.new { run_timer(fetch_check) }
      @timer.name = "outbox-fetch-timer"
      @timer.report_on_exception = true
      @watcher = PushWatcher.new(interval: push_check) { |name, pushed| noticed(name, pushed) }
    end

    # Boot: make sure the configuration repos exist, bring repos/ in line
    # with the approved configuration, then fetch every repository once.
    # Cheap when nothing changed, and it completes any first fetch that a
    # restart interrupted.
    def start_all
      Config.ensure!
      fetched = reconcile.map(&:name)
      Repo.all.each { |repo| fetch(repo) unless fetched.include?(repo.name) }
    end

    # Apply the approved configuration: create staging repos for new
    # entries, bring the remotes of the others in line, and fetch every repo
    # that gained a remote, or is new. Runs at boot and after every approval
    # on the config repo. Returns the repos it fetched.
    def reconcile
      changed = Config.apply!
      changed.each { |repo| fetch(repo) }
      changed
    end

    def status(repo)
      @mutex.synchronize { @status[repo.name] || Status.new }
    end

    # Hand over a client's socket, headers already sent, to be told of every
    # change as server-sent events.
    def subscribe(io) = @notifier.subscribe(io)

    # How many changes have gone out to pages. A page rendered now reflects
    # this many (or more).
    def seq = @notifier.seq

    def fetch(repo) = enqueue(repo, [:fetch])

    # Fetch every repository that is not already working. A busy repo has a
    # fetch of its own in flight or queued behind something that will leave
    # it fetched anyway, so another would only lengthen its queue. Returns
    # the repos a fetch was queued for.
    def fetch_all
      Repo.all.reject { |repo| status(repo).busy? }.each { |repo| fetch(repo) }
    end

    # Fetch every repository whose last fetch finished at least FETCH_EVERY
    # ago, unless it has a fetch queued or running. One this hub has not
    # fetched counts from when the hub started, which boot fetches anyway.
    # The timer calls this every FETCH_CHECK. Returns the repos a fetch was
    # queued for.
    def fetch_stale(now = Time.now)
      Repo.all.select do |repo|
        enqueue(repo, [:fetch]) do |s|
          s.fetches_queued > 0 || s.job == :fetch || now - (s.fetched_at || @started_at) < @fetch_every
        end
      end
    end

    # Clear a failed result so its notice stops showing. A success is left
    # alone: it is only the quiet "last did X" line.
    def dismiss(repo)
      @mutex.synchronize do
        s = @status[repo.name]
        @status[repo.name] = s.with(last: nil) if s&.last && !s.last.ok?
      end
      @notifier.publish(repo.name, :status)
    end

    # A review comment was written (App's POST .../comments), for the pages
    # showing that repository to say so. A verdict comment needs no call:
    # it is written by a job, and a finished job is announced as refs.
    def commented(repo) = @notifier.publish(repo.name, :comments)

    # reviewer: who to name on the review comment the job leaves (RepoActor.verdict);
    # none without one.
    def approve(repo, branch, force: false, expected: nil, expected_upstream: nil, reviewer: nil) =
      enqueue(repo, [:approve, branch, force, expected, expected_upstream, reviewer])
    def discard(repo, branch, expected: nil, expected_upstream: nil, reviewer: nil) =
      enqueue(repo, [:discard, branch, expected, expected_upstream, reviewer])

    # Stop every actor, the event thread, the timer, the watcher and the
    # notifier. Jobs still queued are dropped.
    def shutdown
      @timer_stop.close
      @timer.join
      @watcher.stop
      actors = @mutex.synchronize { @actors.values.tap { @actors.clear } }
      actors.each do |actor|
        actor.send([:stop])
        actor.join
      rescue Ractor::ClosedError, Ractor::RemoteError
        # Already gone.
      end
      @drain.kill
      @drain.join
      @notifier.stop
    end

    private

    # Send a job to the repo's actor. Given a block, the job is only sent
    # if the block, handed the repo's Status, returns false; deciding and
    # sending are one step, so two threads asking at once send one job.
    # Returns whether it was sent.
    def enqueue(repo, message)
      @mutex.synchronize do
        s = @status[repo.name] || Status.new
        return false if block_given? && yield(s)

        actor = @actors[repo.name] ||= spawn_actor(repo.name)
        begin
          actor.send(message)
        rescue Ractor::ClosedError
          # The actor died, and every job queued on it went with it, so
          # nothing is running or queued any more. Replace it and retry once.
          actor = @actors[repo.name] = spawn_actor(repo.name)
          actor.send(message)
          s = s.with(job: nil, branch: nil, progress: nil, started_at: nil, queued: 0, fetches_queued: 0)
        end
        fetches = message[0] == :fetch ? 1 : 0
        @status[repo.name] = s.with(queued: s.queued + 1, fetches_queued: s.fetches_queued + fetches)
      end
      @notifier.publish(repo.name, :status)
      true
    end

    # The PushWatcher saw a repo change: pages are told whatever it was.
    # A push is also fetched after, so what it brought is shown against
    # upstream as it is now, not as of the last fetch: an agent may well
    # have built on something newer. A fetch that is queued and not yet
    # started will do, as it starts after the push too.
    def noticed(name, pushed)
      @notifier.publish(name, :refs)
      return unless pushed && (repo = Repo.find(name))
      enqueue(repo, [:fetch]) { |s| s.fetches_queued > 0 }
    rescue StandardError => e
      # Never the watcher's end: pages would stop hearing of pushes.
      warn "outbox: could not fetch #{name} after a push: #{e.message}"
    end

    def run_timer(check)
      while @timer_stop.pop(timeout: check).nil? && !@timer_stop.closed?
        begin
          fetch_stale
        rescue StandardError => e
          warn "outbox: timed fetch: #{e.message}"
        end
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
              fetches_queued = rest[0] == :fetch ? [s.fetches_queued - 1, 0].max : s.fetches_queued
              s.with(job: rest[0], branch: rest[1], progress: nil, started_at: Time.now, fetches_queued:)
            when :progress
              s.with(progress: rest[0])
            when :finished
              job, branch, ok, message = rest
              now = Time.now
              # A fetch that worked clears a failed fetch, but leaves another
              # job's failure showing until it is dismissed. Fetching does
              # not undo a failed approval, and most fetches are now ones
              # nobody asked for (after a push, on the timer).
              kept = job == :fetch && ok && s.last && !s.last.ok? && s.last.job != :fetch
              s.with(job: nil, branch: nil, progress: nil, started_at: nil,
                     queued: [s.queued - 1, 0].max,
                     last: kept ? s.last : Result.new(job:, branch:, ok:, message:, finished_at: now),
                     fetched_at: job == :fetch ? now : s.fetched_at)
            else
              s
            end
        end
        # A job that finished may have moved refs; anything else is progress.
        @notifier.publish(name, kind == :finished ? :refs : :status)
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
      @notifier.publish(Config::NAME, :status)
    end
  end
end
