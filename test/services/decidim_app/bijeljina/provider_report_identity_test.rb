# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class ProviderReportIdentityTest < ActiveSupport::TestCase
      PHONE = "38765123456"
      BUSINESS = "synthetic-business"

      setup do
        @organization = create_organization
        @user = create(:user, :confirmed, organization: @organization)
        @authorization = Decidim::Authorization.create!(user: @user, name: "sms",
                                                        unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE), granted_at: Time.current)
      end

      test "provider phone attributes only a currently granted account in the same organization" do
        assert_equal @user, resolve
        @authorization.update!(granted_at: nil)
        assert_nil resolve
        @authorization.update!(granted_at: Time.current)
        foreign = create_organization
        assert_nil resolve(organization: foreign)
        @authorization.destroy!
        assert_nil resolve
      end

      test "typed contacts opaque IDs and other channel numeric IDs cannot choose report author" do
        assert_nil resolve(sender: "BA.opaque-#{PHONE}", text: "Moj broj je #{PHONE}")
        assert_nil resolve(sender: "unknown", text: PHONE)
        assert_nil resolve(channel: "messenger")
        assert_nil resolve(channel: "instagram")
        assert_nil resolve(recipient: "foreign-business")
        assert_nil ProviderReportIdentity.call(organization: @organization, message: { sender: PHONE })
      end

      test "a verified channel connection permits report attribution but revocation takes effect immediately" do
        sender = "opaque-citizen"
        connection = connect(sender:)
        assert_equal @user, resolve(sender:)
        connection.update!(revoked_at: Time.current)
        assert_nil resolve(sender:)
        connection.assign_attributes(revoked_at: nil, verified_at: nil)
        assert_not connection.valid?, "an unverified channel connection cannot be persisted"
        assert_includes connection.errors.attribute_names, :verified_at
        assert_nil resolve(sender:), "the persisted connection is still revoked"
      end

      test "verified connection does not bypass current account phone verification" do
        connect(sender: "opaque-citizen")
        @authorization.update!(granted_at: nil)
        assert_nil resolve(sender: "opaque-citizen")
      end

      test "phone variants matching different accounts fail closed" do
        second = create(:user, :confirmed, organization: @organization)
        Decidim::Authorization.create!(user: second, name: "sms",
                                       unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("065123456"), granted_at: Time.current)
        assert_nil resolve
      end

      test "identity resolution never grants authorization mutates contact consent or creates a session" do
        before = @user.reload.attributes
        assert_no_difference("Decidim::Authorization.count") { assert_equal @user, resolve }
        assert_equal before, @user.reload.attributes
      end

      private

      def resolve(organization: @organization, channel: "whatsapp", sender: PHONE, recipient: BUSINESS, text: "Problem u ulici")
        message = Decidim::Bih::Infobip::InboundMessage.from_primitives(channel:, sender:, recipient:,
                                                                        message_id: SecureRandom.uuid, type: "TEXT", text:, occurred_at: Time.current.iso8601(6))
        Decidim::Bih::ChannelConnections.stub(:configured_sender, BUSINESS) do
          ProviderReportIdentity.call(organization:, message:)
        end
      end

      def connect(sender:)
        Decidim::Bih::ChannelConnection.create!(organization: @organization, user: @user, channel: "whatsapp",
                                                business_sender: BUSINESS, recipient_digest: Decidim::Bih::ChannelConnections.digest(sender),
                                                recipient_ciphertext: Decidim::Bih::ChannelConnections.encrypt(sender), verified_at: Time.current)
      end
    end
  end
end
