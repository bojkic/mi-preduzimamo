# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Pins the wiring between the Decidim::Bih::Instrumentation event stream and
    # the durable IntegrationHealth subscriber: the engine installs a subscriber
    # (idempotently) that folds metadata-only events into the per-provider health
    # record. Uses an injected MemoryStore so no Redis is required.
    class IntegrationHealthSubscriberTest < ActiveSupport::TestCase
      setup do
        @store = Decidim::Bih::IntegrationHealth::MemoryStore.new
        Decidim::Bih::IntegrationHealth.instance =
          Decidim::Bih::IntegrationHealth.new(store: @store)
      end

      teardown do
        Decidim::Bih::IntegrationHealth.reset!
      end

      test "the engine has installed a listener for the integration topics" do
        Decidim::Bih::IntegrationHealth::TOPICS.each do |topic|
          assert ActiveSupport::Notifications.notifier.listening?(topic),
                 "nothing is subscribed to #{topic} — integration health is dark"
        end
      end

      # The real provider clients emit via ActiveSupport::Notifications.instrument
      # (start/finish), so these simulate events the same way — the subscriber is
      # subscribed for that path.
      test "an instrumented success event is folded into the health record" do
        ActiveSupport::Notifications.instrument(
          "decidim_bih.odoo.rpc", provider: "odoo", success: true, http_status: 200
        ) { nil }

        state = Decidim::Bih::IntegrationHealth.instance.state(provider: "odoo")
        assert_equal :ok, state[:status]
        assert_equal 1, state[:success_count]
      end

      test "an instrumented failure event is folded with its scrubbed code" do
        ActiveSupport::Notifications.instrument(
          "decidim_bih.infobip.request",
          provider: "infobip", success: false, http_status: 401, error_class: "Decidim::Bih::Infobip::Error"
        ) { nil }

        state = Decidim::Bih::IntegrationHealth.instance.state(provider: "infobip")
        assert_equal :failing, state[:status]
        assert_equal "401", state[:last_error_code].to_s
      end

      test "install! is idempotent — calling it again does not double-record" do
        Decidim::Bih::IntegrationHealth.install!

        ActiveSupport::Notifications.instrument(
          "decidim_bih.gemini.generate_content", provider: "gemini", success: true
        ) { nil }

        state = Decidim::Bih::IntegrationHealth.instance.state(provider: "gemini")
        # Exactly one record despite the engine's install + the explicit re-install.
        assert_equal 1, state[:success_count]
      end
    end
  end
end
