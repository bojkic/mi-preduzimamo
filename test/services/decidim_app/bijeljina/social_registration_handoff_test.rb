# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class SocialRegistrationHandoffTest < ActiveSupport::TestCase
      Organization = Struct.new(:id, :host)

      FakeRoutes = Struct.new(:destination) do
        def recognize_path(*) = destination
      end

      class FakeRedis
        attr_reader :values

        def initialize
          @values = {}
        end

        def set(key, value, **options)
          return false if options.fetch(:nx) && values.has_key?(key)

          raise "missing expiry" unless options.fetch(:ex).between?(1, SocialRegistrationHandoff::TTL.to_i)

          values[key] = value
          "OK"
        end

        def get(key) = values[key]

        def eval(_script, keys:, argv:)
          key = keys.fetch(0)
          return nil unless values[key] == argv.fetch(0)

          values.delete(key)
        end
      end

      setup do
        @now = Time.utc(2026, 9, 5, 12, 0, 0)
        @organization = Organization.new(42, "mi.example.org")
        @other_organization = Organization.new(43, "other.example.org")
        @redis = FakeRedis.new
        @store = SocialRegistrationHandoff.new(
          redis: @redis,
          secret: "s" * 64,
          clock: -> { @now },
          url_builder: ->(organization, token) { "https://#{organization.host}/registracija/drustvene-mreze?social_handoff=#{token}" }
        )
      end

      test "issue returns an opaque URL and stores only an HMAC key plus encrypted payload" do
        url = with_available { issue }
        key, ciphertext = @redis.values.first

        assert_match(%r{\Ahttps://mi\.example\.org/registracija/drustvene-mreze\?social_handoff=[A-Za-z0-9_-]{40,64}\z}, url)
        assert_match(/\Ami:social-registration-handoff:[0-9a-f]{64}\z/, key)
        [url, key, ciphertext].each do |value|
          assert_not_includes value, "+38765123456"
          assert_not_includes value, "provider-sender-123"
        end
      end

      test "GET-style peek does not consume and correct organization claims exactly once" do
        token = token_from(with_available { issue })

        assert_equal "+38765123456", @store.peek(token:, organization: @organization).fetch("phone")
        assert_equal 1, @redis.values.size
        assert_equal "+38765123456", @store.claim(token:, organization: @organization).fetch("phone")
        assert_empty @redis.values
        assert_nil @store.claim(token:, organization: @organization)
      end

      test "wrong organization cannot inspect or burn the intended handoff" do
        token = token_from(with_available { issue })

        assert_nil @store.peek(token:, organization: @other_organization)
        assert_nil @store.claim(token:, organization: @other_organization)
        assert_equal "+38765123456", @store.claim(token:, organization: @organization).fetch("phone")
      end

      test "expired payload and unsupported channels fail closed" do
        token = token_from(with_available { issue })
        @now += 11.minutes

        assert_nil @store.peek(token:, organization: @organization)
        assert_raises(ArgumentError) { with_available { issue(channel: "whatsapp") } }
      end

      test "a durable inbound transaction defers the Redis write" do
        capture = Decidim::Bih::DurableEffects.capture { with_available { issue } }

        assert_empty @redis.values
        assert_equal(["redis_set"], capture.effects.map { |effect| effect.fetch("type") })
        Decidim::Bih::DurableEffects.dispatch!(capture.effects.first, redis: @redis)
        assert_equal 1, @redis.values.size
      end

      test "issue fails closed when Redis does not accept the write" do
        Decidim::Bih::DurableEffects.stub(:redis_set, nil) do
          assert_raises(SocialRegistrationHandoff::Unavailable) { with_available { issue } }
        end
      end

      test "availability is disabled by default without probing Redis" do
        previous = ENV.delete("MI_SOCIAL_REGISTRATION_ENABLED")
        assert_not SocialRegistrationHandoff.available?
      ensure
        ENV["MI_SOCIAL_REGISTRATION_ENABLED"] = previous if previous
      end

      test "availability requires the canonical registration config and route" do
        with_enabled_flag do
          SocialRegistrationHandoff.stub(:registration_components_available?, true) do
            Decidim::Bih.stub(:registration_path, "/users/sign_up") do
              assert_not SocialRegistrationHandoff.available?(routes: FakeRoutes.new({}))
            end
            Decidim::Bih.stub(:registration_path, "/registracija") do
              wrong = { controller: "decidim/devise/registrations", action: "new" }
              assert_not SocialRegistrationHandoff.available?(routes: FakeRoutes.new(wrong))

              correct = { controller: "decidim/bih/registrations", action: "new" }
              assert SocialRegistrationHandoff.available?(routes: FakeRoutes.new(correct))
            end
          end
        end
      end

      private

      def issue(channel: "instagram")
        @store.issue(
          organization: @organization,
          channel:,
          sender: "provider-sender-123",
          phone: "065 123 456"
        )
      end

      def with_available(&)
        SocialRegistrationHandoff.stub(:available?, true, &)
      end

      def with_enabled_flag
        previous = ENV.fetch("MI_SOCIAL_REGISTRATION_ENABLED", nil)
        ENV["MI_SOCIAL_REGISTRATION_ENABLED"] = "true"
        yield
      ensure
        ENV["MI_SOCIAL_REGISTRATION_ENABLED"] = previous
      end

      def token_from(url)
        Rack::Utils.parse_query(URI(url).query).fetch("social_handoff")
      end
    end
  end
end
