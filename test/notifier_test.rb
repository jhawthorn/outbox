# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class NotifierTest < Minitest::Test
  def setup
    @notifier = Outbox::Notifier.new(keepalive: 0.2)
    @sockets = []
  end

  def teardown
    @notifier.stop
    @sockets.flatten.each { |s| s.close unless s.closed? }
  end

  # Subscribe a socket; returns the end a browser would read, and the
  # notifier's end.
  def subscribe
    server, client = UNIXSocket.pair
    @sockets << [server, client]
    @notifier.subscribe(server)
    client
  end

  # What the client has received, read until the block says it is enough,
  # the stream ends, or the timeout passes.
  def read(client, timeout: 2)
    buffer = +""
    deadline = Time.now + timeout
    loop do
      return buffer if block_given? && yield(buffer)
      left = deadline - Time.now
      return buffer if left <= 0 || !IO.select([client], nil, nil, left)
      chunk = client.read_nonblock(4096, exception: false)
      return buffer if chunk.nil?
      buffer << chunk unless chunk == :wait_readable
    end
  end

  def hello(client) = read(client) { |b| b.include?("event: hello\n") && b.end_with?("\n\n") }

  def test_a_stream_opens_with_the_seq
    client = subscribe
    assert_equal "retry: #{Outbox::Notifier::RETRY}\nevent: hello\ndata: 0\n\n", hello(client)
    assert_equal 1, @notifier.subscribers
  end

  def test_each_message_names_the_repository_with_the_next_id
    client = subscribe
    hello(client)
    @notifier.publish("demo", :status)
    assert_equal "id: 1\nevent: status\ndata: demo\n\n", read(client) { |b| b.end_with?("\n\n") }
    @notifier.publish("demo", :refs)
    assert_equal "id: 2\nevent: refs\ndata: demo\n\n", read(client) { |b| b.end_with?("\n\n") }
    assert_equal 2, @notifier.seq
  end

  def test_a_later_stream_opens_with_the_seq_so_far
    @notifier.publish("demo", :refs)
    client = subscribe
    assert_includes hello(client), "data: 1\n\n"
  end

  def test_publish_reaches_every_subscriber
    clients = [subscribe, subscribe]
    @notifier.publish("demo", :refs)
    clients.each do |client|
      assert_includes read(client) { |b| b.include?("data: demo\n\n") }, "event: refs\ndata: demo\n\n"
    end
  end

  def test_an_unknown_kind_is_refused
    assert_raises(ArgumentError) { @notifier.publish("demo", :other) }
  end

  def test_a_burst_collapses_to_one_message_per_repository_and_kind
    client = subscribe
    hello(client)
    # Queued faster than the writer sends: whatever is waiting when it
    # wakes goes out once.
    50.times { @notifier.publish("demo", :status) }
    @notifier.publish("demo", :refs)
    3.times { @notifier.publish("other", :status) }
    out = read(client) { |b| b.include?("data: other\n\n") }
    out << read(client, timeout: 0.1)
    assert_operator out.scan("event: status\ndata: demo\n\n").size, :<, 50
    assert_equal 1, out.scan("event: refs\ndata: demo\n\n").size
    assert_equal 1, out.scan("event: status\ndata: other\n\n").size
  end

  def test_a_quiet_stream_gets_keepalives
    client = subscribe
    assert_includes read(client) { |b| b.include?(": keepalive\n\n") }, ": keepalive\n\n"
  end

  def test_a_closed_client_is_dropped
    gone = subscribe
    hello(gone)
    other = subscribe
    hello(other)
    gone.close
    @notifier.publish("demo", :refs)
    # Written to in order, so once the second has it the first has failed.
    read(other) { |b| b.include?("data: demo\n\n") }
    assert_equal 1, @notifier.subscribers
  end

  def test_a_client_that_does_not_read_is_dropped_rather_than_waited_on
    stuck = subscribe
    hello(stuck)
    # Fill the socket from the notifier's end, as a client that stopped
    # reading would leave it.
    server = @sockets.last.first
    [65_536, 1].each { |size| nil until server.write_nonblock("x" * size, exception: false) == :wait_writable }
    other = subscribe
    hello(other)
    @notifier.publish("demo", :refs)
    assert_includes read(other) { |b| b.include?("data: demo\n\n") }, "data: demo\n\n"
    assert_equal 1, @notifier.subscribers
    assert server.closed?
  end

  def test_stop_closes_every_stream
    client = subscribe
    hello(client)
    @notifier.stop
    assert_equal "", read(client, timeout: 0.5)
    assert client.eof?
  end

  def test_a_socket_handed_over_after_stop_is_closed
    @notifier.stop
    client = subscribe
    assert client.eof?
  end
end
