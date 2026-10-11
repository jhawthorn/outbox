# frozen_string_literal: true

require_relative "lib/outbox"

password = ENV["OUTBOX_PASSWORD"].to_s
abort "OUTBOX_PASSWORD is not set. Refusing to start without one." if password.empty?

# OUTBOX_GIT_AUTH=none leaves /<name>.git/* open so agents can use this
# endpoint directly. Default requires the password for git too; agents then
# use the git daemon instead.
git_open = ENV["OUTBOX_GIT_AUTH"] == "none"

Outbox.hub = Outbox::Hub.new
Outbox.hub.start_all

use Rack::CommonLogger
use Outbox::Auth, password: password, git_open: git_open
use Outbox::GitHttp, Outbox::Repo.repos_dir
run Outbox::App
