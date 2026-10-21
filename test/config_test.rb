# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < OutboxTest::RepoCase
  Config = Outbox::Config
  Repo = Outbox::Repo

  def live = Config.live_path

  def conf = git("show", "HEAD:outbox.conf", chdir: live)

  def test_ensure_creates_the_live_repo_and_its_staging_repo
    assert_equal "refs/heads/main", git("symbolic-ref", "HEAD", chdir: live).strip
    assert_includes conf, "[repo \"rails\"]", "the initial file explains the format"
    assert_equal "outbox", git("log", "-1", "--format=%an", chdir: live).strip

    staging = Config.staging
    assert File.directory?(staging.path)
    assert staging.config?
    assert_equal "../../config.git", staging.upstream_url
    assert File.executable?(File.join(staging.path, "hooks", "update"))
    assert_equal File.join(Repo.repos_dir, "_config.git"), staging.path

    staging.fetch!
    assert_equal [%w[main synced]], staging.branches.map { |b| [b.name, b.status.to_s] }
    assert_equal "refs/heads/main", staging.git("symbolic-ref", "HEAD").strip
  end

  def test_ensure_is_idempotent
    before = rev(live, "main")
    Config.ensure!
    assert_equal before, rev(live, "main")
    assert_equal %w[_config demo], Repo.all.map(&:name)
  end

  # A data directory from before the configuration existed: repos on disk,
  # no config.git. They are left exactly as they are.
  def test_ensure_leaves_existing_repos_alone
    FileUtils.rm_rf(live)
    Config.staging.destroy!

    Config.ensure!
    assert_empty Config.load.repos
    assert_empty Config.apply!
    assert_equal %w[_config demo], Repo.all.map(&:name)
    assert File.exist?(@repo.path)
  end

  def test_load_parses_entries_and_reports_problems
    assert_empty Config.load.repos
    assert_empty Config.load.problems

    Config.edit(message: "Several") do |f|
      File.write(f, <<~CONF)
        [repo "rails"]
            upstream = git@github.com:rails/rails.git
        [repo "a.b"]
            upstream = https://example.com/a.git
            other = ignored
        [repo "-x"]
            upstream = x
        [repo "_config"]
            upstream = y
        [repo "empty"]
            upstream =
        [something]
            upstream = not a repo
      CONF
    end
    config = Config.load
    assert_equal({ "a.b" => "https://example.com/a.git" }, config.repos.transform_values(&:push_url))
    assert_equal [
      "rails: upstream git@github.com:rails/rails.git must be an https URL (authenticated with OUTBOX_UPSTREAM_TOKEN) or a local path",
      "\"-x\" is not a valid repository name",
      "_config is reserved for the configuration itself",
      "empty has no upstream",
    ], config.problems
  end

  def write_conf(text) = Config.edit(message: "Edit") { |f| File.write(f, text) }

  def test_load_reads_named_remotes
    write_conf(<<~'CONF')
      [remote "you"]
          url = https://github.com/you/${name}.git
      [remote "ruby"]
          url = https://github.com/ruby/${name}.git
      [remote "shopify"]
          url = https://github.com/Shopify/${name}.git

      [repo "ruby"]
          push = you
          fetch = ruby
          fetch = shopify
          base = ruby/master
          base = ruby/ruby_4_0

      [repo "vernier"]
          push = you
    CONF
    config = Config.load
    assert_empty config.problems
    ruby = config.repos.fetch("ruby")
    assert_equal "you", ruby.push
    assert_equal [%w[you https://github.com/you/ruby.git], %w[ruby https://github.com/ruby/ruby.git],
                  %w[shopify https://github.com/Shopify/ruby.git]], ruby.remotes.to_a
    assert_equal %w[ruby/master ruby/ruby_4_0], ruby.bases
    vernier = config.repos.fetch("vernier")
    assert_equal [%w[you https://github.com/you/vernier.git]], vernier.remotes.to_a
    assert_empty vernier.bases
  end

  def test_load_reports_problems_with_remotes_and_bases
    write_conf(<<~'CONF')
      [remote "you"]
          url = https://github.com/you/${name}.git
      [remote "origin"]
          url = https://example.com/${name}.git
      [remote "a.b"]
          url = https://example.com/${name}.git
      [remote "nourl"]
          other = x
      [remote "ssh"]
          url = git@github.com:x/${name}.git
      [remote "solo"]
          url = https://github.com/ruby/ruby.git

      [repo "nopush"]
          fetch = you
      [repo "both"]
          upstream = https://example.com/both.git
          push = you
      [repo "twopush"]
          push = you
          push = solo
      [repo "unknown"]
          push = you
          fetch = nope
      [repo "twice"]
          push = you
          fetch = you
      [repo "badbase"]
          push = you
          base = ruby/master
          base = you/
          base = you/a..b
      [repo "dupbase"]
          push = you
          base = you/main
          base = you/main
      [repo "sshy"]
          push = ssh
      [repo "s1"]
          push = you
          fetch = solo
      [repo "s2"]
          push = you
          fetch = solo
      [repo "s3"]
          push = solo
      [repo "fine"]
          push = you
          base = you/main
    CONF
    config = Config.load
    assert_equal %w[fine], config.repos.keys
    assert_equal [
      "origin is reserved: clones of the outbox use it",
      "\"a.b\" is not a valid remote name",
      "remote nourl has no url",
      "nopush has no push remote",
      "both has both upstream and push; give one",
      "twopush has more than one push remote",
      "unknown: no remote named nope",
      "twice lists remote you twice",
      "badbase: base ruby/master is not a branch of one of its remotes, as remote/branch",
      "badbase: base you/ is not a branch of one of its remotes, as remote/branch",
      "badbase: base you/a..b is not a branch of one of its remotes, as remote/branch",
      "dupbase lists base you/main twice",
      "sshy: remote ssh git@github.com:x/sshy.git must be an https URL (authenticated with OUTBOX_UPSTREAM_TOKEN) or a local path",
      "remote solo has no ${name} in its url, so only one repository can use it, not s1, s2, s3",
    ], config.problems
  end

  def test_load_survives_a_missing_file
    Config.edit(message: "Delete it") { |f| File.delete(f) }
    config = Config.load
    assert_empty config.repos
    assert_match(/outbox\.conf could not be read/, config.problems.first)
  end

  def test_add_edits_the_live_config
    Config.add("demo", @upstream)
    assert_equal({ "demo" => @upstream }, Config.load.repos.transform_values(&:push_url))
    assert_equal "Add demo", git("log", "-1", "--format=%s", chdir: live).strip

    other, = make_upstream("other")
    Config.add("other", other)
    assert_equal %w[demo other], Config.load.repos.keys
    assert_equal 3, git("rev-list", "--count", "main", chdir: live).to_i

    assert_raises(ArgumentError) { Config.add("bad name", other) }
    assert_raises(ArgumentError) { Config.add("_config", other) }
    assert_raises(ArgumentError) { Config.add("x", " ") }
    err = assert_raises(ArgumentError) { Config.add("x", "git@github.com:x/y.git") }
    assert_includes err.message, "must be an https URL"
    assert_equal %w[demo other], Config.load.repos.keys
  end

  def test_remove_drops_the_entry_and_destroys_the_staging_repo
    Config.add("demo", @upstream)
    Config.remove("demo")
    assert_empty Config.load.repos
    refute File.exist?(@repo.path)
    assert_equal "hello\n", git("show", "main:README", chdir: @upstream), "upstream untouched"

    # Also for a repo that was never configured, and never for _config.
    other, = make_upstream("other")
    Repo.create("other", other)
    Config.remove("other")
    assert_equal %w[_config], Repo.all.map(&:name)
    assert_raises(Outbox::NotFound) { Config.remove("nope") }
    assert_raises(ArgumentError) { Config.remove("_config") }
    assert File.directory?(Config.staging.path)
  end

  def test_apply_creates_and_updates_but_never_destroys
    # demo exists on disk but is not configured; other is configured but absent.
    other, = make_upstream("other")
    Config.add("other", other)

    created = Config.apply!
    assert_equal ["other"], created.map(&:name)
    assert File.exist?(@repo.path), "a repo with no entry is left alone"
    assert_equal %w[_config demo other], Repo.all.map(&:name)
    assert_equal other, Repo.find!("other").upstream_url

    created.first.fetch!
    assert_equal %w[main], Repo.find!("other").branches.map(&:name)

    # A changed upstream re-points the existing staging repo, which then
    # wants a fetch.
    moved, = make_upstream("moved")
    Config.add("other", moved)
    assert_equal ["other"], Config.apply!.map(&:name)
    assert_equal moved, Repo.find!("other").upstream_url
    assert_empty Config.apply!, "nothing changed"

    # The config repo itself is never touched.
    assert File.directory?(Config.staging.path)
    assert_empty Config.apply!
  end

  # A fork: mine/proj.git is a copy of theirs/proj.git, which has moved on.
  def test_apply_gives_a_repo_its_remotes_and_bases
    theirs, their_work = make_upstream("proj", dir: File.join(@dir, "theirs"))
    mine = File.join(@dir, "mine", "proj.git")
    git("clone", "--quiet", "--bare", theirs, mine)
    commit(their_work, "new.txt", "new\n", "Theirs moved on")
    push(their_work, "main")
    conf = <<~CONF
      [remote "mine"]
          url = #{@dir}/mine/${name}.git
      [remote "theirs"]
          url = #{@dir}/theirs/${name}.git
      [repo "proj"]
          push = mine
          fetch = theirs
          base = theirs/main
    CONF
    write_conf(conf)
    assert_equal ["proj"], Config.apply!.map(&:name)
    repo = Repo.find!("proj")
    assert_equal [["mine", mine], ["theirs", theirs]], repo.remotes.to_a
    assert_equal "mine", repo.push_remote
    assert_equal ["theirs/main"], repo.configured_bases
    repo.fetch!
    assert_equal rev(mine, "main"), rev(repo.path, "refs/heads/main")
    assert_equal rev(theirs, "main"), rev(repo.path, "refs/remotes/theirs/main")
    assert_empty Config.apply!, "nothing changed"

    write_conf(conf.sub(/^\s*fetch = theirs\n/, "").sub(%r{^\s*base = theirs/main\n}, ""))
    assert_empty Config.apply!, "dropping a remote needs no fetch"
    assert_equal %w[mine], Repo.find!("proj").remotes.keys
    write_conf(conf)
    assert_equal ["proj"], Config.apply!.map(&:name), "adding one does"
  end

  # The upstream remote of a repo from before remotes had names becomes the
  # named push remote, keeping what it has.
  def test_apply_names_an_upstream_remote
    stage_commit
    write_conf(<<~CONF)
      [remote "mine"]
          url = #{@upstream}
      [repo "demo"]
          push = mine
    CONF
    assert_empty Config.apply!, "the same repo by another name needs no fetch"
    repo = Repo.find!("demo")
    assert_equal [["mine", @upstream]], repo.remotes.to_a
    assert_equal rev(@upstream, "main"), rev(repo.path, "refs/remotes/mine/main")
    assert_equal :ready, repo.branch("main").status
  end

  def test_proposed_change_goes_through_review_before_taking_effect
    staging = Config.staging
    staging.fetch!
    work = File.join(@dir, "config-work")
    git("clone", "--quiet", staging.path, work)
    git("config", "-f", File.join(work, "outbox.conf"), "repo.demo.upstream", @upstream, chdir: work)
    git("commit", "--quiet", "-am", "Add demo", chdir: work)
    push(work, "main")

    b = staging.branch("main")
    assert_equal :ready, b.status
    assert_equal ["Add demo"], staging.commits("main").map(&:subject)
    assert_equal ["outbox.conf"], staging.diff("main").files.map(&:path)
    assert_empty Config.load.repos, "the live config is untouched until approval"

    staging.approve!("main")
    assert_equal({ "demo" => @upstream }, Config.load.repos.transform_values(&:push_url))
    assert_equal :synced, staging.branch("main").status
    assert_equal rev(work, "HEAD"), rev(live, "main")
  end

  def test_only_branches_of_the_config_repo_can_be_pushed
    staging = Config.staging
    staging.fetch!
    work = File.join(@dir, "config-work")
    git("clone", "--quiet", staging.path, work)
    git("commit", "--quiet", "--allow-empty", "-m", "Sneaky", chdir: work)
    _, err, status = Open3.capture3(OutboxTest::GIT_ENV, "git", "push", "origin", "HEAD:refs/remotes/upstream/main", chdir: work)
    refute status.success?
    assert_includes err, "only branches"
    assert_equal rev(live, "main"), rev(staging.path, "refs/remotes/upstream/main")
  end
end
