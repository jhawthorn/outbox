# outbox

A git remote that holds pushes for human review before forwarding them to the real remote.

Push to `http://localhost:8080/<name>.git` instead of the upstream. A web UI shows each
branch's commits and diff against upstream. A human approves (outbox pushes to upstream)
or discards (staged branch is reset). Nothing reaches upstream without approval.

## Layout

- `lib/outbox/repo.rb` — one bare repo per name under `$OUTBOX_DATA/repos/<name>.git`.
  `refs/heads/*` is what was pushed here; `refs/remotes/upstream/*` is the real remote.
  A branch is pending when they differ. States: ready, new, deleted, diverged, synced.
- `lib/outbox/git_http.rb` — Rack middleware serving smart HTTP via `git http-backend`.
- `lib/outbox/app.rb`, `views/` — Sinatra UI. Routes: `/`, `/repos/:name`,
  `/repos/:name/branches/*`, plus POST `approve`, `discard`, `fetch`, `destroy`.
- `lib/outbox/git.rb` — git wrapper. Arguments as arrays, never a shell. Subprocesses get
  a minimal environment (`unsetenv_others`), not the server's.
- `bin/outbox` — CLI for the same operations.

Pushes to upstream use `--force-with-lease` against the last fetched sha. Diverged
branches need an explicit force. Upstream auth is not yet decided.

## Run

```sh
bundle install
OUTBOX_DATA=./data bundle exec puma -p 8080 config.ru
```

Docker: `docker build -t outbox . && docker run -p 127.0.0.1:8080:8080 -v outbox-data:/data outbox`
