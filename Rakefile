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

task default: %i[test smoke]
