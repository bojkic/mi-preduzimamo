# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ExternalChatOnboardingTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
        @previous_links = Decidim::Bih.external_chat_onboarding_links
      end

      teardown do
        Decidim::Bih.external_chat_onboarding_links = @previous_links
      end

      test "hides external channels until launch links and provider config are both ready" do
        Decidim::Bih.external_chat_onboarding_links = {
          whatsapp: "https://wa.me/387000000000"
        }

        with_chat_client(configured: []) do
          get "/biceriseno/mi-bot"
        end

        assert_response :success
        assert_select "[data-external-chat-onboarding]", false
        assert_not_includes response.body, "wa.me/387000000000"
      end

      test "renders an exact fully configured and approved HTTPS channel set" do
        Decidim::Bih.external_chat_onboarding_links = {
          whatsapp: "https://wa.me/387000000000",
          messenger: "https://m.me/fondacijabijeljina"
        }
        create_launch_approval(%w(whatsapp messenger))

        with_chat_client(configured: %w(whatsapp messenger instagram)) do
          get "/biceriseno/mi-bot"
        end

        assert_response :success
        assert_select "[data-external-chat-onboarding=?]", "public"
        assert_select "a[href=?]", "https://wa.me/387000000000", count: 1
        assert_select "a[href=?]", "https://m.me/fondacijabijeljina", count: 1
      end

      test "fails closed when any publicly selected channel has an invalid URL or incomplete provider config" do
        Decidim::Bih.external_chat_onboarding_links = {
          whatsapp: "https://wa.me/387000000000",
          messenger: "javascript:alert(1)"
        }
        create_launch_approval(%w(whatsapp messenger))

        with_chat_client(configured: %w(whatsapp)) do
          get "/biceriseno/mi-bot"
        end

        assert_response :success
        assert_select "[data-external-chat-onboarding]", false
        assert_not_includes response.body, "wa.me/387000000000"
        assert_not_includes response.body, "javascript:alert(1)"
      end

      test "hides configured channels when approval scope does not match the public set" do
        Decidim::Bih.external_chat_onboarding_links = {
          whatsapp: "https://wa.me/387000000000",
          messenger: "https://m.me/fondacijabijeljina"
        }
        create_launch_approval(%w(whatsapp))

        with_chat_client(configured: %w(whatsapp messenger)) do
          get "/biceriseno/mi-bot"
        end

        assert_response :success
        assert_select "[data-external-chat-onboarding]", false
      end

      test "host initializer keeps a public entry hidden until its webhook secret is ready" do
        keys = %w(
          DECIDIM_BIH_INSTAGRAM_CHAT_URL
          DECIDIM_BIH_INSTAGRAM_PUBLIC_ONBOARDING_ENABLED
          DECIDIM_BIH_MESSENGER_CHAT_URL
          DECIDIM_BIH_MESSENGER_PUBLIC_ONBOARDING_ENABLED
          DECIDIM_BIH_WHATSAPP_CHAT_URL
          DECIDIM_BIH_WHATSAPP_PUBLIC_ONBOARDING_ENABLED
          INFOBIP_CHAT_WEBHOOK_SECRET
          INSTAGRAM_WEBHOOK_SECRET
          MESSENGER_WEBHOOK_SECRET
          WHATSAPP_WEBHOOK_SECRET
        )
        original_env = keys.index_with { |key| ENV.fetch(key, nil) }
        keys.each { |key| ENV.delete(key) }
        ENV["DECIDIM_BIH_WHATSAPP_CHAT_URL"] = "https://wa.me/387000000000"
        ENV["DECIDIM_BIH_WHATSAPP_PUBLIC_ONBOARDING_ENABLED"] = "true"

        load Rails.root.join("config/initializers/decidim_bih_external_chat.rb")
        assert_empty Decidim::Bih.external_chat_onboarding_links

        ENV["WHATSAPP_WEBHOOK_SECRET"] = "a" * 16
        load Rails.root.join("config/initializers/decidim_bih_external_chat.rb")
        assert_equal "https://wa.me/387000000000",
                     Decidim::Bih.external_chat_onboarding_links.fetch(:whatsapp)
      ensure
        original_env&.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
      end

      private

      def create_launch_approval(channels)
        summary = "Live external chat verification completed for public launch."
        Decidim::Bih::GovernanceApproval.create!(
          organization: @organization,
          user: FactoryBot.create(:user, :admin, :confirmed, organization: @organization),
          governance_kind: "external_chat_launch",
          status: "approved",
          scope_key: Decidim::Bih::GovernanceApproval.external_chat_scope_key(channels),
          evidence_summary: summary,
          evidence_digest: Decidim::Bih::GovernanceApproval.safe_evidence_digest(summary)
        )
      end

      def with_chat_client(configured:)
        client = Object.new
        client.define_singleton_method(:chat_channel_configured?) do |channel|
          configured.include?(channel.to_s)
        end

        Decidim::Bih::Infobip::Client.stub(:new, client) { yield }
      end
    end
  end
end
