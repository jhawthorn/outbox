# outbox

A git remote that holds pushes for human review before forwarding them to the real remote.

Push to `http://localhost:8080/<name>.git` instead of the upstream. A web UI shows each
branch's commits and diff against upstream. A human approves (outbox pushes to upstream)
or discards (staged branch is reset). Nothing reaches upstream without approval.

## Configuration

Which repositories exist, and which remotes each one tracks, is itself kept in git and
changed through the same review. The approved copy is a bare repo at
`$OUTBOX_DATA/config.git` holding one file, `outbox.conf`, in git's own config syntax:

```
[remote "you"]
    url = https://github.com/you/${name}.git
[remote "ruby"]
    url = https://github.com/ruby/${name}.git

[repo "ruby"]
    push = you
    fetch = ruby
    base = ruby/master
    base = ruby/ruby_4_0

[repo "myapp"]
    push = you
```

A remote is named once, and `${name}` in its url stands for each repository's name, as in
Gerrit's replication config. A url without `${name}` is one repository, so only one entry
may use it. Remote names are ref path components in every clone: no `/` or `.`, and not
`origin`.

- `push` is the remote approvals go to (`upstream` in the rest of this README).
- `fetch`, any number, are remotes that are only ever fetched: the repo a fork came from,
  say. Commits any remote has are never counted as a branch's own.
- `base`, any number, as `remote/branch`, are where new work starts. A new branch is
  shown against the one it builds on, the one leaving it the fewest commits of its own,
  the first listed on a tie. Without any, the base is the push remote's default branch.

`upstream = <url>` in place of `push` is the older form: a push remote called `upstream`,
with that url. It can be combined with `fetch` and `base`.

Each staging repo keeps its remotes as git remotes of the same names, fetched into
`refs/remotes/<remote>/*`, and records which is the push remote (`outbox.push`) and the
bases (`outbox.base`) in its own git config.

That repo is never served. What is served is `_config.git`, a staging repo like any
other whose upstream is the approved copy. Anyone who can push, agents included, can
clone it, edit the file, and push; the change shows up for review with a diff, and
approving it is what makes it real. Then the outbox creates a staging repo for each new
entry and brings the remotes of the others in line: adds new ones, re-points moved ones,
renames the push remote when only its name changed (keeping what it has, so pending
branches stay pending against it), and removes ones no longer listed along with their
fetched refs. Every repo that is new, or gained or re-pointed a remote, is fetched. Nothing
is fetched from a proposed remote until a human has approved it.

Nothing is ever deleted by a configuration change. A staging repo whose entry is removed
stays on disk and in the UI until the operator runs `bin/outbox remove <name>`, which is
the only thing that deletes one. A staging repo that predates the configuration is in the
same position: on disk, served, reviewed, just not listed in `outbox.conf`.

Agents can read `outbox.conf` from a clone of `_config.git` to learn which repositories
exist and what their remotes are. Its `main` is the staged copy and may hold proposals
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
  `refs/heads/*` is what was pushed here; `refs/remotes/<push>/*` is the real remote,
  and `refs/remotes/<other>/*` each fetch-only one. A branch is pending when it differs
  from the push remote's. States: ready, new, deleted, diverged, synced. A diverged
  branch moved onto a newer base is also rebased (below).
- `lib/outbox/git_http.rb` — Rack middleware serving smart HTTP via `git http-backend`.
- `lib/outbox/app.rb`, `views/` — Sinatra UI. Routes: `/`, `/repos/:name`,
  `/repos/:name/branches/*`, `.../commits/:sha`, each also as `.patch` (raw diff),
  plus POST `approve`, `discard`, `fetch`, and `/events`, which keeps pages current
  (below).
- `lib/outbox/diff.rb` — parses a patch for the summary: files, status, counts, and
  lines with hidden characters. The diff body itself is drawn in the browser.
- `assets/diffs.js` — the diff viewer: [@pierre/diffs](https://diffs.com) (Shiki
  highlighting), fetching the `.patch` URL and drawing every file in one CodeView, which
  becomes the page's scroller (the rest of the page is its header). File headers are
  pierre's, with outbox's fold toggle, mode/binary notes and hidden-character badge in
  their slots, from data attributes on the server's file sections. Each file can be
  shown whole, and selected line numbers go in the URL (`#f1-R10-R14`, `L` for the old
  side), so lines can be linked to. `rake assets` bundles
  it with esbuild into `public/diffs/` (gitignored; needs pnpm). Without it the pages
  still work, with a notice and a link to the raw patch instead of rendered diffs.
- `lib/outbox/git.rb` — git wrapper. Arguments as arrays, never a shell. Subprocesses get
  a minimal environment (`unsetenv_others`), not the server's.
- `lib/outbox/repo_actor.rb` — one Ractor per repo; the only thing that writes to it.
  Jobs (fetch, approve, discard) arrive on its port; it reports progress and results.
- `lib/outbox/hub.rb` — main-Ractor side: spawns actors, queues jobs, folds their events
  into a per-repo Status that the UI reads. Reads (branches, diffs) bypass the actor.
  Applies the configuration at boot and after each approval on `_config`. Tells open
  pages about every change, through the notifier.
- `lib/outbox/notifier.rb` — the `/events` stream: holds every open page's connection
  and writes to them all from one thread.
- `lib/outbox/push_watcher.rb` — notices pushes, which land through the git daemon in
  another container, by the mark each repo's `post-receive` hook leaves.
- `bin/outbox` — CLI for the same operations, synchronous, in its own process.
- `test/` — minitest unit tests, `smoke_test.rb` against a booted server, and `browser/`,
  Playwright tests in Chromium for what only runs in the browser: the diff viewer, live
  updates, confirm dialogs, the offline page.

Pushes to upstream use `--force-with-lease` against the last fetched sha. Diverged
branches need an explicit force. A branch's diff runs from upstream's current tip to the
staged tip, so for a diverged branch it is exactly what the force push changes there: an
amended commit shows as the amendment, and anything only upstream has shows as removed.

A branch rebased onto a newer base is diverged too, but that diff would be mostly the
base's own commits, so a rebase is told apart and shown for what it is. A diverged branch
is rebased when its staged commits build on one commit a remote has (`git rev-list
--boundary`, against every remote's refs) and that is not where upstream's version of the
branch builds; the commits between are counted as picked up, not as the branch's. The
page then lists only the branch's own commits, resting on the commit it was rebased onto,
and diffs the staged tip against upstream's version of the branch replayed onto that
commit (`git merge-tree`): a plain rebase shows no changes, an amend shows the amendment,
and a conflict shows the markers being replaced by the resolution, with the files named.
On every diverged branch, `git range-diff` pairs the staged commits with upstream's: each
staged commit is marked unchanged or changed from the one it carries over, and only the
upstream commits nothing carries over are listed as dropped. The pairing is skipped past
200 commits a side, since it compares each commit with every other.

## Live pages

Pages follow what happens without a reload: a push landing, a job queued, running and
finishing, an approval made in another tab. Each page opens `GET /events`, a stream of
server-sent events, each naming a repository and saying whether its refs may have moved
(`refs`: a push, a finished job) or only its job status changed (`status`). The index
cares about every repository, a repository's pages about their own. On an event the page
fetches itself again, at most about once a second.

The index and a repository's page swap in the new content. A branch page, and a commit
page, do not: what gets approved must be what was reviewed, so a page never changes under
the reader. When the branch has moved, or the page is gone, a notice says so and offers a
reload, and the page's approve and discard buttons are disabled. (The server would refuse
them anyway if the staged sha moved: each carries the sha the page showed.)

Every event has an id counting up from the server's start, pages are drawn with the id
they reflect, and a stream opens by saying the latest. A page that missed something while
it had no stream (still loading, in a hidden tab, reconnecting after a restart) sees the
difference and fetches itself once. A hidden tab closes its stream, since a browser allows
only a few connections to one host over HTTP/1.1, and opens it again when shown.

The server knows of its own jobs. Pushes are another matter: agents push to the git
daemon, a separate container, and the only trace of a push in this process is on the
shared volume. Each staging repo has a `post-receive` hook (installed with the `update`
hook, on creation and on every fetch) that touches `outbox-pushed` in the repo, and the
`PushWatcher` stats that file in every repo once a second.

The stream holds no puma thread. `/events` answers with a Rack 3 streaming body; puma
writes the headers, hands it the socket and moves on, and the notifier's one thread writes
every event to every socket, a burst (git's progress lines) collapsed to one per repository
and kind, with a comment every 15 seconds when quiet. A socket that will not take a write
is dropped rather than waited on; its browser reconnects. Behind a proxy the stream must
not be buffered (`X-Accel-Buffering: no` is sent for nginx).

## Upstream auth

Remotes are https URLs or local paths. One token, `OUTBOX_UPSTREAM_TOKEN` in the
server's environment, authenticates every fetch and push. On GitHub that is a fine-grained
personal access token with Contents read and write on the repositories the outbox may
push to; adding a repository is then one line in `outbox.conf` and nothing else. Git only
asks for it when a remote demands credentials, so a public fetch-only remote never sees
it; one that does ask, on any host, is given it.

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

Every remote of a repo is fetched, the push remote first, when its entry is approved or
changed, once per repo at boot, and when you click "Fetch upstream" on a repo page or
"Fetch all upstreams" on the index. Never on a timer. A fetch-only remote that fails does
not stop the push remote's fetch from taking effect.

Clones see only `refs/heads/*` unless told otherwise. A client that also fetches
`+refs/remotes/*:refs/remotes/*` from the staging repo gets every remote's branches beside
its own `origin/*`: `you/main` is what the push remote has, `ruby/master` a fetch-only
remote's.

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
- **Diff base for a new branch** is the merge-base with the nearest base, like a GitHub
  compare. A branch forked from a remote branch that is not a base shows that branch's
  commits too. `git rev-list --boundary <branch> --not --remotes` finds the exact
  attachment point in one call and would be more accurate when there is a single boundary.
- **Base patterns.** `base = ruby/ruby_*`, so a new stable branch needs no config change.
- **One remote name, different places.** A remote's name means one url pattern in every
  repo. Scoping a remote to one repo (`[remote "upstream.nokogiri"]`, winning over
  `[remote "upstream"]` there) would lift that; remote names have no `.` to keep it free.
- **Proposals not named for branches.** Pushes to something like
  `refs/for/<remote>/<branch>` rather than branch names matched one-to-one.
- **Commit limits disagree.** The branch page lists up to 200 commits; the commit page
  validates against 1000. Past 200 the two views do not match.
- **Merge commits** get a "merge" badge in the commit list. GitHub does not badge them;
  it shows the parents on the commit page instead. Undecided.
