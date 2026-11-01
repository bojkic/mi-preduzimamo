# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Unit tests for the durable integration-health subscriber. The store is
    # injectable so these tests never touch Redis: we pass an in-memory store
    # (Decidim::Bih::IntegrationHealth::MemoryStore) instead. The production
    # default is a Redis-backed store (mirroring Viber::OtpStore's REDIS_URL).
    class IntegrationHealthTest < ActiveSupport::TestCase
      setup do
        @store = Decidim::Bih::IntegrationHealth::MemoryStore.new
        @health = Decidim::Bih::IntegrationHealth.new(store: @store)
      end

      test "records a success event keyed by provider and organization" do
        @health.record(
          "decidim_bih.gemini.generate_content",
          { provider: "gemini", organization_id: 42, success: true, http_status: 200 }
        )

        state = @health.state(provider: "gemini", organization_id: 42)
        assert_not_nil state[:last_success_at]
        assert_nil state[:last_error_at]
        assert_equal 1, state[:success_count]
        assert_equal 0, state[:failure_count]
      end

      test "records a failure event with the scrubbed error class and http status" do
        @health.record(
          "decidim_bih.infobip.request",
          { provider: "infobip", success: false, http_status: 401, error_class: "Decidim::Bih::Infobip::Error" }
        )

        state = @health.state(provider: "infobip")
        assert_nil state[:last_success_at]
        assert_not_nil state[:last_error_at]
        assert_equal "401", state[:last_error_code].to_s
        assert_equal "Decidim::Bih::Infobip::Error", state[:last_error_class]
        assert_equal 0, state[:success_count]
        assert_equal 1, state[:failure_count]
      end

      test "derives the provider from the event name when no provider key is present" do
        # report_processing emits no :provider key; the suffix's first segment is
        # the provider bucket ("report_processing").
        @health.record(
          "decidim_bih.report_processing",
          { organization_id: 7, success: true, report_id: 99 }
        )

        state = @health.state(provider: "report_processing", organization_id: 7)
        assert_equal 1, state[:success_count]
      end

      test "never stores raw messages — only scrubbed metadata" do
        @health.record(
          "decidim_bih.infobip.request",
          {
            provider: "infobip",
            success: false,
            error_class: "Decidim::Bih::Infobip::Error",
            exception: ["RuntimeError", "Send failed for +38765111222 token=secret-key"],
            path: "/sms/2/text/advanced"
          }
        )

        serialized = @store.dump.to_json
        assert_not_includes serialized, "38765111222"
        assert_not_includes serialized, "secret-key"
      end

      test "a store failure never propagates out of record" do
        broken = Object.new
        broken.define_singleton_method(:record_success) { |*| raise "redis down" }
        broken.define_singleton_method(:record_failure) { |*| raise "redis down" }
        health = Decidim::Bih::IntegrationHealth.new(store: broken)

        assert_nothing_raised do
          health.record("decidim_bih.gemini.generate_content", { provider: "gemini", success: true })
        end
      end

      test "state returns a safe empty shape for an unseen provider" do
        state = @health.state(provider: "odoo")
        assert_nil state[:last_success_at]
        assert_nil state[:last_error_at]
        assert_equal 0, state[:success_count]
        assert_equal 0, state[:failure_count]
      end

      test "a recent success summarises as ok" do
        @health.record("decidim_bih.gemini.generate_content", { provider: "gemini", success: true })
        state = @health.state(provider: "gemini")
        assert_equal :ok, state[:status]
      end

      test "a recent failure summarises as failing" do
        @health.record(
          "decidim_bih.gemini.generate_content",
          { provider: "gemini", success: false, http_status: 503, error_class: "Decidim::Bih::Ai::Error" }
        )
        state = @health.state(provider: "gemini")
        assert_equal :failing, state[:status]
      end

      test "an unseen provider summarises as unknown" do
        assert_equal :unknown, @health.state(provider: "odoo")[:status]
      end

      test "an old observation summarises as stale" do
        travel_to(Decidim::Bih::IntegrationHealth::RECENT_WINDOW.seconds.ago - 1.second) do
          @health.record("decidim_bih.gemini.generate_content", { provider: "gemini", success: true })
        end

        state = @health.state(provider: "gemini")
        assert_equal :stale, state[:status]
        assert_not_nil state[:observed_at]
      end
    end
  end
end
