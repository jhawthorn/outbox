# frozen_string_literal: true

module Outbox
  # The /events stream: server-sent events telling every open page that a
  # repository changed, so the page can fetch itself again. Each message
  # names the repository and says what kind of change it was:
  #
  #   status  a job was queued, started or reported progress, or a failure
  #           was dismissed. Nothing in git moved.
  #   refs    the repository's refs may have moved: a push landed, a job
  #           finished, the repository appeared or went away.
  #
  # Every message carries an id, counting up from the start of this process
  # (seq). Pages are rendered with the seq they reflect, and the stream
  # opens with a "hello" naming the current one, so a page that missed
  # something while it had no stream (loading, hidden, reconnecting) knows
  # to catch up.
  #
  # Connections are handed over once their headers are out (App's /events),
  # so a page left open holds no puma thread. One thread writes to all of
  # them. A client whose socket will not take a write is dropped rather
  # than waited on; its browser reconnects on its own.
  class Notifier
    KINDS = %i[status refs].freeze

    # Seconds of quiet before a comment is sent, so a dead connection is
    # found and nothing in between times the stream out.
    KEEPALIVE = 15

    # How long a browser waits before reconnecting, in milliseconds.
    RETRY = 2000

    attr_reader :seq

    def initialize(keepalive: KEEPALIVE)
      @keepalive = keepalive
      @seq = 0
      @queue = Thread::Queue.new
      @clients = []
      @writer = Thread.new { run }
      @writer.name = "outbox-notifier"
      @writer.report_on_exception = true
    end

    # Take over a socket whose response headers have been sent.
    def subscribe(io) = post([:subscribe, io])

    def publish(name, kind)
      raise ArgumentError, "unknown kind #{kind.inspect}" unless KINDS.include?(kind)
      post([kind, name])
    end

    # Open streams, as of the last thing the writer did.
    def subscribers = @clients.size

    # Send what is queued, close every stream and stop the writer.
    def stop
      @queue.close
      @writer.join
    end

    private

    def post(item)
      @queue << item
    rescue ClosedQueueError
      # Stopped. A job finishing during shutdown has nobody left to tell, and
      # a socket handed over now is closed by its server.
      item[1].close if item[0] == :subscribe
    end

    def run
      until (item = @queue.pop(timeout: @keepalive)).nil? && @queue.closed?
        if item.nil?
          broadcast(": keepalive\n\n")
          next
        end
        # Take everything already waiting, so a burst (git's progress lines,
        # several a second) goes out as one message per repository and kind.
        items = [item]
        items << @queue.pop until @queue.empty?
        items.uniq.each do |kind, arg|
          if kind == :subscribe
            hello(arg)
          else
            @seq += 1
            broadcast("id: #{@seq}\nevent: #{kind}\ndata: #{arg}\n\n")
          end
        end
      end
    ensure
      @clients.each { |io| close(io) }.clear
    end

    def hello(io)
      if write(io, "retry: #{RETRY}\nevent: hello\ndata: #{@seq}\n\n")
        @clients << io
      else
        close(io)
      end
    end

    def broadcast(data)
      @clients.reject! do |io|
        next false if write(io, data)
        close(io)
        true
      end
    end

    # Whether all of data went out. A socket whose buffer is full counts as
    # gone: this one thread serves every client. So does one whose write
    # raises, whatever it raises (an SSL socket's errors are not IOErrors):
    # a client is never worth the thread that serves all the others.
    def write(io, data)
      until data.empty?
        n = io.write_nonblock(data, exception: false)
        return false if n == :wait_writable
        data = data.byteslice(n..)
      end
      true
    rescue StandardError
      false
    end

    def close(io)
      io.close unless io.closed?
    rescue StandardError
      # already gone
    end
  end
end
