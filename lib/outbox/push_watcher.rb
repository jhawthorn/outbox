# frozen_string_literal: true

module Outbox
  # Notices pushes. Agents push over the git daemon, in another container,
  # so nothing in this process sees one arrive; what it leaves behind is the
  # mtime of the file each repo's post-receive hook touches (Repo#pushed_at).
  # This thread stats those once per interval and reports the names that
  # changed, and those of repositories that appeared or went away (an
  # approved configuration change, or `bin/outbox` in another process).
  class PushWatcher
    INTERVAL = 1

    def initialize(interval: INTERVAL, &changed)
      @interval = interval
      @changed = changed
      @seen = snapshot
      @stop = Thread::Queue.new
      @thread = Thread.new { run }
      @thread.name = "outbox-pushes"
      @thread.report_on_exception = true
    end

    def stop
      @stop.close
      @thread.join
    end

    private

    def run
      while @stop.pop(timeout: @interval).nil? && !@stop.closed?
        now = snapshot
        (now.keys | @seen.keys).each { |name| @changed.call(name) if now.fetch(name, :gone) != @seen.fetch(name, :gone) }
        @seen = now
      end
    end

    def snapshot
      Repo.all.to_h { |repo| [repo.name, repo.pushed_at] }
    end
  end
end
