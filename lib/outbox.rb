# frozen_string_literal: true

require_relative "outbox/git"
require_relative "outbox/diff"
require_relative "outbox/repo"
require_relative "outbox/config"
require_relative "outbox/repo_actor"
require_relative "outbox/notifier"
require_relative "outbox/push_watcher"
require_relative "outbox/hub"
require_relative "outbox/git_http"
require_relative "outbox/auth"
require_relative "outbox/app"

module Outbox
  class << self
    attr_accessor :hub
  end
end
