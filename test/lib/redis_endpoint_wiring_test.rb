# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "json"
require "open3"
require "rbconfig"
require "socket"

# Host wiring for the fail-closed test Redis endpoint (server-health plan
# item 2). test_helper has already refused production endpoints before boot;
# this proves the clients that were built during boot use that explicit
# endpoint, and that no host code keeps its own hardcoded fallback.
class RedisEndpointWiringTest < ActiveSupport::TestCase
  ROOT = Rails.root.to_s

  test "the shared resolver returns the explicit test endpoint" do
    # Boolean comparisons with value-free messages: the configured URL may
    # carry a credential and must never reach test output.
    assert ENV.fetch("REDIS_URL") == Decidim::Bih::RedisEndpoint.url, "resolver did not return the configured test endpoint (values withheld)"
    assert Decidim::Bih::RedisEndpoint.guard_test_environment!(ENV)
  end

  test "the resolver raises under test when no endpoint is configured" do
    assert_raises(Decidim::Bih::RedisEndpoint::Unconfigured) { Decidim::Bih::RedisEndpoint.url(env: {}) }
  end

  test "the rack-attack counter store points at the test endpoint without connecting" do
    store = Rack::Attack.cache.store
    store = store.__getobj__ if store.respond_to?(:__getobj__) # Rack::Attack's store proxy
    assert_kind_of ActiveSupport::Cache::RedisCacheStore, store
    expected = Decidim::Bih::RedisEndpoint.parse!(ENV.fetch("REDIS_URL"))
    # Redis#id reads the configured location; it does not open a socket.
    ids = store.redis.respond_to?(:with) ? store.redis.with(&:id) : store.redis.id
    actual = Decidim::Bih::RedisEndpoint.parse!(ids)
    assert expected == actual, "rack-attack store does not use the configured test endpoint (values withheld)"
  end

  test "host stores built without an injected client use the test endpoint" do
    stores = [
      DecidimApp::Bijeljina::SocialRegistrationHandoff.new(secret: "x" * 64),
      DecidimApp::Bijeljina::Milica::ReportConversationStore.new,
      DecidimApp::Bijeljina::Milica::ChatPhotoStore.new,
      DecidimApp::Bijeljina::Milica::RegistrationHandoffStore.new
    ]
    expected = Decidim::Bih::RedisEndpoint.parse!(ENV.fetch("REDIS_URL"))
    stores.each do |store|
      client = store.send(:redis)
      assert expected == Decidim::Bih::RedisEndpoint.parse!(client.id), "#{store.class.name} does not use the configured test endpoint (values withheld)"
    end
  end

  test "the test helper latched this process as a test process" do
    assert Decidim::Bih::RedisEndpoint.test_process?
  end

  # Tests stub Rails.env as "production". The latched process must still
  # refuse an unset, db0 or db1 REDIS_URL before any host client is built,
  # and keep using an explicit test endpoint. Redis.new is a recorder here,
  # so a regression cannot reach a server.
  test "host stores built under a production Rails.env stub stay on the test path" do
    production = ActiveSupport::EnvironmentInquirer.new("production")
    builders = {
      "SocialRegistrationHandoff" => -> { DecidimApp::Bijeljina::SocialRegistrationHandoff.new(secret: "x" * 64).send(:redis) },
      "ReportConversationStore" => -> { DecidimApp::Bijeljina::Milica::ReportConversationStore.new.send(:redis) },
      "ChatPhotoStore" => -> { DecidimApp::Bijeljina::Milica::ChatPhotoStore.new.send(:redis) },
      "RegistrationHandoffStore" => -> { DecidimApp::Bijeljina::Milica::RegistrationHandoffStore.new.send(:redis) },
      "ConversationUsage" => -> { DecidimApp::Bijeljina::Milica::ConversationUsage.new(organization_id: 1, model: "gemini-3.5-flash-lite") }
    }
    built = []
    [nil, "redis://127.0.0.1:6379/0", "redis://localhost:6379/1", "redis://#{Socket.gethostname}:6379/0"].each do |url|
      with_redis_url(url) do
        Redis.stub(:new, ->(**options) { built << options[:url] }) do
          Rails.stub(:env, production) do
            builders.each do |name, build|
              assert_raises(Decidim::Bih::RedisEndpoint::Error, "#{name} with #{url.inspect}") { build.call }
            end
          end
        end
      end
    end
    assert built.empty?, "#{built.length} Redis client(s) built for a production endpoint (values withheld)"

    expected = Decidim::Bih::RedisEndpoint.parse!(ENV.fetch("REDIS_URL"))
    Rails.stub(:env, production) do
      builders.except("ConversationUsage").each do |name, build|
        assert expected == Decidim::Bih::RedisEndpoint.parse!(build.call.id), "#{name} does not use the configured test endpoint (values withheld)"
      end
    end
  end

  # The guard's reading of an accepted URL must be the database redis-rb
  # actually selects; query-form databases (which redis-rb ignores) refuse.
  # Task A's generic endpoint cases are judged in interim mode on any machine
  # (Ruby-only seam); the installed-mode block below uses a fixture credential.
  test "accepted test URLs select the same endpoint in redis-rb" do
    absent = File.join(Dir.tmpdir, "mi-test-redis-absent-#{Process.pid}-#{object_id}")
    Decidim::Bih::TestRedisInstance.with_install_dir(absent) do
      ["redis://127.0.0.1:6379/15", "redis://localhost:6379/15", "redis://127.0.0.1:16390/0", "redis://127.0.0.1:16390/3"].each do |url|
        guard = Decidim::Bih::RedisEndpoint.assert_test_endpoint!(url, env: {})
        client = Decidim::Bih::RedisEndpoint.parse!(Redis.new(url:).id)
        assert_equal guard.to_a, client.to_a, url
      end
      ["redis://127.0.0.1:6379?db=15", "redis://127.0.0.1:6379/?db=15"].each do |url|
        assert_equal 0, Decidim::Bih::RedisEndpoint.parse!(Redis.new(url:).id).database, "redis-rb reading of #{url}"
        assert_raises(Decidim::Bih::RedisEndpoint::Refused, url) { Decidim::Bih::RedisEndpoint.assert_test_endpoint!(url, env: {}) }
      end
    end
  end

  # Installed mode (plan item 7): the instance's URLs still select what
  # redis-rb selects; the interim db15 and staging Redis are refused.
  test "installed mode accepts only the instance and keeps the redis-rb reading" do
    Dir.mktmpdir("mi-test-redis-installed") do |dir|
      File.write(File.join(dir, "url"), "redis://mi_test:wiring-fixture@127.0.0.1:16390/0\n")
      Decidim::Bih::TestRedisInstance.with_install_dir(dir) do
        ["redis://mi_test:wiring-fixture@127.0.0.1:16390/0", "redis://mi_test:wiring-fixture@localhost:16390/3"].each do |url|
          guard = Decidim::Bih::RedisEndpoint.assert_test_endpoint!(url, env: {})
          assert_equal guard.to_a, Decidim::Bih::RedisEndpoint.parse!(Redis.new(url:).id).to_a, url
        end
        ["redis://127.0.0.1:6379/15", "redis://localhost:6379/15", "redis://127.0.0.1:16379/0"].each do |url|
          assert_raises(Decidim::Bih::RedisEndpoint::Refused, url) { Decidim::Bih::RedisEndpoint.assert_test_endpoint!(url, env: {}) }
        end
      end
    end
  end

  # Real production resolution of the db0-defaulting client, in fresh
  # interpreters that never latch: REDIS_URL set and unset both match the
  # original expression ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0").
  # Redis.new is a recorder, so nothing connects. Only fixture values are used.
  test "ConversationUsage production resolution is byte-identical in a fresh process" do
    probe = <<~RUBY
      require "json"
      require "redis"
      recorded = []
      Redis.singleton_class.define_method(:new) { |**options| recorded << options[:url]; Object.new }
      load ARGV.fetch(0)
      DecidimApp::Bijeljina::Milica::ConversationUsage.new(organization_id: 1, model: "gemini-3.5-flash-lite")
      print JSON.generate(url: recorded.fetch(0), original: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"),
                          latched: Decidim::Bih::RedisEndpoint.test_process?)
    RUBY
    source = File.join(ROOT, "app/services/decidim_app/bijeljina/milica/conversation_usage.rb")
    base = ENV.to_h.slice("PATH", "HOME", "LANG", "BUNDLE_GEMFILE", "BUNDLE_APP_CONFIG", "BUNDLE_USER_CONFIG",
                          "BUNDLE_LOCAL__DECIDIM___BIH", "BUNDLE_DISABLE_LOCAL_BRANCH_CHECK", "RBENV_ROOT")
    { nil => "redis://127.0.0.1:6379/0", "redis://:fixture-pass@10.9.8.7:6380/2" => "redis://:fixture-pass@10.9.8.7:6380/2" }.each do |url, expected|
      env = base.merge("RAILS_ENV" => "production")
      env["REDIS_URL"] = url if url
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-rbundler/setup", "-e", probe, source, unsetenv_others: true)
      assert status.success?, err.lines.last(3).join
      result = JSON.parse(out)
      assert_equal expected.b, result.fetch("url").b
      assert_equal result.fetch("original").b, result.fetch("url").b
      assert_not result.fetch("latched")
    end
  end

  test "host code has no hardcoded Redis fallback" do
    offenders = Dir[File.join(ROOT, "{app,config,lib}/**/*.{rb,yml,erb}")].select do |path|
      File.read(path).match?(%r{REDIS_URL["']\s*(?:,|\)\s*\{)\s*["']redis://|redis://(?:localhost|127\.0\.0\.1):6379})
    end
    assert_empty(offenders.map { |path| path.delete_prefix("#{ROOT}/") })
  end

  private

  def with_redis_url(url)
    previous = ENV.fetch("REDIS_URL", nil)
    url ? ENV["REDIS_URL"] = url : ENV.delete("REDIS_URL")
    yield
  ensure
    previous ? ENV["REDIS_URL"] = previous : ENV.delete("REDIS_URL")
  end
end
