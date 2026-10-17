# outbox

A git remote that holds pushes for human review before forwarding them to the real remote.

Push to `http://localhost:8080/<name>.git` instead of the upstream. A web UI shows each
branch's commits and diff against upstream. A human approves (outbox pushes to upstream)
or discards (staged branch is reset). Nothing reaches upstream without approval.

## Configuration

Which repositories exist, and where their upstreams are, is itself kept in git and
changed through the same review. The approved copy is a bare repo at
`$OUTBOX_DATA/config.git` holding one file, `outbox.conf`, in git's own config syntax:

```
[repo "rails"]
    upstream = https://github.com/rails/rails.git
```

That repo is never served. What is served is `_config.git`, a staging repo like any
other whose upstream is the approved copy. Anyone who can push, agents included, can
clone it, edit the file, and push; the change shows up for review with a diff, and
approving it is what makes it real. Then the outbox creates a staging repo for each new
entry (and starts its first fetch) and re-points one whose upstream changed. Nothing is
fetched from a proposed upstream until a human has approved it.

Nothing is ever deleted by a configuration change. A staging repo whose entry is removed
stays on disk and in the UI until the operator runs `bin/outbox remove <name>`, which is
the only thing that deletes one. A staging repo that predates the configuration is in the
same position: on disk, served, reviewed, just not listed in `outbox.conf`.

Agents can read `outbox.conf` from a clone of `_config.git` to learn which repositories
exist and what their upstreams are. Its `main` is the staged copy and may hold proposals
not yet approved; `refs/remotes/upstream/main` in the same repo is the approved state.

`bin/outbox add` and `remove` edit the approved copy directly, for the operator. In the
container, run it as the server's user, since the data directory belongs to it:

```sh
podman compose exec -u outbox outbox bin/outbox add myapp git@github.com:you/myapp.git
```

## Layout

- `lib/outbox/config.rb` — the configuration above: creating the two repos, reading
  the approved file with `git config --blob`, and `apply!`, which makes `repos/` match.
- `lib/outbox/repo.rb` — one bare repo per name under `$OUTBOX_DATA/repos/<name>.git`.
  `refs/heads/*` is what was pushed here; `refs/remotes/upstream/*` is the real remote.
  A branch is pending when they differ. States: ready, new, deleted, diverged, synced.
- `lib/outbox/git_http.rb` — Rack middleware serving smart HTTP via `git http-backend`.
- `lib/outbox/app.rb`, `views/` — Sinatra UI. Routes: `/`, `/repos/:name`,
  `/repos/:name/branches/*`, `.../commits/:sha`, each also as `.patch` (raw diff),
  plus POST `approve`, `discard`, `fetch`.
- `lib/outbox/diff.rb` — parses a patch for the summary: files, status, counts, and
  lines with hidden characters. The diff body itself is drawn in the browser.
- `assets/diffs.js` — the diff viewer: [@pierre/diffs](https://diffs.com) (Shiki
  highlighting), fetching the `.patch` URL and rendering each file. `rake assets` bundles
  it with esbuild into `public/diffs/` (gitignored; needs pnpm). Without it the pages
  still work, with a notice and a link to the raw patch instead of rendered diffs.
- `lib/outbox/git.rb` — git wrapper. Arguments as arrays, never a shell. Subprocesses get
  a minimal environment (`unsetenv_others`), not the server's.
- `lib/outbox/repo_actor.rb` — one Ractor per repo; the only thing that writes to it.
  Jobs (fetch, approve, discard) arrive on its port; it reports progress and results.
- `lib/outbox/hub.rb` — main-Ractor side: spawns actors, queues jobs, folds their events
  into a per-repo Status that the UI reads. Reads (branches, diffs) bypass the actor.
  Applies the configuration at boot and after each approval on `_config`.
- `bin/outbox` — CLI for the same operations, synchronous, in its own process.
- `test/` — minitest unit tests, `smoke_test.rb` against a booted server, and `browser/`,
  Playwright tests in Chromium for what only runs in the browser: the diff viewer, live
  updates, confirm dialogs, the offline page.

Pushes to upstream use `--force-with-lease` against the last fetched sha. Diverged
branches need an explicit force. A branch's diff runs from upstream's current tip to the
staged tip, so for a diverged branch it is exactly what the force push changes there: an
amended commit shows as the amendment, and anything only upstream has shows as removed.

## Upstream auth

Upstreams are https URLs or local paths. One token, `OUTBOX_UPSTREAM_TOKEN` in the
server's environment, authenticates every fetch and push. On GitHub that is a fine-grained
personal access token with Contents read and write on the repositories the outbox may
push to; adding a repository is then one line in `outbox.conf` and nothing else.

Git asks for credentials through `GIT_ASKPASS`, set to `bin/outbox-askpass`, which git
runs directly (no shell) and which answers from its environment, so the token is never a
command-line argument. Only the fetch and push commands get it. The commands that read the
local repo, `git http-backend`, and the git daemon container never see it.

ssh and `git://` upstreams are refused by the configuration check, since there is nothing
here to authenticate them with. Local paths need no token.

## Access

`OUTBOX_PASSWORD` is required; the server refuses to start without it. Every request
needs it as HTTP basic auth (any username). Browsers remember it; git stores it in your
credential helper after the first prompt. It travels in the clear, so this assumes a
trusted LAN. Put a TLS proxy in front if that is not true.

An agent must never have the password: with it, an agent can approve its own push. Two
ways to give agents git access without it:

- `OUTBOX_GIT_AUTH=none`: the git endpoint on the main port (`/<name>.git/*`) needs no
  password. Simplest. Means anything on the LAN can clone and push.
- Default: the git endpoint needs the password too, and agents use `outbox-git`, a plain
  `git daemon` with push enabled on the compose `agents` network, not published to the
  host and mounting only the repos volume. Agent containers join that network and use
  `git://outbox-git/<name>.git`. The network is `internal`, so agents need a second
  network for the LLM API.

Either way agents get no credentials of any kind.

Every staging repo has an `update` hook that rejects pushes to anything but
`refs/heads/*`. Without it, `receive-pack` would accept an update to
`refs/remotes/upstream/<branch>`, which is the outbox's record of what upstream has.
The hook applies to pushes over the daemon and over HTTP alike, and is installed on
create and re-checked on every fetch.

## Fetching

Upstream is fetched when a repo's entry is approved, once per repo at boot, and when you
click "Fetch upstream" on a repo page or "Fetch all upstreams" on the index. Never on a
timer.

## Run

```sh
bundle install
bundle exec rake assets                     # diff viewer bundle; needs pnpm
OUTBOX_PASSWORD=... OUTBOX_UPSTREAM_TOKEN=... bundle exec puma -p 8080 config.ru   # data in ./data
bin/outbox add myapp https://github.com/you/myapp.git    # or push to _config.git and approve
                                            # (in the container: podman compose exec -u outbox outbox bin/outbox add ...)
bundle exec rake test                       # unit tests, git against temp dirs
bundle exec rake smoke                      # end-to-end, uses a temp dir and a random port
bundle exec rake browser                    # Playwright in Chromium; needs pnpm, builds the bundle
```

The browser tests are `test/browser/*.spec.js`. Playwright starts `test/browser/server.rb`,
which seeds repositories in each state the tests look at into a temp dir and boots puma on
port 48080 (`OUTBOX_TEST_PORT` to change). `rake browser -- --headed` watches, `--ui` steps
through; see `test/browser/playwright.config.js`.

Container: put `OUTBOX_PASSWORD=...` and `OUTBOX_UPSTREAM_TOKEN=...` in `.env`, then
`podman compose up -d --build` (or `docker compose`) and open port 8080 on this machine.
Data lives in the `outbox-repos` and `outbox-config` volumes. Rootless podman is fine;
nothing needs root.

## Not yet done

Things discussed and deliberately left.

- **Reading the approved configuration from a clone.** Agents have to know to look at
  `refs/remotes/upstream/main` of `_config.git` rather than `main` if they want only
  approved entries. Serving the approved copy read-only under its own name would be
  plainer, at the cost of a second served repo.
- **Staleness.** Everything on a branch page is computed against upstream as of the last
  fetch. If an agent builds on a newer upstream than the outbox has and pushes, upstream's
  own commits show up as new work. Fetching when a push arrives (the HTTP middleware
  already sees every `git-receive-pack`) would fix the common case at one fetch per push.
  Not done because fetch policy was explicitly limited to add, boot and the button.
- **Diff base for a new branch** is the merge-base with upstream's default branch, like
  a GitHub compare. A branch forked from some other upstream branch shows that branch's
  commits too. `git rev-list --boundary <branch> --not --remotes=upstream` finds the exact
  attachment point in one call and would be more accurate when there is a single boundary.
- **Commit limits disagree.** The branch page lists up to 200 commits; the commit page
  validates against 1000. Past 200 the two views do not match.
- **Merge commits** get a "merge" badge in the commit list. GitHub does not badge them;
  it shows the parents on the commit page instead. Undecided.
