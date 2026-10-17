# frozen_string_literal: true

require "rake/testtask"

# Unit tests: fast, no server, git against temp dirs.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/*_test.rb"].exclude("test/smoke_test.rb")
  t.warning = false
end

# End to end: boots the real server on a random localhost port.
Rake::TestTask.new(:smoke) do |t|
  t.libs << "test"
  t.test_files = ["test/smoke_test.rb"]
  t.warning = false
end

# Rebuild the browser bundle (public/diffs) after changing assets/ or
# bumping a JS dependency. Needs pnpm.
task :assets do
  sh "pnpm", "install", "--frozen-lockfile"
  sh "pnpm", "build"
end

# Browser tests: Playwright in Chromium against a real server with seeded
# repositories (test/browser/server.rb). Needs the bundle, since the diff
# viewer is most of what they look at. Extra arguments go to Playwright:
#
#   rake browser -- --headed            # watch
#   rake browser -- review.spec.js      # one file
task browser: :assets do
  args = ARGV.drop_while { |a| a != "--" }.drop(1)
  sh "pnpm", "exec", "playwright", "install", "chromium"
  sh "pnpm", "exec", "playwright", "test", "-c", "test/browser", *args
  exit # rake would otherwise try to run the arguments as tasks
end

task default: %i[test smoke browser]
