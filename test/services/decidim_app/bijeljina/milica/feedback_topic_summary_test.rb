# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class FeedbackTopicSummaryTest < ActiveSupport::TestCase
        test "feedback summary groups existing ratings without transcripts and preserves unknown historical attribution" do
          organization = create_organization
          now = Time.utc(2026, 9, 9, 12)
          rating(organization, now - 1.hour, "not_helpful", topic: "water", intent: "service")
          rating(organization, now - 1.hour, "helpful", intent: "budget")
          rating(organization, now - 1.hour, "not_helpful", intent: "service")
          rating(organization, now - 1.hour, "not_helpful", topic: "Private street", intent: "Private message")
          rating(organization, now - 25.hours, "not_helpful", topic: "water")
          rating(create_organization, now - 1.hour, "not_helpful", topic: "water")
          sql = []
          callback = ->(*arguments) { sql << arguments.last.fetch(:sql) }
          result = nil
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            result = FeedbackTopicSummary.new.call(organization:, now:)
          end
          rows = result.fetch(:rows).index_by { |row| row.fetch(:topic) }
          assert_equal 1, rows.fetch("water").fetch(:not_helpful)
          assert_equal "recorded_typed_topic", rows.fetch("water").fetch(:attribution)
          assert_equal 1, rows.fetch("budget").fetch(:helpful)
          assert_equal "bounded_answer_intent_mapping", rows.fetch("budget").fetch(:attribution)
          assert_equal 2, rows.fetch("unknown").fetch(:not_helpful)
          assert_equal "unknown", rows.fetch("unknown").fetch(:attribution)
          assert_not_includes result.to_json, "Private"
          queries = sql.select { |query| query.include?("decidim_bih_concierge_feedbacks") }
          assert queries.any?
          assert(queries.all? { |query| !query.match?(/citizen_message|bot_reply_text|session_digest|reply_id/) })
        end

        private

        def rating(organization, at, value, topic: nil, intent: "unknown")
          Decidim::Bih::ConciergeFeedback.create!(organization:, reply_id: SecureRandom.uuid, session_digest: SecureRandom.hex(32), value:,
                                                  metadata: { topic:, answer_intent: intent }.compact, citizen_message: "Private fixture transcript",
                                                  bot_reply_text: "Private fixture answer", created_at: at, updated_at: at)
        end
      end
    end
  end
end
