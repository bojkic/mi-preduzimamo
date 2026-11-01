# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Tests for Config (A3): ENV reads, memoization, reset!, validate!
    class ConfigTest < ActiveSupport::TestCase
      teardown do
        Config.reset!
      end

      test "odoo reads the four expected ENV keys" do
        with_env("ODOO_URL" => "https://odoo.example.com",
                 "ODOO_DB" => "mydb",
                 "ODOO_LOGIN" => "admin@example.com",
                 "ODOO_API_KEY" => "abc123") do
          assert_equal "https://odoo.example.com", Config.odoo[:base_url]
          assert_equal "mydb", Config.odoo[:db]
          assert_equal "admin@example.com", Config.odoo[:login]
          assert_equal "abc123", Config.odoo[:api_key]
        end
      end

      test "infobip reads the expected ENV keys" do
        with_env("INFOBIP_BASE_URL" => "https://api.infobip.com",
                 "INFOBIP_API_KEY" => "key1",
                 "INFOBIP_SMS_SENDER" => "AuthoredCommunity",
                 "INFOBIP_VIBER_BM_SENDER" => "BusinessSender",
                 "INFOBIP_VIBER_BOT_SENDER" => "BotSender",
                 "INFOBIP_VIBER_BM_OTP_TEMPLATE_ID" => "otp-template-uuid",
                 "INFOBIP_VIBER_BM_LOGIN_TEMPLATE_ID" => "login-template-uuid",
                 "INFOBIP_VIBER_BM_TEMPLATE_LANGUAGE" => "bs",
                 "INFOBIP_WHATSAPP_SENDER" => "38765000000",
                 "INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME" => "mi_phone_message",
                 "INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE" => "sr",
                 "INFOBIP_MESSENGER_SENDER" => "page-id",
                 "INFOBIP_MESSAGES_API_ENABLED" => "1") do
          assert_equal "https://api.infobip.com", Config.infobip[:base_url]
          assert_equal "key1", Config.infobip[:api_key]
          assert_equal "AuthoredCommunity", Config.infobip[:sms_sender] # explicitly configured
          assert_equal "BusinessSender", Config.infobip[:viber_bm_sender]
          assert_equal "BotSender", Config.infobip[:viber_bot_sender]
          assert_equal "otp-template-uuid", Config.infobip[:viber_otp_template_id]
          assert_equal "login-template-uuid", Config.infobip[:viber_login_template_id]
          assert_equal "bs", Config.infobip[:viber_template_language]
          assert_equal "BusinessSender", Config.infobip[:viber_sender]
          assert_equal "38765000000", Config.infobip[:whatsapp_sender]
          assert_equal "mi_phone_message", Config.infobip[:whatsapp_template_name]
          assert_equal "sr", Config.infobip[:whatsapp_template_language]
          assert_equal "page-id", Config.infobip[:messenger_sender]
          assert Config.infobip[:messages_api_enabled]
        end
      end

      test "absent SMS sender does not inherit the Foundation sender" do
        prior = Decidim::Bih.infobip_sms_sender
        Decidim::Bih.infobip_sms_sender = nil
        with_env("INFOBIP_SMS_SENDER" => nil) { assert_nil Config.infobip[:sms_sender] }
      ensure
        Decidim::Bih.infobip_sms_sender = prior
      end

      test "legacy Viber sender config applies only to Business Messages" do
        with_env("INFOBIP_VIBER_SENDER" => "LegacyBusinessSender") do
          assert_equal "LegacyBusinessSender", Config.infobip[:viber_bm_sender]
          assert_equal "LegacyBusinessSender", Config.infobip[:viber_sender]
          assert_nil Config.infobip[:viber_bot_sender]
        end
      end

      test "phone channel validity uses seconds and preserves the legacy fallback" do
        with_env("INFOBIP_PHONE_CHANNEL_VALIDITY_SECONDS" => "45") do
          assert_equal 45, Config.phone_channel_validity_seconds
        end

        with_env("INFOBIP_VIBER_FAILOVER_MINUTES" => "2") do
          assert_equal 120, Config.phone_channel_validity_seconds
        end
      end

      test "phone channel validity enforces the provider minimum" do
        with_env("INFOBIP_PHONE_CHANNEL_VALIDITY_SECONDS" => "2") do
          assert_equal 10, Config.phone_channel_validity_seconds
        end
      end

      test "validate warns when WhatsApp sender lacks the authentication template" do
        logs = capture_logs do
          with_env("INFOBIP_MESSAGES_API_ENABLED" => "true",
                   "INFOBIP_WHATSAPP_SENDER" => "38765000000") do
            Config.validate!
          end
        end

        assert_match(/WHATSAPP_PHONE_TEMPLATE_NAME/, logs)
        assert_match(/WhatsApp will be skipped/, logs)
      end

      test "WhatsApp authentication language defaults to Serbian" do
        with_env({}) do
          assert_equal "sr", Config.infobip[:whatsapp_template_language]
          assert_equal "sr", Config::WHATSAPP_AUTH_TEMPLATE_LANGUAGE
        end
      end

      test "gemini uses defaults when ENV keys are absent" do
        with_env({}) do
          assert_nil Config.gemini[:api_key]
          assert_equal "gemini-flash-lite-latest", Config.gemini[:model]
          assert_equal "https://generativelanguage.googleapis.com", Config.gemini[:base_url]
        end
      end

      test "viber reads bot_uri from ENV" do
        with_env("VIBER_BOT_URI" => "mipreduzimamo") do
          assert_equal "mipreduzimamo", Config.viber[:bot_uri]
        end
      end

      test "viber reads public onboarding flag from ENV" do
        with_env("DECIDIM_BIH_VIBER_PUBLIC_ONBOARDING_ENABLED" => "1") do
          assert_equal true, Config.viber[:public_onboarding_enabled]
        end

        with_env("DECIDIM_BIH_VIBER_PUBLIC_ONBOARDING_ENABLED" => "false") do
          assert_equal false, Config.viber[:public_onboarding_enabled]
        end
      end

      test "reset! clears all memoized values" do
        Config.odoo # memoize
        Config.reset!
        # After reset, re-reading with different ENV should give new values
        with_env("ODOO_URL" => "https://new.example.com") do
          assert_equal "https://new.example.com", Config.odoo[:base_url]
        end
      end

      test "validate! logs a warning when a provider is partially configured" do
        logs = capture_logs do
          with_env("ODOO_URL" => "https://odoo.example.com") do # only 1/4 keys
            Config.validate!
          end
        end

        assert_match(/odoo.*partially configured/, logs)
        assert_match(/missing:.*db/, logs)
      end

      test "validate! does not warn when a provider has zero configured keys" do
        logs = capture_logs do
          with_env({}) do # all blank
            Config.validate!
          end
        end

        assert_no_match(/odoo.*partially configured/, logs)
      end

      test "validate! does not warn when a provider is fully configured" do
        logs = capture_logs do
          with_env("ODOO_URL" => "https://o.example.com",
                   "ODOO_DB" => "db",
                   "ODOO_LOGIN" => "login",
                   "ODOO_API_KEY" => "key") do
            Config.validate!
          end
        end

        assert_no_match(/odoo.*partially configured/, logs)
      end

      test "validate! warns when a gemini key is set but base_url is the blocked AI Studio default" do
        logs = capture_logs do
          # Key present, GEMINI_BASE_URL left unset → falls back to the
          # generativelanguage.googleapis.com default, which is blocked for the
          # production GCP project (Vertex-only). This is the silent-401 trap.
          with_env("GEMINI_API_KEY" => "abc123") do
            Config.validate!
          end
        end

        assert_match(/gemini/i, logs)
        assert_match(/generativelanguage/, logs)
      end

      test "validate! does not warn about gemini when base_url is the Vertex host" do
        logs = capture_logs do
          with_env("GEMINI_API_KEY" => "abc123",
                   "GEMINI_BASE_URL" => "https://aiplatform.googleapis.com") do
            Config.validate!
          end
        end

        assert_no_match(/generativelanguage/, logs)
      end

      test "validate! does not warn about gemini when no key is set even on the default base_url" do
        logs = capture_logs do
          with_env({}) do # no key → provider intentionally not set up
            Config.validate!
          end
        end

        assert_no_match(/generativelanguage/, logs)
      end

      test "gemini_misrouted? is true when a key is set but base_url is the blocked AI Studio host" do
        with_env("GEMINI_API_KEY" => "abc123") do
          assert Config.gemini_misrouted?
        end
      end

      test "gemini_misrouted? is false when base_url is the Vertex host" do
        with_env("GEMINI_API_KEY" => "abc123",
                 "GEMINI_BASE_URL" => "https://aiplatform.googleapis.com") do
          assert_not Config.gemini_misrouted?
        end
      end

      test "gemini_misrouted? is false when no key is set even on the default base_url" do
        with_env({}) do
          assert_not Config.gemini_misrouted?
        end
      end

      private

      def with_env(overrides)
        saved = {}
        all_keys = %w(ODOO_URL ODOO_DB ODOO_LOGIN ODOO_API_KEY
                      INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_SMS_SENDER INFOBIP_VIBER_SENDER
                      INFOBIP_VIBER_BM_SENDER INFOBIP_VIBER_BOT_SENDER
                      INFOBIP_VIBER_BM_OTP_TEMPLATE_ID INFOBIP_VIBER_BM_LOGIN_TEMPLATE_ID
                      INFOBIP_VIBER_BM_TEMPLATE_LANGUAGE
                      INFOBIP_WHATSAPP_SENDER INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME
                      INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE INFOBIP_MESSENGER_SENDER
                      INFOBIP_MESSAGES_API_ENABLED INFOBIP_PHONE_CHANNEL_VALIDITY_SECONDS
                      INFOBIP_VIBER_FAILOVER_MINUTES
                      GEMINI_API_KEY GEMINI_MODEL GEMINI_BASE_URL
                      VIBER_BOT_URI VIBER_WEBHOOK_SECRET VIBER_IMAGE_HOST_ALLOWLIST
                      DECIDIM_BIH_VIBER_PUBLIC_ONBOARDING_ENABLED)

        all_keys.each do |k|
          saved[k] = ENV.fetch(k, nil)
          ENV.delete(k)
        end
        overrides.each { |k, v| ENV[k] = v }

        Config.reset!
        yield
      ensure
        all_keys.each { |k| saved[k].nil? ? ENV.delete(k) : (ENV[k] = saved[k]) }
        Config.reset!
      end

      def capture_logs
        io = StringIO.new
        orig = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        yield
        io.string
      ensure
        Rails.logger = orig
      end
    end
  end
end
