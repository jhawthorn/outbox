#!/usr/bin/env ruby
# frozen_string_literal: true

# The server the browser tests run against. Playwright starts this as its
# webServer (test/browser/playwright.config.js): it builds a data directory
# in a temp dir with repositories in the states the tests look at, boots
# puma on OUTBOX_TEST_PORT, and removes everything when it is stopped.
#
#   bundle exec ruby test/browser/server.rb      # what `rake browser` runs
#
# Repositories, each with a local bare upstream, except where noted:
#
#   review    two staged commits on main: several files, two hunks in one of
#             them, a commit with a body. Read-only; the diff viewer tests.
#   approve   one staged commit on main, for the approve test.
#   discard   one staged commit on main, for the discard test.
#   diverged  one staged commit on main and upstream moved underneath it.
#   rebased   a feature branch rebased onto a newer main, one of its two
#             commits amended on the way. Read-only.
#   conflicted  a feature branch rebased onto a main that changed the same
#             line, the conflict resolved by hand. Read-only.
#   slow      upstream is an http stub in this process that answers 404
#             after a delay, so a fetch can be watched running and failing.
#   headers   one staged commit: a rename, a binary file, a mode change, a
#             hidden character and a long file. Read-only.
#   images    one staged commit: a PNG changed, one added, one deleted, and
#             an SVG changed. Read-only.
#   huge      one staged commit of about 20 MB: 400 added files and a
#             lockfile of 100,000 lines. Read-only; the large diff tests.
#   browse    for browse.spec.js: a README.md with links, an image and
#             things that must not survive sanitising, docs, an image, a
#             second staged branch with a slash in its name. Read-only.
#   live      nothing staged. live.spec.js clones it over HTTP, pushes, and
#             watches open pages follow.
require "fileutils"
require "open3"
require "socket"
require "tmpdir"
require "zlib"

ROOT = File.expand_path("../..", __dir__)
require File.join(ROOT, "lib/outbox")

PORT = ENV.fetch("OUTBOX_TEST_PORT", "48080")
PASSWORD = ENV.fetch("OUTBOX_PASSWORD", "browser-test-password")
STUB_DELAY = 2 # seconds before the slow upstream answers

GIT_ENV = {
  "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
  "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com",
  "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null",
  "GIT_TERMINAL_PROMPT" => "0",
}.freeze

def git(*args, chdir: nil)
  opts = chdir ? { chdir: chdir } : {}
  out, err, status = Open3.capture3(GIT_ENV, "git", *args, **opts)
  abort "git #{args.join(" ")} failed:\n#{err}" unless status.success?
  out
end

def write(dir, file, content)
  FileUtils.mkdir_p(File.dirname(File.join(dir, file)))
  File.write(File.join(dir, file), content)
end

def commit(work, message, files)
  files.each do |file, content|
    content ? write(work, file, content) : File.delete(File.join(work, file))
  end
  git("add", "--all", chdir: work)
  git("commit", "--quiet", "-m", message, chdir: work)
end

# A PNG of one colour, width by height.
def png(width, height, rgb)
  chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
  rows = ("\0" + rgb.pack("C3") * width) * height
  "\x89PNG\r\n\x1A\n".b + chunk.("IHDR", [width, height, 8, 2, 0, 0, 0].pack("N2C5")) +
    chunk.("IDAT", Zlib::Deflate.deflate(rows)) + chunk.("IEND", "")
end

# A bare upstream with an initial commit, and the working clone it came from.
def make_upstream(dir, name, files)
  bare = File.join(dir, "#{name}-upstream.git")
  work = File.join(dir, "#{name}-upstream-work")
  git("init", "--quiet", "--bare", "-b", "main", bare)
  git("init", "--quiet", "-b", "main", work)
  git("remote", "add", "origin", bare, chdir: work)
  commit(work, "Initial commit", files)
  git("push", "--quiet", "origin", "main", chdir: work)
  [bare, work]
end

# Add a repository the way `bin/outbox add` does, fetch it, and return a
# working clone of the staging repo to push staged commits from.
def add_repo(dir, name, upstream)
  Outbox::Config.add(name, upstream)
  Outbox::Config.apply!
  repo = Outbox::Repo.find!(name)
  repo.fetch!
  work = File.join(dir, "#{name}-staged-work")
  git("clone", "--quiet", repo.path, work)
  work
end

def stage(work, message, files)
  commit(work, message, files)
  git("push", "--quiet", "origin", "main", chdir: work)
end

# An http server that answers every request with 404 after STUB_DELAY, so
# git fetch is visibly running for a while and then fails.
def start_stub
  server = TCPServer.new("127.0.0.1", 0)
  Thread.new do
    loop do
      client = server.accept
      Thread.new(client) do |c|
        loop { line = c.gets; break if line.nil? || line.strip.empty? } # request line and headers
        sleep STUB_DELAY
        c.write "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      rescue IOError, SystemCallError
        # the client gave up
      ensure
        c.close
      end
    end
  end
  server.addr[1]
end

def seed(dir)
  long = (1..120).map { |i| "line #{i}\n" }.join

  upstream, = make_upstream(dir, "review", "README" => "hello\n", "lib/long.rb" => long, "notes.md" => "notes\n")
  work = add_repo(dir, "review", upstream)
  changed = long.sub("line 10\n", "line ten\n").sub("line 100\n", "line one hundred\n")
  stage(work, "Add greeting\n\nThe README now says hello to the world,\nand two lines of long.rb change.\n",
        "README" => "hello world\n", "lib/long.rb" => changed)
  stage(work, "Add thing", "lib/thing.rb" => "class Thing\nend\n", "notes.md" => nil)

  upstream, = make_upstream(dir, "approve", "README" => "hello\n")
  stage(add_repo(dir, "approve", upstream), "Approve me", "README" => "approved\n")

  upstream, = make_upstream(dir, "comments", "README" => "hello\nold line\n")
  stage(add_repo(dir, "comments", upstream), "Change the readme", "README" => "hello\nnew line\nmore\n")
  upstream, = make_upstream(dir, "commented", "README" => "hello\n")
  stage(add_repo(dir, "commented", upstream), "Say more", "README" => "hello there\n")
  upstream, = make_upstream(dir, "edited", "README" => "hello\n")
  stage(add_repo(dir, "edited", upstream), "Say less", "README" => "hi\n")

  upstream, = make_upstream(dir, "discard", "README" => "hello\n")
  stage(add_repo(dir, "discard", upstream), "Discard me", "README" => "discarded\n")

  upstream, up_work = make_upstream(dir, "diverged", "README" => "hello\n")
  stage(add_repo(dir, "diverged", upstream), "Staged change", "README" => "staged\n")
  commit(up_work, "Upstream change", "other.txt" => "upstream\n")
  git("push", "--quiet", "origin", "main", chdir: up_work)
  Outbox::Repo.find!("diverged").fetch!

  body = (1..12).map { |i| "line #{i}\n" }.join
  upstream, up_work = make_upstream(dir, "rebased", "README" => "hello\n")
  git("checkout", "--quiet", "-b", "feature", chdir: up_work)
  commit(up_work, "Add greeter", "greeter.rb" => "class Greeter\n#{body}end\n")
  commit(up_work, "Add docs", "docs.md" => "#{body}docs\n")
  git("push", "--quiet", "origin", "feature", chdir: up_work)
  work = add_repo(dir, "rebased", upstream)
  git("checkout", "--quiet", "-b", "feature", "origin/feature", chdir: work)
  git("checkout", "--quiet", "main", chdir: up_work)
  commit(up_work, "Upstream change", "other.txt" => "upstream\n")
  git("push", "--quiet", "origin", "main", chdir: up_work)
  Outbox::Repo.find!("rebased").fetch!
  git("fetch", "--quiet", upstream, "main:refs/remotes/up/main", chdir: work)
  git("rebase", "--quiet", "up/main", chdir: work)
  git("reset", "--quiet", "--soft", "HEAD~1", chdir: work)
  commit(work, "Add docs", "docs.md" => "#{body}docs, with more\n")
  git("push", "--quiet", "--force", "origin", "feature", chdir: work)

  cfg = (1..12).map { |i| "setting_#{i} = #{i}\n" }.join
  upstream, up_work = make_upstream(dir, "conflicted", "config.ini" => cfg)
  git("checkout", "--quiet", "-b", "feature", chdir: up_work)
  commit(up_work, "Raise the timeout", "config.ini" => cfg.sub("setting_6 = 6", "setting_6 = 60"))
  git("push", "--quiet", "origin", "feature", chdir: up_work)
  work = add_repo(dir, "conflicted", upstream)
  git("checkout", "--quiet", "main", chdir: up_work)
  commit(up_work, "Change the timeout too", "config.ini" => cfg.sub("setting_6 = 6", "setting_6 = 30"))
  git("push", "--quiet", "origin", "main", chdir: up_work)
  Outbox::Repo.find!("conflicted").fetch!
  git("fetch", "--quiet", upstream, "main:refs/remotes/up/main", chdir: work)
  git("checkout", "--quiet", "-b", "feature", "up/main", chdir: work)
  commit(work, "Raise the timeout", "config.ini" => cfg.sub("setting_6 = 6", "setting_6 = 45"))
  git("push", "--quiet", "--force", "origin", "feature", chdir: work)

  # One staged commit with everything a file header has to say: a rename
  # with changes, a binary file, a mode change, a hidden character, and a
  # file long enough to scroll under its own stuck header.
  big = (1..400).map { |i| "def method_#{i} = #{i}\n" }.join
  upstream, up_work = make_upstream(dir, "headers", "old_name.rb" => body, "logo.bin" => "\x00\x01binary",
                                    "run.sh" => "echo hi\n", "big.rb" => big, "plain.txt" => "plain\n")
  work = add_repo(dir, "headers", upstream)
  git("mv", "old_name.rb", "new_name.rb", chdir: work)
  File.chmod(0o755, File.join(work, "run.sh"))
  stage(work, "Exercise the file headers",
        "new_name.rb" => body.sub("line 6\n", "line six\n"), "logo.bin" => "\x00\x02binary",
        "plain.txt" => "pla​in\n", "big.rb" => big.gsub(/= (\d*[05])$/) { "= #{$1.to_i * 2}" })

  svg = ->(fill) { %(<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30"><rect width="30" height="30" fill="#{fill}"/></svg>\n) }
  upstream, = make_upstream(dir, "images", "logo.png" => png(40, 40, [200, 0, 0]), "old.png" => png(20, 20, [0, 0, 200]),
                                           "icon.svg" => svg.("red"))
  stage(add_repo(dir, "images", upstream), "Redraw the images",
        "logo.png" => png(60, 30, [0, 160, 0]), "old.png" => nil, "new.png" => png(100, 50, [0, 120, 200]),
        "icon.svg" => svg.("green"))

  upstream, = make_upstream(dir, "huge", "README" => "hello\n")
  files = (1..400).to_h { |n| ["vendor/gem_#{n}/lib.rb", (1..1200).map { |i| "def method_#{n}_#{i}(a, b) = a + b * #{i}\n" }.join] }
  files["yarn.lock"] = (1..100_000).map { |i| "package-#{i}@^1.0.#{i}:\n" }.join
  stage(add_repo(dir, "huge", upstream), "Vendor everything", files)

  Outbox::Config.add("slow","http://127.0.0.1:#{start_stub}/slow.git")
  Outbox::Config.apply!

  readme = <<~MD
    # Browse me

    See [the guide](docs/guide.md), [the top](/lib/app.rb) and [below](#usage).

    ![logo](docs/logo.svg)
    ![tracker](https://example.invalid/pixel.png)
    <img src="https:\\\\example.invalid/b.png" alt="backslashes"> <img src="//example.invalid/c.png" alt="protocol-relative">
    <svg><image href="https://example.invalid/d.png"/></svg>
    [climb](../../../../../etc/passwd) and [both](docs/guide.md?x=1#guide)

    <script>window.pwned = 1</script>
    <img src="x" onerror="window.pwned = 2">
    <form method="post" action="/repos/browse/branches/main/approve"><button>Win a prize</button></form>
    <a href="javascript:window.pwned = 3">click</a>

    - [x] done
    - [ ] to do

    ## Usage

    Run it.
  MD
  upstream, up_work = make_upstream(dir, "browse", "README.md" => readme, "docs/guide.md" => "# Guide\n\nBack to [the readme](../README.md).\n",
                                    "docs/logo.svg" => %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>),
                                    "lib/app.rb" => "class App\n  def call = :ok\nend\n", "lib/helper.rb" => "module Helper\nend\n",
                                    "bin/tool" => "#!/usr/bin/env ruby\nclass Tool\nend\n")
  commit(up_work, "Make the app answer", "lib/app.rb" => "class App\n  def call = :answer\nend\n")
  git("push", "--quiet", "origin", "main", chdir: up_work)
  work = add_repo(dir, "browse", upstream)
  git("checkout", "--quiet", "-b", "topic/x", chdir: work)
  commit(work, "Add a topic", "lib/topic.rb" => "TOPIC = 1\n")
  git("push", "--quiet", "origin", "topic/x", chdir: work)

  upstream, = make_upstream(dir, "live", "README" => "hello\n")
  add_repo(dir, "live", upstream)
end

dir = Dir.mktmpdir("outbox-browser")
ENV["OUTBOX_DATA"] = File.join(dir, "data")
Outbox::Config.ensure!
seed(dir)
warn "outbox browser test server: data in #{dir}, http://127.0.0.1:#{PORT}/ (password #{PASSWORD})"

env = {
  "OUTBOX_DATA" => ENV["OUTBOX_DATA"],
  "OUTBOX_PASSWORD" => PASSWORD,
  "OUTBOX_UPSTREAM_TOKEN" => "browser-test-token",
  "RACK_ENV" => "test",
  "RUBYOPT" => "-W0",
}
server = spawn(env, "bundle", "exec", "puma", "-b", "tcp://127.0.0.1:#{PORT}", "config.ru", chdir: ROOT)

stop = lambda do |signal|
  Process.kill(signal, server)
rescue Errno::ESRCH
  # already gone
end
%w[INT TERM].each { |sig| trap(sig) { stop.call(sig) } }

begin
  Process.wait(server)
ensure
  FileUtils.rm_rf(dir)
end
