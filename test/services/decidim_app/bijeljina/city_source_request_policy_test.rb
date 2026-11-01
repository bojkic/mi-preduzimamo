# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "active_support/all"
require "active_support/cache/redis_cache_store"
require "tmpdir"
require_relative "../../../../app/services/decidim_app/bijeljina/city_source_request_policy"

module DecidimApp
  module Bijeljina
    class CitySourceRequestPolicyTest < Minitest::Test
      Response = Struct.new(:code, :body, :headers) do
        def [](name) = (headers || {})[name]
      end

      # Models the cache operations used in production (Redis NX/EX, INCR),
      # including expiry and contention across separate policy instances.
      class Cache
        attr_reader :writes

        def initialize(clock)
          @clock = clock
          @rows = {}
          @mutex = Mutex.new
          @writes = []
        end

        def read(key, **)
          @mutex.synchronize { current(key)&.first }
        end

        def write(key, value, expires_in:, unless_exist: false, **)
          @mutex.synchronize do
            @writes << { key:, expires_in:, unless_exist: }
            return false if unless_exist && current(key)

            @rows[key] = [value, @clock.call + expires_in]
            true
          end
        end

        def increment(key, amount, expires_in:)
          @mutex.synchronize do
            value = current(key)&.first.to_i + amount
            @rows[key] = [value, @clock.call + expires_in]
            value
          end
        end

        def delete(key)
          @mutex.synchronize { @rows.delete(key) }
        end

        private

        def current(key)
          row = @rows[key]
          row if row && row.last > @clock.call
        end
      end

      def setup
        @time = Time.utc(2026, 9, 15, 12).to_f
        @cache = Cache.new(-> { @time })
        @fetches = []
        @response = Response.new("200", "User-agent: *\nDisallow: /private\n")
        @policy = build_policy
      end

      def test_honest_identification_and_bounded_cached_robots_with_pacing
        first = @policy.before_request(uri, timeout: 8)
        assert_in_delta 6.99, first, 0.001
        assert_equal 1, @fetches.size
        assert_equal "https://source.test/robots.txt", @fetches.first[0].to_s
        assert_equal CitySourceRequestPolicy::ROBOTS_MAX_BYTES, @fetches.first[1][:max_bytes]
        assert_includes CitySourceRequestPolicy::USER_AGENT, "MilicaSourceCollector"
        assert_equal false, CitySourceRequestPolicy::USER_AGENT.include?("Chrome")
        @policy.before_request(uri, timeout: 8)
        assert_equal 1, @fetches.size
        assert(@cache.writes.any? { |write| write[:unless_exist] && write[:expires_in] == 1 })
      end

      def test_expiry_jitter_does_not_turn_a_past_pacing_timestamp_into_host_failure
        @policy.before_request(uri, timeout: 8)
        key = @cache.writes.find { |write| write[:unless_exist] }.fetch(:key)
        @cache.write(key, @time - 0.001, expires_in: 0.005)
        remaining = @policy.before_request(uri, timeout: 8)
        assert_operator remaining, :>, 7.9
      end

      def test_agent_groups_merge_override_wildcard_and_keep_empty_group_separate
        rules = "User-agent: *\nDisallow: /\nUser-agent: MilicaSourceCollector\nDisallow:\nUser-agent: OtherBot\nDisallow: /\n"
        assert allowed?(rules, "/public")
        rules = "User-agent: *\nDisallow: /\nUser-agent: MILICASOURCECOLLECTOR\nDisallow: /one\nUser-agent: MilicaSourceCollector\nDisallow: /two\n"
        assert_equal false, allowed?(rules, "/one")
        assert_equal false, allowed?(rules, "/two")
        assert allowed?(rules, "/public")
      end

      def test_longest_path_allow_tie_wildcards_and_end_anchor
        rules = "User-agent: *\nDisallow: /private\nAllow: /private/public\nDisallow: /*.pdf$\nAllow: /ok.pdf$\n"
        assert_equal false, allowed?(rules, "/private/a")
        assert allowed?(rules, "/private/public/a")
        assert_equal false, allowed?(rules, "/a.pdf")
        assert allowed?(rules, "/a.pdf?download=1")
        assert allowed?(rules, "/ok.pdf")
        assert allowed?("User-agent: *\nDisallow: /same\nAllow: /same", "/same")
      end

      def test_percent_encoding_cannot_bypass_a_rule_and_reserved_slash_stays_distinct
        rules = "User-agent: *\nDisallow: /private\nDisallow: /put/ča\nDisallow: /path%2Fencoded\n"
        assert_equal false, allowed?(rules, "/%70rivate")
        assert_equal false, allowed?(rules, "/put/%C4%8Da")
        assert_equal false, allowed?(rules, "/path%2fencoded")
        assert allowed?(rules, "/path/encoded")
      end

      def test_disallowed_path_stops_before_content_request
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(uri("/private"), timeout: 8) }
        assert_equal :robots_disallowed, error.code
        assert_equal 1, @fetches.size
      end

      def test_comments_only_and_missing_robots_are_not_licence_decisions
        @response = Response.new("200", "# content signal definitions only\n")
        assert_operator @policy.before_request(uri, timeout: 8), :>, 0
        @response = Response.new("404", "not found")
        assert_operator @policy.before_request(URI("https://other.test/public"), timeout: 8), :>, 0
      end

      def test_active_ai_input_restriction_is_distinct_from_comments_or_training
        @response = Response.new("200", "User-agent: *\nContent-Signal: search=yes, ai-input=no\nAllow: /\n")
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(uri, timeout: 8) }
        assert_equal :source_ai_input_disallowed, error.code
        @response = Response.new("200", "User-agent: *\nContent-Signal: ai-train=no\nAllow: /\n")
        assert_operator @policy.before_request(URI("https://other.test/public"), timeout: 8), :>, 0
      end

      def test_robots_errors_and_template_pages_do_not_mean_allowed
        [["403", "", :source_provider_blocked], ["500", "", :robots_unavailable],
         ["200", "<html>maintenance</html>", :robots_invalid_document], ["302", "", :robots_unavailable]].each_with_index do |(code, body, expected), index|
          @response = Response.new(code, body)
          error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(URI("https://host#{index}.test/public"), timeout: 8) }
          assert_equal expected, error.code
        end
      end

      # Explicit HTTP refusals are distinct from network failures.
      def test_a_site_blocking_the_collector_is_left_alone_for_a_day
        [["403", ""], ["447", ""]].each_with_index do |(code, body), index|
          @response = Response.new(code, body)
          target = URI("https://blocked#{index}.test/public")
          error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(target, timeout: 8) }
          assert_equal :source_provider_blocked, error.code
          assert_in_delta @time + 86_400, error.retry_at.to_f, 1

          fetches = @fetches.size
          @time += 23 * 3600
          again = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(target, timeout: 8) }
          assert_equal :source_provider_blocked, again.code
          assert_equal fetches, @fetches.size, "a blocked host must not be contacted again within the day"

          @time += 2 * 3600
          @response = Response.new("404", "")
          assert_operator @policy.before_request(target, timeout: 8), :>, 0
        end
      end

      def test_a_refused_connection_is_unreachable_with_short_backoff
        policy = build_policy(fetcher: ->(*) { raise Errno::ECONNREFUSED })
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { policy.before_request(uri, timeout: 8) }
        assert_equal :source_unreachable, error.code
        assert_in_delta @time + 60, error.retry_at.to_f, 1
        again = assert_raises(CitySourceRequestPolicy::PolicyError) { policy.before_request(uri, timeout: 8) }
        assert_equal :source_unreachable, again.code
      end

      def test_network_robots_failure_stays_bounded_and_is_unreachable
        policy = build_policy(fetcher: ->(*) { raise Timeout::Error })
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { policy.before_request(uri, timeout: 8) }
        assert_equal :source_unreachable, error.code
      end

      def test_robots_payload_limit_is_enforced_for_injected_fetches_too
        @response = Response.new("200", "x" * (CitySourceRequestPolicy::ROBOTS_MAX_BYTES + 1))
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(uri, timeout: 8) }
        assert_equal :robots_oversized, error.code
      end

      def test_backoff_retry_after_and_circuit_recovery_are_shared_across_workers
        @policy.before_request(uri, timeout: 8)
        error = assert_raises(CitySourceRequestPolicy::PolicyError) do
          @policy.observe_response(uri, Response.new("429", "", { "retry-after" => "120" }))
        end
        assert_equal @time + 120, error.retry_at.to_f
        second_worker = build_policy
        assert_raises(CitySourceRequestPolicy::PolicyError) { second_worker.before_request(uri, timeout: 8) }
        assert_equal 1, @fetches.size
        @time += 121
        assert_operator second_worker.before_request(uri, timeout: 8), :>, 0
        second_worker.observe_response(uri, Response.new("200", "quiet valid feed"))
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.observe_response(uri, Response.new("503", "")) }
        assert_equal @time + 60, error.retry_at.to_f
      end

      def test_an_older_inflight_success_cannot_clear_newer_backoff
        assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.observe_response(uri, Response.new("503", "")) }
        @policy.observe_response(uri, Response.new("200", "old request"))
        assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(uri, timeout: 8) }
      end

      def test_backoff_is_per_host_and_date_retry_after_is_bounded
        target = Time.at(@time + 90).utc.httpdate
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.observe_response(uri, Response.new("503", "", { "retry-after" => target })) }
        assert_equal @time + 90, error.retry_at.to_f
        assert_operator @policy.before_request(URI("https://other.test/public"), timeout: 8), :>, 0
        assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(URI("http://source.test/public"), timeout: 8) }
      end

      def test_pacing_and_robots_cannot_extend_the_passed_deadline
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(uri, timeout: 0.5) }
        assert_equal :source_host_busy, error.code
        assert_equal 1, @fetches.size
        assert_equal Time.utc(2026, 9, 15, 12).to_f, @time
      end

      def test_http_and_https_robots_are_separate_policies
        @policy.before_request(uri, timeout: 8)
        @policy.before_request(URI("http://source.test/public"), timeout: 8)
        assert_equal 2, @fetches.size
      end

      def test_real_robots_transport_keeps_tls_identity_and_body_limit
        response = Net::HTTPOK.new("1.1", "200", "OK")
        response.define_singleton_method(:read_body) { |&block| block.call("User-agent: *\nAllow: /\n") }
        response.define_singleton_method(:body) { "User-agent: *\nAllow: /\n" }
        requested = []
        options_seen = []
        http = Object.new
        http.define_singleton_method(:request) do |request, &block|
          requested << request
          block.call(response)
        end
        starter = lambda do |host, port, **options, &block|
          assert_equal "source.test", host
          assert_equal 443, port
          options_seen << options
          block.call(http)
        end
        policy = CitySourceRequestPolicy.new(cache: @cache, clock: -> { Time.at(@time).utc }, monotonic: -> { @time },
                                             sleeper: ->(seconds) { @time += seconds })
        Net::HTTP.stub(:start, starter) { policy.before_request(uri, timeout: 8) }
        assert_equal true, options_seen.first[:use_ssl]
        assert_equal CitySourceRequestPolicy::USER_AGENT, requested.first["User-Agent"]
        assert_equal "/robots.txt", requested.first.path
        error = Net::HTTP.stub(:start, starter) do
          assert_raises(CitySourceRequestPolicy::PolicyError) { policy.send(:fetch_robots, uri("/robots.txt"), timeout: 8, max_bytes: 4) }
        end
        assert_equal :robots_oversized, error.code
      end

      def test_authority_credentials_and_unknown_schemes_are_rejected
        ["https://user:password@source.test/public", "file:///tmp/x"].each do |url|
          assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(URI(url), timeout: 8) }
        end
        assert_empty @fetches
      end

      def test_utf8_bom_preserves_the_first_disallow_group
        @response = Response.new("200", "\uFEFFUser-agent: *\nDisallow: /\n")
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(uri, timeout: 8) }
        assert_equal :robots_disallowed, error.code
        assert_equal false, allowed?(@response.body, "/public")
      end

      def test_invalid_utf8_is_a_cached_typed_refusal
        @response = Response.new("200", "\xFF".dup.force_encoding("UTF-8"))
        2.times do
          error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(uri, timeout: 8) }
          assert_equal :robots_invalid_document, error.code
        end
        assert_equal 1, @fetches.size
      end

      def test_a_shorter_inflight_failure_cannot_shorten_the_existing_circuit
        long = assert_raises(CitySourceRequestPolicy::PolicyError) do
          @policy.observe_response(uri, Response.new("429", "", { "retry-after" => "3600" }))
        end
        short = assert_raises(CitySourceRequestPolicy::PolicyError) do
          build_policy.observe_response(uri, Response.new("503", "", { "retry-after" => "10" }))
        end
        assert_equal long.retry_at, short.retry_at
        @time += 11
        assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.before_request(uri, timeout: 8) }
      end

      def test_null_cache_refuses_before_network_and_cannot_swallow_a_circuit
        policy = CitySourceRequestPolicy.new(cache: ActiveSupport::Cache::NullStore.new,
                                             robots_fetcher: ->(*) { flunk "null-cache policy fetched robots" })
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { policy.before_request(uri, timeout: 8) }
        assert_equal :source_policy_cache_unavailable, error.code
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { policy.observe_response(uri, Response.new("429", "")) }
        assert_equal :source_policy_cache_unavailable, error.code
      end

      def test_legacy_serialized_backoff_is_preserved_when_new_atomic_key_is_used
        key = @policy.send(:key, uri, "backoff")
        @cache.write(key, @time + 3600, expires_in: 3600)
        error = assert_raises(CitySourceRequestPolicy::PolicyError) { @policy.observe_response(uri, Response.new("429", "", { "retry-after" => "10" })) }
        assert_equal @time + 3600, error.retry_at.to_f
      end

      def test_redis_atomic_circuit_preserves_namespace_and_bypasses_cached_nil
        with_isolated_redis do |socket|
          stores = [true, false].map do |pool|
            ActiveSupport::Cache::RedisCacheStore.new(redis: -> { Redis.new(url: "unix://#{socket}") }, namespace: -> { "policy-test:A" }, pool:)
          end
          policies = stores.map { |cache| CitySourceRequestPolicy.new(cache:, clock: -> { Time.at(@time).utc }) }
          raw_key = @policy.send(:key, uri, "backoff_until")
          stores.first.with_local_cache do
            assert_nil stores.first.read(raw_key, raw: true)
            error = assert_raises(CitySourceRequestPolicy::PolicyError) do
              policies.first.observe_response(uri, Response.new("429", "", { "retry-after" => "3600" }))
            end
            short = assert_raises(CitySourceRequestPolicy::PolicyError) do
              policies.last.observe_response(uri, Response.new("503", "", { "retry-after" => "10" }))
            end
            assert_equal error.retry_at, short.retry_at
            # The cache middleware still has its prior miss, but acquisition
            # must consult the authoritative Redis circuit, not that miss.
            assert_nil stores.first.read(raw_key, raw: true)
            @time += 11
            assert_raises(CitySourceRequestPolicy::PolicyError) { policies.first.before_request(uri, timeout: 8) }
          end
          client = Redis.new(url: "unix://#{socket}")
          assert_equal (@time - 11 + 3600).to_f, client.get("policy-test:A:#{raw_key}").to_f
          assert_nil client.get(raw_key)
          assert_operator client.pttl("policy-test:A:#{raw_key}"), :>, 3_590_000
          other = ActiveSupport::Cache::RedisCacheStore.new(redis: client, namespace: "policy-test:B", pool: false)
          assert_equal 0, CitySourceRequestPolicy.new(cache: other).send(:backoff_until, uri)
        end
      end

      def test_redis_concurrent_cooldowns_and_recovery_do_not_erase_newer_failures
        with_isolated_redis do |socket|
          cache = ActiveSupport::Cache::RedisCacheStore.new(redis: -> { Redis.new(url: "unix://#{socket}") }, namespace: "policy-test:concurrency")
          policies = 8.times.map { CitySourceRequestPolicy.new(cache:, clock: -> { Time.at(@time).utc }) }
          threads = policies.each_with_index.map do |policy, index|
            Thread.new do
              policy.observe_response(uri, Response.new("503", "", { "retry-after" => ((index + 1) * 100).to_s }))
            rescue CitySourceRequestPolicy::PolicyError => e
              e.code
            end
          end
          assert_equal [:source_host_backoff], threads.map(&:value).uniq
          policy = policies.first
          assert_equal @time + 800, policy.send(:backoff_until, uri)
          # Force the pre-Lua read to race as an older success would. Lua sees
          # the newer circuit and retains its failure history atomically.
          policy.stub(:backoff_until, 0.0) { policy.observe_response(uri, Response.new("200", "older request")) }
          assert_equal 8, cache.read(policy.send(:key, uri, "failures"), raw: true).to_i
          @time += 801
          policy.observe_response(uri, Response.new("200", "recovered"))
          assert_nil cache.read(policy.send(:key, uri, "failures"), raw: true)
          error = assert_raises(CitySourceRequestPolicy::PolicyError) { policy.observe_response(uri, Response.new("503", "")) }
          assert_equal @time + 60, error.retry_at.to_f
        end
      end

      def test_default_does_not_keep_a_previous_null_store_after_cache_configuration_changes
        created_rails = !Object.const_defined?(:Rails)
        Object.const_set(:Rails, Module.new) if created_rails
        created_cache_method = !Rails.respond_to?(:cache)
        Rails.define_singleton_method(:cache) { nil } if created_cache_method
        previous = CitySourceRequestPolicy.instance_variable_get(:@default)
        previous_cache = CitySourceRequestPolicy.instance_variable_get(:@default_cache)
        first = Rails.stub(:cache, ActiveSupport::Cache::NullStore.new) { CitySourceRequestPolicy.default }
        second = Rails.stub(:cache, @cache) { CitySourceRequestPolicy.default }
        assert_equal false, first.equal?(second)
        assert_same @cache, second.instance_variable_get(:@cache)
      ensure
        CitySourceRequestPolicy.instance_variable_set(:@default, previous)
        CitySourceRequestPolicy.instance_variable_set(:@default_cache, previous_cache)
        Rails.singleton_class.send(:remove_method, :cache) if created_cache_method
        Object.send(:remove_const, :Rails) if created_rails
      end

      private

      def with_isolated_redis
        # Never read Redis URLs/configuration or contact the host's Redis. This
        # disposable process accepts only its unique Unix socket and persists
        # nothing; cleanup targets just the process/directory created here.
        Dir.mktmpdir("milica-policy-test-") do |directory|
          socket = File.join(directory, "redis.sock")
          pid = Process.spawn("redis-server", "--port", "0", "--unixsocket", socket, "--save", "", "--appendonly", "no",
                              "--dir", directory, out: File::NULL, err: File::NULL)
          100.times do
            break if File.socket?(socket)

            sleep 0.01
          end
          raise "isolated Redis did not start" unless File.socket?(socket)

          yield socket
        ensure
          Process.kill("TERM", pid) if pid
          Process.wait(pid) if pid
        end
      end

      def uri(path = "/public") = URI("https://source.test#{path}")

      def allowed?(body, path) = CitySourceRequestPolicy::RobotsRules.new(body).allowed?(path)

      def build_policy(fetcher: nil)
        fetcher ||= lambda do |url, **options|
          @fetches << [url, options]
          @response
        end
        CitySourceRequestPolicy.new(cache: @cache, robots_fetcher: fetcher, clock: -> { Time.at(@time).utc },
                                    monotonic: -> { @time }, sleeper: ->(seconds) { @time += seconds })
      end
    end
  end
end
