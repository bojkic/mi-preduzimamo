# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class SocialRegistrationIntakeTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      Message = Struct.new(:channel, :sender, :text, :shared_phone, keyword_init: true)

      setup do
        @organization = create_organization
        @cache = ActiveSupport::Cache::MemoryStore.new
        @original_enabled = ENV.fetch("MI_SOCIAL_REGISTRATION_ENABLED", nil)
        ENV["MI_SOCIAL_REGISTRATION_ENABLED"] = "true"
        @calls = []
        calls = @calls
        @handoff = Class.new do
          define_singleton_method(:available?) { true }
          define_singleton_method(:issue) do |**attributes|
            calls << attributes
            "https://mi.example.test/social/register/opaque-token"
          end
        end
      end

      teardown do
        @original_enabled.nil? ? ENV.delete("MI_SOCIAL_REGISTRATION_ENABLED") : ENV["MI_SOCIAL_REGISTRATION_ENABLED"] = @original_enabled
      end

      test "feature gate and handoff availability keep ordinary guidance untouched" do
        ENV["MI_SOCIAL_REGISTRATION_ENABLED"] = "false"

        reply = SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(text: "zelim da otvorim nalog"),
          cache: @cache,
          handoff: @handoff
        )

        assert_nil reply
        assert_empty @calls
      end

      test "an enabled registration request stays deterministic when handoff is unavailable" do
        unavailable = Class.new do
          define_singleton_method(:available?) { false }
        end

        reply = SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(text: "zelim da otvorim nalog"),
          cache: @cache,
          handoff: unavailable
        )

        assert_match(/nije dostupna/i, reply.text)
        expired_phone = SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(text: "065123456"),
          cache: @cache,
          handoff: unavailable
        )

        assert_match(/registracija je istekla/i, expired_phone.text)
        assert_empty @calls
      end

      test "Messenger registration intent asks for a phone and requests native phone quick reply" do
        reply = SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(channel: "messenger", text: "Zelim da otvorim nalog"),
          cache: @cache,
          handoff: @handoff
        )

        assert_equal "registration_intake", reply.answer_intent
        assert reply.request_phone
        assert_in_delta 10.minutes.from_now.to_f, reply.expires_at.to_f, 2
        assert_match(/broj mobilnog telefona/i, reply.text)
        assert_empty @calls
      end

      test "Instagram registration asks for typed phone without Messenger quick reply" do
        reply = SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(channel: "instagram", text: "otvori nalog"),
          cache: @cache,
          handoff: @handoff
        )

        assert_equal false, reply.request_phone
      end

      test "accepted phone issues handoff, normalizes it, and clears private state" do
        sender = "opaque-messenger-sender"
        SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(sender:, channel: "messenger", text: "otvori nalog"),
          cache: @cache,
          handoff: @handoff
        )

        reply = SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(sender:, channel: "messenger", text: "+387 65 123-456"),
          cache: @cache,
          handoff: @handoff
        )

        assert_match(%r{https://mi\.example\.test/}, reply.text)
        assert_equal(
          {
            organization: @organization,
            channel: "messenger",
            sender:,
            phone: "+38765123456"
          },
          @calls.sole
        )
        expired = SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(sender:, channel: "messenger", text: "+387 65 123-456"),
          cache: @cache,
          handoff: @handoff
        )
        assert_match(/registracija je istekla/i, expired.text)
        assert_equal 1, @calls.size
        assert_not_includes @cache.instance_variable_get(:@data).keys.to_json, sender
        assert_not_includes @cache.instance_variable_get(:@data).values.to_json, "38765123456"
      end

      test "invalid input keeps pending state and cancel returns a bounded reply" do
        sender = "opaque-instagram-sender"
        intake = lambda do |text|
          SocialRegistrationIntake.call(
            organization: @organization,
            message: inbound_message(sender:, channel: "instagram", text:),
            cache: @cache,
            handoff: @handoff
          )
        end

        intake.call("registruj me")
        invalid = intake.call("ovo nije broj")
        assert_match(/nije prepoznat/i, invalid.text)
        assert_match(/\+387 6X XXX XXX/, invalid.text)
        assert_match(%r{https://mi\.example\.test/}, intake.call("065123456").text)

        intake.call("otvori nalog")
        cancelled = intake.call("odustani")
        assert_match(/prekinula/i, cancelled.text)
        assert_match(/registracija je istekla/i, intake.call("065123456").text)
      end

      test "a phone reply after the private state expires gets restart guidance before general chat" do
        sender = "expired-messenger-sender"
        intake = lambda do |text|
          SocialRegistrationIntake.call(
            organization: @organization,
            message: inbound_message(sender:, channel: "messenger", text:),
            cache: @cache,
            handoff: @handoff
          )
        end

        intake.call("otvori nalog")
        travel 16.minutes
        reply = intake.call("065123456")

        assert_match(/registracija je istekla/i, reply.text)
        assert_empty @calls
        assert_not_includes reply.text, "065123456"
      ensure
        travel_back
      end

      test "an explicitly normalized shared phone can be handed off without entering text history" do
        reply = SocialRegistrationIntake.call(
          organization: @organization,
          message: inbound_message(channel: "messenger", text: "otvori nalog", shared_phone: "+38765123456"),
          cache: @cache,
          handoff: @handoff
        )

        assert_match(%r{https://mi\.example\.test/}, reply.text)
        assert_equal "+38765123456", @calls.sole.fetch(:phone)
      end

      private

      def inbound_message(text:, channel: "messenger", sender: "opaque-social-sender", shared_phone: nil)
        Message.new(channel:, sender:, text:, shared_phone:)
      end
    end
  end
end
