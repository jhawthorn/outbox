require_relative "lib/outbox"

# One fetch per repository at boot: cheap when nothing changed, and it
# completes any first fetch that a restart interrupted.
Outbox::Sync.start_all

use Rack::CommonLogger
use Outbox::GitHttp, Outbox::Repo.repos_dir
run Outbox::App
