# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Tests for the Broadcast audit record model — focusing on the
    # server-side message length cap (Komšiluk fix b).
    class BroadcastTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-bc-model-test",
          name: { "sr" => "Centar" }
        )
      end

      def build_broadcast(message:)
        Broadcast.new(
          organization: @organization,
          area: @area,
          sent_by: @admin,
          message:,
          channels: "bell",
          recipients_count: 0
        )
      end

      test "a message of 500 chars is valid" do
        bc = build_broadcast(message: "a" * 500)
        assert bc.valid?, bc.errors.full_messages.inspect
      end

      test "a message over 500 chars is invalid" do
        bc = build_broadcast(message: "a" * 501)
        assert_not bc.valid?
        assert_includes bc.errors.attribute_names, :message
      end

      test "a blank message is still invalid (presence preserved)" do
        bc = build_broadcast(message: "")
        assert_not bc.valid?
        assert_includes bc.errors.attribute_names, :message
      end
    end
  end
end
