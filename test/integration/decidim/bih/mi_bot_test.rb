# frozen_string_literal: true

require "test_helper"
# See reports_intake_test.rb / reports_map_test.rb for why Capybara is required
# here (the Decidim layout resolves default URL options via Capybara.server_port
# in tests).
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for the public Milica introduction. It presents the same
    # site assistant as the global widget and only exposes launch-ready channels.
    class MiBotTest < ActionDispatch::IntegrationTest
      setup do
        @previous_persona_image = Decidim::Bih.mi_bot_persona_image_path
        @previous_persona_static_image = Decidim::Bih.mi_bot_persona_static_image_path
        @organization = create_organization
        host! @organization.host
        @previous_viber_bot_uri = Decidim::Bih.viber_bot_uri
        @previous_viber_public_onboarding_enabled = Decidim::Bih.viber_public_onboarding_enabled
        @previous_viber_env = %w(INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_VIBER_BOT_SENDER VIBER_WEBHOOK_SECRET
                                 DECIDIM_BIH_VIBER_BOT_ENABLED INFOBIP_VIBER_BM_SENDER INFOBIP_CHAT_CHANNELS
                                 VIBER_BM_WEBHOOK_SECRET DECIDIM_BIH_VIBER_BM_PUBLIC_ONBOARDING_ENABLED)
                              .index_with { |key| ENV.fetch(key, nil) }
        @previous_viber_env.each_key { |key| ENV.delete(key) }
        Decidim::Bih::Config.reset!
      end

      teardown do
        Decidim::Bih.mi_bot_persona_image_path = @previous_persona_image
        Decidim::Bih.mi_bot_persona_static_image_path = @previous_persona_static_image
        Decidim::Bih.viber_bot_uri = @previous_viber_bot_uri
        Decidim::Bih.viber_public_onboarding_enabled = @previous_viber_public_onboarding_enabled
        @previous_viber_env.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
        Decidim::Bih::Config.reset!
      end

      test "GET mi-bot renders the single site assistant experience" do
        get "/biceriseno/mi-bot"

        assert_response :success
        # Page-scoped stylesheet served statically from /public.
        assert_select "link[href^=?]", "/mi/mi-bot.css"
        assert_select "h1", text: /Komšinica\s+Milica/
        assert_select ".mi-bot-eyebrow", text: "Digitalna komšinica kroz MI platformu"
        assert_select "button[data-mi-chat-open]", text: I18n.t("decidim.bih.mi_bot.show.cta.try_bot")
        assert_select ".mi-bot-hero__persona source[media='(prefers-reduced-motion: reduce)'][srcset='/mi/milica/wave.jpg']", 1
        assert_select ".mi-bot-hero__persona img[src='/mi/milica/wave.gif']",
                      alt: I18n.t("decidim.bih.concierge.media.milica_wave.alt")
        assert_select ".mi-bot-phone", false
        assert_select ".mi-bot-capability-card", 8
        assert_select ".mi-bot-capability-card h3", text: "Javni prevoz"
        assert_select ".mi-bot-capability-card h3", text: "Parking zone"
        assert_select ".mi-bot-capability-card h3", text: "Servisne informacije"
        assert_select ".mi-bot-capability-card h3", text: "Vrijeme, vodostaj i vazduh"
        assert_not_includes response.body, "WhatsApp"
        assert_not_includes response.body, "Messenger"
        # Match complete UI words, rather than substrings inside other words.
        assert_no_match(/\bdemo\b/, response.body)
      end

      test "GET mi-bot omits persona when the host explicitly disables it" do
        Decidim::Bih.mi_bot_persona_image_path = nil
        Decidim::Bih.mi_bot_persona_static_image_path = nil
        get "/biceriseno/mi-bot"
        assert_response :success
        assert_select ".mi-bot-hero__persona", count: 0
        assert_select "button[data-mi-chat-open]", minimum: 1
      end

      test "GET mi-bot preserves host-selected reduced-motion artwork" do
        Decidim::Bih.mi_bot_persona_image_path = "/authored/motion.gif"
        Decidim::Bih.mi_bot_persona_static_image_path = "/authored/static.jpg"
        get "/biceriseno/mi-bot"
        assert_response :success
        assert_select ".mi-bot-hero__persona source[media='(prefers-reduced-motion: reduce)'][srcset='/authored/static.jpg']", count: 1
        assert_select ".mi-bot-hero__persona img[src='/authored/motion.gif']", count: 1
      end

      test "GET mi-bot renders inline SVG icons (no external CDN)" do
        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "svg.mi-bot-ico"
        assert_not_includes response.body, "unpkg.com"
        assert_not_includes response.body, "data-lucide"
      end

      test "GET mi-bot uses the translated section headings" do
        get "/biceriseno/mi-bot"

        assert_response :success
        assert_includes response.body, I18n.t("decidim.bih.mi_bot.show.capabilities.kicker")
        assert_includes response.body, "poruka u razgovoru sama ne kreira prijavu"
        assert_includes response.body, "Redovi vožnje i stajališta koje zajednica uveze i provjeri."
        assert_includes response.body, "Tarife i zone parkinga koje zajednica unese i provjeri."
        assert_includes response.body, "Izričito povezani izvori komunalnih i javnih službi."
        assert_includes response.body, "Izričito povezani meteorološki, hidrološki i senzorski izvori."
      end

      test "GET mi-bot renders localized content without Serbian showcase residue in Croatian" do
        post "/locale", params: { locale: "hr" }
        get "/biceriseno/mi-bot"

        assert_response :success
        assert_includes response.body, "Razgovaraj s Milicom na stranici"
        assert_not_includes response.body, "danas 09:14"
      end

      test "GET mi-bot hides Viber onboarding by default" do
        Decidim::Bih.viber_bot_uri = "mipreduzimamo"
        Decidim::Bih.viber_public_onboarding_enabled = false

        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "[data-viber-onboarding]", false
        assert_not_includes response.body, "viber://pa"
      end

      test "GET mi-bot shows verified Business Messages without a Bot URI" do
        ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
        ENV["INFOBIP_API_KEY"] = "test-api-key"
        ENV["INFOBIP_VIBER_BM_SENDER"] = "BusinessSender"
        ENV["INFOBIP_CHAT_CHANNELS"] = "viber_bm"
        ENV["VIBER_BM_WEBHOOK_SECRET"] = "test-business-secret"
        ENV["DECIDIM_BIH_VIBER_BM_PUBLIC_ONBOARDING_ENABLED"] = "true"
        Decidim::Bih::Config.reset!

        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "[data-viber-bm-onboarding=?]", "public"
        assert_select "[data-viber-onboarding]", false
        assert_not_includes response.body, "viber://pa"
      end

      test "GET mi-bot hides Business Messages while owner switch is off" do
        ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
        ENV["INFOBIP_API_KEY"] = "test-api-key"
        ENV["INFOBIP_VIBER_BM_SENDER"] = "BusinessSender"
        ENV["INFOBIP_CHAT_CHANNELS"] = "viber_bm"
        ENV["VIBER_BM_WEBHOOK_SECRET"] = "test-business-secret"
        ENV["DECIDIM_BIH_VIBER_BM_PUBLIC_ONBOARDING_ENABLED"] = "false"
        Decidim::Bih::Config.reset!

        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "[data-viber-bm-onboarding]", false
      end

      test "GET mi-bot hides Viber onboarding without a bot URI" do
        Decidim::Bih.viber_bot_uri = nil
        Decidim::Bih.viber_public_onboarding_enabled = true

        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "[data-viber-onboarding]", false
        assert_not_includes response.body, "viber://pa"
      end

      test "GET mi-bot hides Viber onboarding when Bot delivery is not configured" do
        Decidim::Bih.viber_bot_uri = "mipreduzimamo"
        Decidim::Bih.viber_public_onboarding_enabled = true

        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "[data-viber-onboarding]", false
        assert_not_includes response.body, "viber://pa"
      end

      test "GET mi-bot renders gated public Viber onboarding" do
        ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
        ENV["INFOBIP_API_KEY"] = "test-api-key"
        ENV["INFOBIP_VIBER_BOT_SENDER"] = "TestViberBot"
        ENV["VIBER_WEBHOOK_SECRET"] = "test-viber-webhook-secret"
        # Covers the dormant Bot's onboarding surface, so switch it on.
        ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = "true"
        Decidim::Bih.viber_bot_uri = "mipreduzimamo"
        Decidim::Bih.viber_public_onboarding_enabled = true
        Decidim::Bih::Config.reset!
        create_launch_approval("viber_launch")

        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "[data-viber-onboarding=?]", "public"
        assert_select "a[href=?]", "viber://pa?chatURI=mipreduzimamo",
                      text: I18n.t("decidim.bih.mi_bot.show.viber_onboarding.cta")
        assert_includes response.body, I18n.t("decidim.bih.mi_bot.show.viber_onboarding.recovery_title")
        assert_includes response.body, I18n.t("decidim.bih.mi_bot.show.viber_onboarding.privacy_note")
      end

      test "GET mi-bot keeps configured Viber hidden without a current launch approval" do
        ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
        ENV["INFOBIP_API_KEY"] = "test-api-key"
        ENV["INFOBIP_VIBER_BOT_SENDER"] = "TestViberBot"
        Decidim::Bih.viber_bot_uri = "mipreduzimamo"
        Decidim::Bih.viber_public_onboarding_enabled = true
        Decidim::Bih::Config.reset!
        create_launch_approval("viber_launch", approved_at: 91.days.ago)

        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "[data-viber-onboarding]", false
        assert_not_includes response.body, "viber://pa"
      end

      test "GET mi-bot keeps configured Viber hidden without a strong webhook secret" do
        ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
        ENV["INFOBIP_API_KEY"] = "test-api-key"
        ENV["INFOBIP_VIBER_BOT_SENDER"] = "TestViberBot"
        ENV["VIBER_WEBHOOK_SECRET"] = "too-short"
        Decidim::Bih.viber_bot_uri = "mipreduzimamo"
        Decidim::Bih.viber_public_onboarding_enabled = true
        Decidim::Bih::Config.reset!
        create_launch_approval("viber_launch")

        get "/biceriseno/mi-bot"

        assert_response :success
        assert_select "[data-viber-onboarding]", false
        assert_not_includes response.body, "viber://pa"
      end

      private

      def create_launch_approval(kind, approved_at: Time.current, scope_key: nil)
        summary = "Live channel verification completed for public launch."
        Decidim::Bih::GovernanceApproval.create!(
          organization: @organization,
          user: FactoryBot.create(:user, :admin, :confirmed, organization: @organization),
          governance_kind: kind,
          status: "approved",
          scope_key:,
          approved_at:,
          evidence_summary: summary,
          evidence_digest: Decidim::Bih::GovernanceApproval.safe_evidence_digest(summary)
        )
      end
    end
  end
end
