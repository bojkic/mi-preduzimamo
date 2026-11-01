# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module ContentBlocks
      # W2.3 — the homepage "MI hub" content block must surface every built
      # citizen capability, not just the original four. The engagement hub
      # (Bodovi zajedništva), volunteering, and the Komšiluk board are otherwise
      # reachable only from the top nav; they must also have a homepage tile.
      class MiHubCellTest < ActionDispatch::IntegrationTest
        CHAT_ENV_KEYS = %w(
          INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_CHAT_CHANNELS
          INFOBIP_VIBER_BOT_SENDER INFOBIP_WHATSAPP_SENDER
          INFOBIP_MESSENGER_SENDER INFOBIP_INSTAGRAM_SENDER
          VIBER_WEBHOOK_SECRET DECIDIM_BIH_VIBER_BOT_ENABLED
        ).freeze

        setup do
          @organization = create_organization
          host! @organization.host
          @previous_chat_env = CHAT_ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
          # Own the visual setting just as we own provider-channel settings.
          # The reference host explicitly supplies a persona; engine users may
          # instead select their own static emblem, which this case exercises.
          @previous_static_image_path = Decidim::Bih.mi_bot_persona_static_image_path
          Decidim::Bih.mi_bot_persona_static_image_path = "/mi/heart-mark.webp"
          @previous_decision_path = Decidim::Bih.mi_hub_decision_path
          Decidim::Bih.mi_hub_decision_path = "/processes/authored-decisions"
          @previous_external_links = Decidim::Bih.external_chat_onboarding_links
          @previous_viber_uri = Decidim::Bih.viber_bot_uri
          @previous_viber_public = Decidim::Bih.viber_public_onboarding_enabled
          CHAT_ENV_KEYS.each { |key| ENV.delete(key) }
          Decidim::Bih.external_chat_onboarding_links = {}
          Decidim::Bih.viber_bot_uri = nil
          Decidim::Bih.viber_public_onboarding_enabled = false
          Decidim::Bih::Config.reset!
        end

        teardown do
          @previous_chat_env.each do |key, value|
            value.nil? ? ENV.delete(key) : ENV[key] = value
          end
          Decidim::Bih.mi_bot_persona_static_image_path = @previous_static_image_path
          Decidim::Bih.mi_hub_decision_path = @previous_decision_path
          Decidim::Bih.external_chat_onboarding_links = @previous_external_links
          Decidim::Bih.viber_bot_uri = @previous_viber_uri
          Decidim::Bih.viber_public_onboarding_enabled = @previous_viber_public
          Decidim::Bih::Config.reset!
        end

        def rendered_hub
          # Render the content-block cell in the host's view context, the same
          # way the homepage renders it. A prior request gives us a fully wired
          # controller/view context (current_organization, helpers, routes).
          get "/"
          follow_redirect! while response.redirect?
          content_block = Decidim::ContentBlock.new(
            organization: @organization, scope_name: :homepage, manifest_name: :mi_hub
          )
          @controller.view_context.cell(
            "decidim/bih/content_blocks/mi_hub", content_block
          ).to_s
        end

        test "the hub links to the community engagement hub" do
          assert_includes rendered_hub, "/biceriseno/zajednistvo"
        end

        test "the hub links to volunteering" do
          assert_includes rendered_hub, "/biceriseno/volontiranje"
        end

        test "the hub links to the Komšiluk board" do
          assert_includes rendered_hub, "/biceriseno/komsiluk-board"
        end

        test "the hub still links to the original four destinations" do
          body = rendered_hub
          assert_includes body, "/biceriseno"
          assert_includes body, "/processes/authored-decisions"
          assert_includes body, "/biceriseno/projekti"
          assert_includes body, "/processes"
        end

        test "the hub advertises only website chat when provider channels are disabled" do
          fragment = Capybara.string(rendered_hub)

          assert fragment.has_css?(".mi-channel--web", text: "Sajt")
          %w(viber whatsapp messenger instagram sms).each do |channel|
            assert_not fragment.has_css?(".mi-channel--#{channel}"),
                       "Expected disabled #{channel} chat pill to remain hidden"
          end
          assert_includes fragment.text, "Razgovaraj sa Milicom na dostupnom kanalu."
          # The public landing page uses the neutral community emblem, without animation.
          assert_equal "/mi/heart-mark.webp", fragment.find(".mi-omni-band__emblem img", visible: :all)["src"]
          assert_not fragment.has_css?(".mi-omni-band__emblem [src$='.gif'], .mi-omni-band__emblem [srcset$='.gif']", visible: :all)
          assert_not_includes fragment.text, "Piši nam i preko Vibera"
        end

        test "the hub shows only provider channels whose delivery and public entry gates are ready" do
          ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
          ENV["INFOBIP_API_KEY"] = "test-api-key"
          ENV["INFOBIP_CHAT_CHANNELS"] = "whatsapp,messenger,instagram"
          ENV["INFOBIP_VIBER_BOT_SENDER"] = "ViberBot"
          ENV["VIBER_WEBHOOK_SECRET"] = "test-viber-webhook-secret"
          # The Bot is off for this deployment; this case covers the pill it
          # would show if it were revived, so it opts the switch on.
          ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = "true"
          ENV["INFOBIP_WHATSAPP_SENDER"] = "WhatsAppBusiness"
          ENV["INFOBIP_MESSENGER_SENDER"] = "MessengerPage"
          ENV["INFOBIP_INSTAGRAM_SENDER"] = "InstagramBusiness"
          Decidim::Bih.viber_bot_uri = "example-community-fixture"
          Decidim::Bih.viber_public_onboarding_enabled = true
          Decidim::Bih.external_chat_onboarding_links = {
            whatsapp: "https://wa.me/12025550101",
            messenger: "https://m.me/example-community-fixture",
            instagram: "https://instagram.com/example_community_fixture"
          }
          Decidim::Bih::Config.reset!
          create_launch_approval("viber_launch")
          create_launch_approval(
            "external_chat_launch",
            scope_key: Decidim::Bih::GovernanceApproval.external_chat_scope_key(
              %w(whatsapp messenger instagram)
            )
          )

          fragment = Capybara.string(rendered_hub)

          %w(web viber whatsapp messenger instagram).each do |channel|
            assert fragment.has_css?(".mi-channel--#{channel}"),
                   "Expected launch-ready #{channel} chat pill"
          end
          assert_not fragment.has_css?(".mi-channel--sms")
        end

        test "the hub keeps provider channels hidden without current launch approvals" do
          ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
          ENV["INFOBIP_API_KEY"] = "test-api-key"
          ENV["INFOBIP_CHAT_CHANNELS"] = "whatsapp"
          ENV["INFOBIP_VIBER_BOT_SENDER"] = "ViberBot"
          ENV["INFOBIP_WHATSAPP_SENDER"] = "WhatsAppBusiness"
          Decidim::Bih.viber_bot_uri = "example-community-fixture"
          Decidim::Bih.viber_public_onboarding_enabled = true
          Decidim::Bih.external_chat_onboarding_links = { whatsapp: "https://wa.me/12025550101" }
          Decidim::Bih::Config.reset!

          fragment = Capybara.string(rendered_hub)

          assert fragment.has_css?(".mi-channel--web")
          assert_not fragment.has_css?(".mi-channel--viber")
          assert_not fragment.has_css?(".mi-channel--whatsapp")
        end

        test "the hub fails closed when one publicly selected external channel is incomplete" do
          ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
          ENV["INFOBIP_API_KEY"] = "test-api-key"
          ENV["INFOBIP_CHAT_CHANNELS"] = "whatsapp"
          ENV["INFOBIP_WHATSAPP_SENDER"] = "WhatsAppBusiness"
          Decidim::Bih.external_chat_onboarding_links = {
            whatsapp: "https://wa.me/12025550101",
            messenger: "https://m.me/example-community-fixture"
          }
          Decidim::Bih::Config.reset!
          create_launch_approval(
            "external_chat_launch",
            scope_key: Decidim::Bih::GovernanceApproval.external_chat_scope_key(%w(whatsapp messenger))
          )

          fragment = Capybara.string(rendered_hub)

          assert fragment.has_css?(".mi-channel--web")
          assert_not fragment.has_css?(".mi-channel--whatsapp")
          assert_not fragment.has_css?(".mi-channel--messenger")
        end

        test "the hub keeps Viber hidden when its webhook secret is missing" do
          ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
          ENV["INFOBIP_API_KEY"] = "test-api-key"
          ENV["INFOBIP_VIBER_BOT_SENDER"] = "ViberBot"
          Decidim::Bih.viber_bot_uri = "example-community-fixture"
          Decidim::Bih.viber_public_onboarding_enabled = true
          Decidim::Bih::Config.reset!
          create_launch_approval("viber_launch")

          fragment = Capybara.string(rendered_hub)

          assert fragment.has_css?(".mi-channel--web")
          assert_not fragment.has_css?(".mi-channel--viber")
        end

        # en.yml is the canonical i18n source and must carry every decidim.bih
        # tile key (verb/kicker/blurb/cta) for all seven hub tiles. A locale
        # audit found the English homepage rendered "translation missing" for
        # the vrijednujemo / volontiramo / druzimo_se tiles because en.yml never
        # defined them. Render the hub in English and assert no missing-key
        # markers leak into the output.
        test "the English hub renders with no missing translations" do
          body = I18n.with_locale(:en) { rendered_hub }

          assert_no_match(/translation missing/i, body,
                          "English MI hub rendered an untranslated decidim.bih key")
          assert_no_match(/translation_missing/i, body,
                          "English MI hub rendered an untranslated decidim.bih key")

          # Spot-check that the previously-missing tiles actually rendered their
          # English copy (not just that no marker leaked).
          assert_includes body, "WE VALUE"
          assert_includes body, "WE VOLUNTEER"
          assert_includes body, "WE GET TOGETHER"
        end

        private

        def create_launch_approval(kind, scope_key: nil)
          summary = "Live channel verification completed for public launch."
          Decidim::Bih::GovernanceApproval.create!(
            organization: @organization,
            user: FactoryBot.create(:user, :admin, :confirmed, organization: @organization),
            governance_kind: kind,
            status: "approved",
            scope_key:,
            evidence_summary: summary,
            evidence_digest: Decidim::Bih::GovernanceApproval.safe_evidence_digest(summary)
          )
        end
      end
    end
  end
end
