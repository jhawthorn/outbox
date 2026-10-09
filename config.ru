# frozen_string_literal: true

require_relative "lib/outbox"

Outbox.hub = Outbox::Hub.new
Outbox.hub.start_all

use Rack::CommonLogger
use Outbox::GitHttp, Outbox::Repo.repos_dir
run Outbox::App
