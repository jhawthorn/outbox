# frozen_string_literal: true

require_relative "test_helper"

class PushWatcherTest < OutboxTest::RepoCase
  def setup
    super
    @changed = Thread::Queue.new
    @watcher = Outbox::PushWatcher.new(interval: 0.05) { |name| @changed << name }
  end

  def teardown
    @watcher.stop
    super
  end

  def next_change = @changed.pop(timeout: 5)

  def test_nothing_is_reported_while_nothing_changes
    assert_nil @changed.pop(timeout: 0.3)
  end

  def test_a_push_is_reported_once
    stage_commit
    assert_equal "demo", next_change
    assert_nil @changed.pop(timeout: 0.3)
  end

  def test_each_push_is_reported
    stage_commit
    assert_equal "demo", next_change
    stage_commit("other.txt", "other\n", "Another", branch: "main:feature/thing")
    assert_equal "demo", next_change
  end

  def test_a_deleted_branch_is_reported
    stage_commit(branch: "main:feature/thing")
    assert_equal "demo", next_change
    git("push", "--quiet", "origin", "--delete", "feature/thing", chdir: @stage)
    assert_equal "demo", next_change
  end

  def test_a_new_repository_is_reported
    other, = make_upstream("other")
    Outbox::Repo.create("other", other)
    assert_equal "other", next_change
  end

  def test_a_removed_repository_is_reported
    @repo.destroy!
    assert_equal "demo", next_change
  end

  # Only the hook's mark counts. The Hub reports its own jobs.
  def test_a_fetch_is_not_a_push
    upstream_commit
    @repo.fetch!
    assert_nil @changed.pop(timeout: 0.3)
  end
end
