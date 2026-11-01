# frozen_string_literal: true

require "digest"
require "net/http"
require "openssl"
require "time"
require "timeout"
require "uri"

module DecidimApp
  module Bijeljina
    # Background network admission only. Robots controls crawling, not licensing
    # or editorial readiness. Cache writes use Redis SET NX + expiry for pacing;
    # backoff failure counters use the cache's atomic increment operation.
    class CitySourceRequestPolicy
      PRODUCT = "MilicaSourceCollector"
      USER_AGENT = "#{PRODUCT}/1.0 (public civic information)".freeze
      ROBOTS_MAX_BYTES = 524_288
      ROBOTS_TTL = 21_600
      FAILURE_TTL = 300
      MIN_INTERVAL = 1.0
      MAX_BACKOFF = 86_400
      # Explicit HTTP refusals are retried once a day; network failures use
      # the shorter ordinary host backoff.
      PROVIDER_BLOCK_BACKOFF = 86_400
      LOCAL_BACKOFF_LOCK = Mutex.new
      MAX_COOLDOWN = <<~LUA
        local previous = tonumber(redis.call('GET', KEYS[1]) or '0')
        local deadline = math.max(previous, tonumber(ARGV[1]))
        local ttl = math.max(1, math.ceil((deadline - tonumber(ARGV[2])) * 1000))
        redis.call('SET', KEYS[1], tostring(deadline), 'PX', ttl)
        return tostring(deadline)
      LUA
      READ_COOLDOWN = "return redis.call('GET', KEYS[1])"
      CLEAR_RECOVERED_FAILURES = <<~LUA
        local deadline = tonumber(redis.call('GET', KEYS[1]) or '0')
        if deadline <= tonumber(ARGV[1]) then
          redis.call('DEL', KEYS[2])
        end
        return 1
      LUA

      class PolicyError < StandardError
        attr_reader :code, :retry_at

        def initialize(code, retry_at: nil)
          @code = code
          @retry_at = retry_at
          super(code.to_s)
        end
      end

      # Optional identity of the operator running this collector, never the
      # upstream project maintainer. Invalid input produces no From header.
      def self.contact_email(environment = ENV)
        value = environment["MI_SOURCE_CONTACT_EMAIL"]
        return unless value.is_a?(String) && value.valid_encoding? && value.ascii_only? && value.bytesize.between?(3, 254)
        return if value.match?(/[\x00-\x20\x7f]/) || !URI::MailTo::EMAIL_REGEXP.match?(value)
        return unless value.split("@", 2).last.include?(".")

        value.dup.freeze
      end

      def self.default
        cache = Rails.cache
        return @default if @default && @default_cache.equal?(cache)

        @default_cache = cache
        @default = new(cache:)
      end

      def initialize(cache:, robots_fetcher: nil, clock: -> { Time.now.utc },
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) })
        @cache = cache
        @robots_fetcher = robots_fetcher || method(:fetch_robots)
        @clock = clock
        @monotonic = monotonic
        @sleeper = sleeper
      end

      # Returns the remaining network budget after robots and pacing, so callers
      # cannot accidentally extend their existing outer deadline.
      def before_request(uri, timeout:)
        assert_cache!
        uri = validated_uri(uri)
        expires = @monotonic.call + Float(timeout)
        check_backoff!(uri)
        robots = robots_for(uri, expires)
        raise PolicyError, robots.fetch("error").to_sym if robots["error"]

        rules = RobotsRules.new(robots.fetch("body"))
        raise PolicyError, :source_ai_input_disallowed if rules.ai_input_disallowed?
        raise PolicyError, :robots_disallowed unless rules.allowed?(uri.request_uri)

        reserve_request!(uri, expires)
        remaining!(expires)
      end

      def observe_response(uri, response)
        assert_cache!
        uri = validated_uri(uri)
        status = response.code.to_i
        if [429, 503].include?(status)
          failures = @cache.increment(key(uri, "failures"), 1, expires_in: MAX_BACKOFF).to_i.clamp(1, 10)
          seconds = retry_seconds(response["retry-after"]) || [60 * (2**(failures - 1)), 3600].min
          retry_at = extend_backoff(uri, @clock.call.to_f + seconds)
          raise PolicyError.new(:source_host_backoff, retry_at: Time.at(retry_at).utc)
        end
        if status.between?(200, 299)
          clear_recovered_failures(uri)
          @cache.delete(key(uri, "unreachable"))
        end
      end

      private

      def assert_cache!
        null_cache = defined?(ActiveSupport::Cache::NullStore) && @cache.is_a?(ActiveSupport::Cache::NullStore)
        raise PolicyError, :source_policy_cache_unavailable if @cache.nil? || null_cache
      end

      def backoff_until(uri)
        # Retain an older serialized v1 circuit until its original expiry. New
        # circuits use a separate raw numeric key suitable for Redis Lua.
        if @cache.respond_to?(:redis)
          legacy = @cache.send(:bypass_local_cache) { @cache.read(key(uri, "backoff")) }
          current = redis_eval(READ_COOLDOWN, [key(uri, "backoff_until")], [])
        else
          legacy = @cache.read(key(uri, "backoff"))
          current = @cache.read(key(uri, "backoff_until"), raw: true)
        end
        [legacy, current].compact.map { |value| Float(value) }.max || 0.0
      end

      def extend_backoff(uri, proposed)
        if @cache.respond_to?(:redis)
          proposed = [proposed, backoff_until(uri)].max
          Float(redis_eval(MAX_COOLDOWN, [key(uri, "backoff_until")], [proposed, @clock.call.to_f]))
        else
          LOCAL_BACKOFF_LOCK.synchronize do
            deadline = [proposed, backoff_until(uri)].max
            written = @cache.write(key(uri, "backoff_until"), deadline, raw: true, expires_in: [deadline - @clock.call.to_f, 0.001].max)
            raise PolicyError, :source_policy_cache_unavailable unless written

            deadline
          end
        end
      end

      def clear_recovered_failures(uri)
        if @cache.respond_to?(:redis)
          return if backoff_until(uri) > @clock.call.to_f

          redis_eval(CLEAR_RECOVERED_FAILURES, [key(uri, "backoff_until"), key(uri, "failures")], [@clock.call.to_f])
        else
          LOCAL_BACKOFF_LOCK.synchronize { @cache.delete(key(uri, "failures")) if backoff_until(uri) <= @clock.call.to_f }
        end
        # Never read-then-delete a cooldown: an in-flight failure can extend it
        # between those operations. Its existing Redis/cache TTL handles expiry.
      end

      def redis_eval(script, keys, arguments)
        # Use RedisCacheStore's normalization, including namespace (or callable
        # namespace) and key truncation, exactly as its ordinary read/write do.
        normalized = keys.map { |name| @cache.send(:normalize_key, name, @cache.options) }
        connection = @cache.redis
        operation = ->(redis) { redis.eval(script, keys: normalized, argv: arguments) }
        connection.respond_to?(:with) ? connection.with(&operation) : operation.call(connection)
      rescue StandardError
        raise PolicyError, :source_policy_cache_unavailable
      end

      def validated_uri(value)
        uri = value.is_a?(URI) ? value : URI.parse(value.to_s)
        raise PolicyError, :invalid_source_authority unless %w(http https).include?(uri.scheme) && uri.host && uri.userinfo.nil?

        uri
      end

      def key(uri, kind)
        # Pacing/backoff share the host across its HTTP/HTTPS endpoints. Robots
        # remain exact-origin records; www and non-www are not policy aliases.
        "city-source-policy:v1:#{kind}:#{Digest::SHA256.hexdigest(uri.host.downcase)}"
      end

      def check_backoff!(uri)
        retry_at = backoff_until(uri)
        return unless retry_at > @clock.call.to_f

        code = if @cache.read(key(uri, "provider_block"))
                 :source_provider_blocked
               elsif @cache.read(key(uri, "unreachable"))
                 :source_unreachable
               else
                 :source_host_backoff
               end
        raise PolicyError.new(code, retry_at: Time.at(retry_at.to_f).utc)
      end

      def reserve_request!(uri, expires)
        4.times do
          remaining!(expires)
          check_backoff!(uri)
          return if @cache.write(key(uri, "pace"), @clock.call.to_f + MIN_INTERVAL, expires_in: MIN_INTERVAL, unless_exist: true)

          # The Redis TTL starts after serialization/network latency, slightly
          # later than the stored wall-clock deadline. Allow expiry jitter;
          # a past timestamp is not evidence that another crawler is busy.
          wait = [@cache.read(key(uri, "pace")).to_f - @clock.call.to_f, 0].max + 0.01
          raise PolicyError.new(:source_host_busy, retry_at: @clock.call + MIN_INTERVAL) unless wait.positive? && wait <= MIN_INTERVAL + 0.01 && wait < remaining!(expires)

          @sleeper.call(wait)
        end
        raise PolicyError.new(:source_host_busy, retry_at: @clock.call + MIN_INTERVAL)
      end

      def robots_for(uri, expires)
        url = URI.join("#{uri.scheme}://#{uri.host}:#{uri.port}", "/robots.txt")
        cache_key = "city-source-policy:v1:robots:#{Digest::SHA256.hexdigest(url.to_s)}"
        cached = @cache.read(cache_key)
        return cached if cached

        reserve_request!(uri, expires)
        response = @robots_fetcher.call(url, timeout: remaining!(expires), max_bytes: ROBOTS_MAX_BYTES)
        observe_response(uri, response)
        payload = robots_payload(response)
        block_provider!(uri) if payload["error"] == "source_provider_blocked"
        @cache.write(cache_key, payload, expires_in: payload["error"] ? FAILURE_TTL : ROBOTS_TTL)
        payload
      rescue PolicyError
        raise
      rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
        unreachable!(uri)
      end

      def robots_payload(response)
        return { "body" => "" } if [404, 410].include?(response.code.to_i)
        # 404/410 mean "no robots file" and 429 already raised a backoff; any
        # other 4xx here (403, and custom WAF codes such as 447) refuses us.
        return { "error" => "source_provider_blocked" } if response.code.to_i.between?(400, 499)
        return { "error" => "robots_unavailable" } unless response.code.to_i.between?(200, 299)

        body = response.body.to_s.dup.force_encoding("UTF-8")
        raise PolicyError, :robots_oversized if body.bytesize > ROBOTS_MAX_BYTES
        return { "error" => "robots_invalid_document" } unless body.valid_encoding?
        return { "error" => "robots_invalid_document" } if body.match?(/<(?:!doctype|html|body)\b/i)

        { "body" => body }
      end

      def block_provider!(uri)
        seconds = PROVIDER_BLOCK_BACKOFF
        @cache.write(key(uri, "provider_block"), true, expires_in: seconds)
        retry_at = extend_backoff(uri, @clock.call.to_f + seconds)
        raise PolicyError.new(:source_provider_blocked, retry_at: Time.at(retry_at).utc)
      end

      def unreachable!(uri)
        failures = @cache.increment(key(uri, "failures"), 1, expires_in: MAX_BACKOFF).to_i.clamp(1, 10)
        seconds = [60 * (2**(failures - 1)), 3600].min
        @cache.write(key(uri, "unreachable"), true, expires_in: seconds)
        retry_at = extend_backoff(uri, @clock.call.to_f + seconds)
        raise PolicyError.new(:source_unreachable, retry_at: Time.at(retry_at).utc)
      end

      def fetch_robots(uri, timeout:, max_bytes:)
        # Deliberately no redirect following: another robots authority must not
        # silently supply policy for this host. Changed endpoints require review.
        Timeout.timeout(timeout) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout) do |http|
            http.request(Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT, "Accept" => "text/plain")) do |response|
              body = +""
              response.read_body do |chunk|
                raise PolicyError, :robots_oversized if body.bytesize + chunk.bytesize > max_bytes

                body << chunk
              end
              response.body = body
              return response
            end
          end
        end
      end

      def retry_seconds(value)
        text = value.to_s.strip
        seconds = text.match?(/\A\d+\z/) ? text.to_i : Time.httpdate(text).to_f - @clock.call.to_f
        seconds.clamp(1, MAX_BACKOFF)
      rescue ArgumentError
        nil
      end

      def remaining!(expires)
        seconds = expires - @monotonic.call
        raise PolicyError, :source_policy_deadline unless seconds.positive?

        seconds
      end

      # Bounded UTF-8 robots parser: exact product groups override wildcard;
      # groups for the same product combine; longest matching path wins and
      # Allow wins ties. Unreserved percent encoding is normalized both ways.
      class RobotsRules
        def initialize(body)
          @groups = []
          group = { agents: [], rules: [], started_rules: false, ai_input_disallowed: false }
          body.delete_prefix("\uFEFF").each_line do |line|
            name, value = line.sub(/#.*/, "").strip.split(":", 2)
            next unless name && value

            if name.downcase == "user-agent"
              if group[:started_rules]
                @groups << group
                group = { agents: [], rules: [], started_rules: false, ai_input_disallowed: false }
              end
              group[:agents] << value.strip.downcase
            else
              apply_rule(group, name.downcase, value.strip)
            end
          end
          @groups << group
        end

        def allowed?(path)
          matches = applicable_groups.flat_map { |group| group[:rules] }.select { |_, rule| match?(rule, path) }
          winner = matches.max_by { |action, rule| [normalize(rule).bytesize, action == "allow" ? 1 : 0] }
          winner.nil? || winner.first == "allow"
        end

        def ai_input_disallowed?
          applicable_groups.any? { |group| group[:ai_input_disallowed] }
        end

        private

        def apply_rule(group, name, value)
          return if group[:agents].empty?

          case name
          when "content-signal"
            group[:started_rules] = true
            group[:ai_input_disallowed] ||= value.downcase.split(",").map(&:strip).include?("ai-input=no")
          when "allow", "disallow"
            group[:started_rules] = true
            group[:rules] << [name, value] unless value.empty?
          end
        end

        def applicable_groups
          groups = @groups.select { |group| group[:agents].include?(PRODUCT.downcase) }
          groups.empty? ? @groups.select { |group| group[:agents].include?("*") } : groups
        end

        def normalize(text)
          decoded = text.gsub(/%[0-9a-f]{2}/i) do |encoded|
            character = encoded[1..].to_i(16).chr
            character.match?(/[a-z0-9_.~-]/i) ? character : encoded.upcase
          end
          decoded.bytes.map { |byte| byte > 127 ? format("%%%02X", byte) : byte.chr }.join
        end

        def match?(rule, path)
          pattern = Regexp.escape(normalize(rule)).gsub('\\*', ".*").sub(/\\\$\z/, "\\z")
          Regexp.new("\\A#{pattern}").match?(normalize(path))
        end
      end
    end
  end
end
