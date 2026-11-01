# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Viber
      # The deployment runs on Viber Business Messages only. These tests pin the
      # two halves of that decision: the Bot cannot come back on by accident,
      # and proactive Viber delivery still finds recipients without it.
      class BusinessMessagesOnlyTest < ActiveSupport::TestCase
        ENV_KEYS = %w(
          DECIDIM_BIH_VIBER_BOT_ENABLED INFOBIP_BASE_URL INFOBIP_API_KEY
          INFOBIP_VIBER_BOT_SENDER INFOBIP_VIBER_BM_SENDER
        ).freeze

        setup do
          @original_env = ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          # Full Bot credentials, so the only thing keeping the Bot off is the switch.
          ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
          ENV["INFOBIP_API_KEY"] = "test-api-key"
          ENV["INFOBIP_VIBER_BOT_SENDER"] = "configured-bot-sender"
          ENV["INFOBIP_VIBER_BM_SENDER"] = "configured-bm-sender"
          ENV.delete("DECIDIM_BIH_VIBER_BOT_ENABLED")
          Decidim::Bih::Config.reset!
        end

        teardown do
          @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Decidim::Bih::Config.reset!
        end

        # --- the kill switch -------------------------------------------------

        test "the Viber Bot is off by default even with complete credentials" do
          assert_not Decidim::Bih::Config.viber_bot_enabled?

          client = Decidim::Bih::Infobip::Client.new
          # Credentials are genuinely present...
          assert client.viber_bot_configured?
          # ...but nothing may act on them.
          assert_not client.viber_bot_active?
        end

        test "Business Messages stays configured while the Bot is off" do
          assert Decidim::Bih::Infobip::Client.new.viber_business_configured?
        end

        test "the Bot only becomes active when explicitly switched on" do
          ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = "true"
          Decidim::Bih::Config.reset!

          assert Decidim::Bih::Config.viber_bot_enabled?
          assert Decidim::Bih::Infobip::Client.new.viber_bot_active?
        end

        test "the switch alone cannot activate the Bot without credentials" do
          ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = "true"
          ENV.delete("INFOBIP_VIBER_BOT_SENDER")
          Decidim::Bih::Config.reset!

          assert_not Decidim::Bih::Infobip::Client.new.viber_bot_active?
        end

        # --- Bot-free delivery addresses -------------------------------------

        test "a verified phone becomes a Business Messages delivery address" do
          contact = Decidim::Bih::Viber::BusinessContact.record!(user: @user, phone: "+387 65 123-456")

          assert_equal "38765123456", contact.phone
          assert_equal @user.id, contact.decidim_user_id
        end

        test "recording the same user twice updates rather than duplicating" do
          Decidim::Bih::Viber::BusinessContact.record!(user: @user, phone: "065123456")
          Decidim::Bih::Viber::BusinessContact.record!(user: @user, phone: "065999888")

          contacts = Decidim::Bih::Viber::BusinessContact.where(decidim_user_id: @user.id)
          assert_equal 1, contacts.count
          assert_equal "065999888", contacts.first.phone
        end

        test "an unusable phone records nothing instead of raising" do
          assert_nil Decidim::Bih::Viber::BusinessContact.record!(user: @user, phone: "12")
          assert_equal 0, Decidim::Bih::Viber::BusinessContact.where(decidim_user_id: @user.id).count
        end

        test "proactive Viber delivery resolves a contact with no Bot linkage" do
          grant_phone!
          Decidim::Bih::Viber::BusinessContact.record!(user: @user, phone: "38765123456")

          phone = Decidim::Bih::Viber::BusinessRecipient.phone_for(
            user: @user,
            organization_id: @organization.id
          )

          assert_equal "38765123456", phone
        end

        test "a stale Bot-era linkage cannot override the verified account number" do
          grant_phone!
          Decidim::Bih::Viber::Linkage.create!(
            organization: @organization,
            user: @user,
            viber_sender: "opaque-bot-id",
            phone: "38766111222",
            verified_at: Time.current
          )
          Decidim::Bih::Viber::BusinessContact.record!(user: @user, phone: "38765123456")

          phone = Decidim::Bih::Viber::BusinessRecipient.phone_for(
            user: @user,
            organization_id: @organization.id
          )

          assert_equal "38765123456", phone
        end

        test "an unverified linkage falls through to the Business contact" do
          grant_phone!
          Decidim::Bih::Viber::Linkage.create!(
            organization: @organization,
            user: @user,
            viber_sender: "opaque-bot-id",
            phone: "38766111222",
            verified_at: nil
          )
          Decidim::Bih::Viber::BusinessContact.record!(user: @user, phone: "38765123456")

          phone = Decidim::Bih::Viber::BusinessRecipient.phone_for(
            user: @user,
            organization_id: @organization.id
          )

          assert_equal "38765123456", phone
        end

        test "a user with neither record has no Viber address" do
          assert_nil Decidim::Bih::Viber::BusinessRecipient.phone_for(
            user: @user,
            organization_id: @organization.id
          )
        end

        # --- Business Messages identity --------------------------------------

        test "the BM sender is itself the attributed phone, with no OTP" do
          identity = Decidim::Bih::Viber::BusinessMessageIdentity.new(
            organization: @organization,
            account_linking: Decidim::Bih::Viber::AccountLinking.new(
              organization: @organization,
              gateway: Decidim::Bih::Viber::QueuedPhoneMessageGateway.new
            )
          )

          assert_equal "38765123456", identity.linked_phone(sender: "+38765123456")
          assert_nil identity.linked_phone(sender: "opaque-38765123456"), "opaque IDs cannot be stripped into an attributed phone"
          assert_nil identity.linked_phone(sender: "+387 65 123 456"), "provider identity must be the strict phone sender, not typed display text"
        end

        private

        def grant_phone!
          Decidim::Authorization.create!(user: @user, name: "sms",
                                         unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("+38765123456"), granted_at: Time.current)
          Decidim::Bih::VerifiedPhone.synchronize!(user: @user, organization: @organization, phone: "+38765123456")
        end
      end
    end
  end
end
