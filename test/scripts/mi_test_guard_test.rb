# frozen_string_literal: true

# rubocop:disable Rails/RefuteMethods -- standalone Minitest without Rails
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "rbconfig"
require_relative "../../script/lib/mi_test_guard"

class MiTestGuardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "script/lib/mi_test_guard.rb")

  def setup
    FileUtils.mkdir_p(File.join(ROOT, "tmp"))
    @tmp = Dir.mktmpdir("test-guard-", File.join(ROOT, "tmp"))
    @app = repository("app")
    @engine = repository("engine")
    @env = { "APP_ROOT" => @app, "ENGINE_ROOT" => @engine, "DATABASE_URL" => "postgresql:///fixture_test_guard" }
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def repository(name)
    path = File.join(@tmp, name)
    FileUtils.mkdir_p(path)
    _output, error, status = Open3.capture3("git", "-C", path, "init", "-q")
    raise error unless status.success?

    path
  end

  def validate(values = {})
    MiTestGuard.validate!(env: @env.merge(values))
  end

  def reject(values)
    assert_raises(MiTestGuard::Invalid, values.keys.join(", ")) { validate(values) }
  end

  def test_api_returns_real_roots_and_database_without_loading_rails_or_mutating_environment
    before = @env.dup
    assert_equal({ "app_root" => @app, "engine_root" => @engine, "database" => "fixture_test_guard" }, validate)
    assert_equal before, @env
    # The enclosing Rails suite may already define both constants. Prove the
    # guard's load boundary in a fresh interpreter with no inherited preload.
    probe = <<~RUBY
      before = ENV.to_h
      abort "framework already loaded" if defined?(Rails) || defined?(ActiveRecord)
      require ARGV.fetch(0)
      result = MiTestGuard.validate!(env: ENV)
      abort "guard loaded a framework" if defined?(Rails) || defined?(ActiveRecord)
      abort "guard mutated environment" unless ENV.to_h == before
      puts JSON.generate(result)
    RUBY
    output, error, status = Open3.capture3(@env.merge("PATH" => "/usr/bin:/bin"), RbConfig.ruby, "-e", probe, SCRIPT, unsetenv_others: true)
    assert status.success?, error
    assert_equal({ "app_root" => @app, "engine_root" => @engine, "database" => "fixture_test_guard" }, JSON.parse(output))
  end

  def test_both_roots_are_required_absolute_existing_git_top_levels
    %w(APP_ROOT ENGINE_ROOT).each do |key|
      [nil, "", "relative/path", File.join(@tmp, "absent"), @tmp].each { |path| reject(key => path) }
      subdir = File.join(@app, "subdir")
      FileUtils.mkdir_p(subdir)
      reject(key => subdir)
      file = File.join(@tmp, "file")
      File.write(file, "not a repository")
      reject(key => file)
    end
  end

  def test_roots_cannot_alias_or_contain_each_other
    reject("ENGINE_ROOT" => @app)
    nested = repository("app/nested")
    reject("ENGINE_ROOT" => nested)
    reject("APP_ROOT" => nested, "ENGINE_ROOT" => @app)
    link = File.join(@tmp, "alias")
    File.symlink(@app, link)
    reject("ENGINE_ROOT" => link)
    assert_equal @app, validate("APP_ROOT" => link).fetch("app_root")
  end

  def test_live_roots_children_ancestors_and_aliases_are_rejected
    live = repository("live")
    child = repository("live/child")
    link = File.join(@tmp, "live-alias")
    File.symlink(live, link)
    [live, child, @tmp, link, "/"].each do |path|
      assert_includes reject("APP_ROOT" => path, "LIVE_APP_ROOT" => live).message, "overlaps a live root"
      assert_includes reject("ENGINE_ROOT" => path, "LIVE_ENGINE_ROOT" => live).message, "overlaps a live root"
    end
    # Additional configured roots cannot replace the immutable canonical denylist.
    MiTestGuard::LIVE_ROOTS.each do |path|
      assert_includes reject("APP_ROOT" => path, "LIVE_APP_ROOT" => live).message, "overlaps a live root"
      assert_includes reject("ENGINE_ROOT" => path, "LIVE_ENGINE_ROOT" => live).message, "overlaps a live root"
    end
    reject("LIVE_APP_ROOT" => "")
    reject("LIVE_ENGINE_ROOT" => "relative")
  end

  def test_live_root_prefix_siblings_are_not_children
    live = repository("app-live")
    assert_equal @app, validate("LIVE_APP_ROOT" => live).fetch("app_root")
  end

  def test_git_worktrees_sharing_common_directory_are_valid_isolated_roots
    Open3.capture3("git", "-C", @app, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture")
    worktree = File.join(@tmp, "app-worktree")
    _output, error, status = Open3.capture3("git", "-C", @app, "worktree", "add", "--detach", worktree)
    assert status.success?, error
    assert_equal worktree, validate("APP_ROOT" => worktree, "LIVE_APP_ROOT" => @app).fetch("app_root")
  end

  def test_postgres_schemes_decoded_database_paths_and_host_port_query
    %w(postgres postgresql).each do |scheme|
      ["fixture_test_guard", "fixture_test-guard", "fixture%5Ftest%5Fguard"].each do |database|
        url = "#{scheme}://fixture:secret@localhost:5432/#{database}?host=%2Fvar%2Frun%2Fpostgresql&port=5432"
        assert_equal database.gsub("%5F", "_"), validate("DATABASE_URL" => url).fetch("database")
      end
    end
  end

  def test_url_rejects_query_overrides_unknown_keys_duplicates_and_encoded_keys
    %w(db database dbname adapter username password options service sslmode).each do |key|
      reject("DATABASE_URL" => "postgresql:///fixture_test_guard?#{key}=production")
    end
    ["%64atabase=production", "Database=production", "host=localhost&host=other", "port=1&port=2",
     "host=", "port=0", "port=65536", "port=5432junk", "host=localhost%20dbname%3Dproduction", "host=%00"].each do |query|
      reject("DATABASE_URL" => "postgresql:///fixture_test_guard?#{query}")
    end
  end

  def test_url_requires_postgres_and_exact_isolated_decoded_path
    ["mysql:///fixture_test_guard", "sqlite3:///fixture_test_guard", "postgresql:fixture_test_guard",
     "postgresql://localhost", "postgresql:///", "postgresql:///production", "postgresql:///decidim_app_test",
     "postgresql:///fixture_test_", "postgresql:///fixture_test_guard/other", "postgresql:///fixture_test_guard%2Fother",
     "postgresql:///fixture_test_guard%00", "postgresql:///fixture_test_guard%3Fdatabase=production",
     "postgresql:///fixture_test_guard%255F", "postgresql:///fixture_test_guard#ignored", "not a URI",
     "postgresql:///fixture_test_#{"a" * 63}"].each { |url| reject("DATABASE_URL" => url) }
  end

  def test_effective_url_takes_precedence_over_safe_suffix_and_named_urls_cannot_override_it
    reject("DATABASE_URL" => "postgresql:///production", "TEST_ENV_NUMBER" => "_safe", "DATABASE_USERNAME" => "fixture")
    %w(PRIMARY_DATABASE_URL TEST_DATABASE_URL).each { |key| reject(key => "postgresql:///production") }
    assert_equal "fixture_test_guard", validate("TEST_ENV_NUMBER" => "invalid-unused").fetch("database")
  end

  def test_named_url_guard_alone_does_not_require_roots_suffix_or_unfiltered_tests
    assert MiTestGuard.reject_named_database_urls!({})
    focused = { "PRIMARY_DATABASE_URL" => "", "TEST_DATABASE_URL" => "", "TEST_ENV_NUMBER" => "",
                "TEST" => "test/focused_test.rb", "TESTOPTS" => "--name test_one" }
    before = focused.dup
    assert MiTestGuard.reject_named_database_urls!(focused)
    assert_equal before, focused
  end

  def test_named_url_guard_alone_rejects_each_override_without_disclosing_credentials
    %w(PRIMARY_DATABASE_URL TEST_DATABASE_URL).each do |key|
      ["postgresql://secretuser:secretpassword@localhost/production", "postgresql:///fixture_test_guard", " "].each do |value|
        error = assert_raises(MiTestGuard::Invalid) { MiTestGuard.reject_named_database_urls!(key => value) }
        assert_equal "#{key} is not supported; use DATABASE_URL", error.message
      end
    end
  end

  def test_without_url_requires_strict_nonempty_isolated_suffix_and_username
    @env.delete("DATABASE_URL")
    @env["DATABASE_USERNAME"] = "fixture"
    [nil, "", "1", "_", "-", "_a/b", "_a?database=production", "_a\n", "_a b", "_#{"a" * 64}"].each { |suffix| reject("TEST_ENV_NUMBER" => suffix) }
    %w(_work_123 -fixture_456).each do |suffix|
      assert_equal "decidim_app_test#{suffix}", validate("TEST_ENV_NUMBER" => suffix).fetch("database")
    end
    reject("TEST_ENV_NUMBER" => "_valid", "DATABASE_USERNAME" => "")
    assert_equal "decidim_app_test_guard", validate("TEST_ENV_NUMBER" => "_guard", "DATABASE_URL" => "").fetch("database")
  end

  def test_discovery_overrides_are_rejected_even_empty
    %w(DEFAULT_TEST DEFAULT_TEST_EXCLUDE TEST).each do |key|
      ["", "test/absent*_test.rb", " ", "test/**/*_test.rb"].each { |value| reject(key => value) }
    end
  end

  def test_all_rake_option_aliases_reject_filters_names_files_and_other_options
    %w(TESTOPTS TESTOPT TEST_OPTS TEST_OPT MINITEST_OPTS).each do |key|
      ["--name no_match", "-n/no_match/", "--exclude /all/", "-e/all/", "test/no_match.rb", "--help", "--",
       "--seed 123 --name no_match", "--seed 1 -e/all/", "--seed nope", "--seed", "'unterminated"].each do |value|
        reject(key => value)
      end
    end
  end

  def test_seed_only_options_and_unrelated_environment_are_allowed
    %w(TESTOPTS TESTOPT TEST_OPTS TEST_OPT MINITEST_OPTS).each do |key|
      ["", "--seed 123", "--seed=123", "-s 123", "-s123"].each do |value|
        assert_equal "fixture_test_guard", validate(key => value, "SEED" => "123", "UNRELATED" => "preserved").fetch("database")
      end
    end
    reject("SEED" => "not a seed")
  end

  def test_non_test_rails_environment_is_rejected
    %w(RAILS_ENV RACK_ENV).each do |key|
      %w(production development).each { |value| reject(key => value) }
      assert_equal "fixture_test_guard", validate(key => "test").fetch("database")
    end
  end

  def cli(env, *)
    Open3.capture3(env.merge("PATH" => "/usr/bin:/bin"), RbConfig.ruby, SCRIPT, *, unsetenv_others: true)
  end

  def test_cli_exits_nonzero_before_followup_and_never_discloses_credentials
    output, error, status = cli(@env)
    assert status.success?, error
    assert_equal "fixture_test_guard", JSON.parse(output).fetch("database")
    output, error, status = cli(@env.merge("DATABASE_URL" => "postgresql://secretuser:secretpassword@localhost/fixture_test_guard?database=production"))
    assert_equal 2, status.exitstatus
    assert_empty output
    assert_includes error, "host/port"
    refute_match(/secretuser|secretpassword|production/, error)
    output, error, status = cli(@env.merge("DATABASE_URL" => "postgresql://secretuser:secret password@localhost/fixture_test_guard"))
    assert_equal 2, status.exitstatus
    assert_empty output
    refute_match(/secretuser|secret password/, error)
    _output, _error, status = cli(@env, "--unexpected")
    assert_equal 2, status.exitstatus
  end
end
# rubocop:enable Rails/RefuteMethods
