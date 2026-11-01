# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class ChannelConversationContextTest < ActiveSupport::TestCase
        setup do
          @organization = Struct.new(:id).new(7)
          @now = Time.utc(2026, 9, 16)
        end

        def scope(channel: "instagram", sender: "opaque-sender", user: nil)
          ChannelConversationContext.call(organization: @organization, channel:, sender:, user:, now: @now)
        end

        test "public continuity does not depend on report switch or grant report authority" do
          context = scope
          assert context.allows?("public_reads")
          assert context.allows?("report_guidance")
          assert_not context.allows?("write_report")
          assert_nil context.actor_id
          assert_equal ChatReportIntake.conversation_key(organization: @organization, channel: "instagram", sender: "opaque-sender"), context.conversation_key
          assert_not_includes context.conversation_key, "opaque-sender"
        end

        test "channel sender and actor transitions cannot inherit each other's frame" do
          base = scope
          user = Struct.new(:id, :decidim_organization_id, :deleted?, :blocked?).new(13, 7, false, false)
          assert_not_equal base.conversation_key, scope(channel: "messenger").conversation_key
          assert_not_equal base.conversation_key, scope(sender: "another-sender").conversation_key
          linked = scope(user:)
          assert_not_equal base.conversation_key, linked.conversation_key
          assert_equal 13, linked.actor_id
          assert_equal "registered", linked.account_state
          assert_not linked.allows?("write_report")
        end

        test "foreign blocked and deleted actors fail before building authorized context" do
          klass = Struct.new(:id, :decidim_organization_id, :deleted?, :blocked?)
          [klass.new(13, 8, false, false), klass.new(13, 7, true, false), klass.new(13, 7, false, true)].each do |user|
            assert_raises(Decidim::Bih::Concierge::Dialogue::Contracts::Invalid) { scope(user:) }
          end
        end
      end
    end
  end
end
