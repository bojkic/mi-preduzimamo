# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Decidim
  module Bih
    module Admin
      # Database half of the rolling chat answer-quality alert: the real
      # grouped query, the real window boundary and tenant separation.
      #
      # The rule itself (thresholds, statuses, labels, incident keys) is
      # covered without a database by the engine test of the same name.
      class ChatFeedbackAlertTest < ActiveSupport::TestCase
        NOW = Time.utc(2026, 9, 14, 9, 0)

        setup do
          @organization = create_organization
          @other_organization = create_organization
        end

        test "a bucket over the threshold alerts and reports its rated-turn share" do
          rate(intent: "service", negative: 6, positive: 1)

          row = alert.rows.first

          assert_equal ChatFeedbackAlert::ALERT, row[:status]
          assert_equal "chat_feedback.service.sr", row[:incident_key]
          assert_equal 7, row[:rated_turns]
          assert_equal 6, row[:negative_turns]
          assert_equal 86, row[:negative_share_percent]
          assert_equal "rated_turn_feedback", row[:measure]
        end

        test "a bucket under the minimum is insufficient evidence and carries no percentage" do
          rate(intent: "setup", negative: 4)

          row = alert.rows.first

          assert_equal ChatFeedbackAlert::INSUFFICIENT, row[:status]
          assert_nil row[:negative_share_percent]
          assert_empty alert.alerting_rows
        end

        test "ratings outside the window are not counted" do
          rate(intent: "service", negative: 6, at: NOW - 8.days)
          rate(intent: "service", negative: 1, at: NOW - 1.day)

          row = alert.rows.first

          assert_equal 1, row[:rated_turns]
          assert_equal ChatFeedbackAlert::INSUFFICIENT, row[:status]
        end

        test "a rating exactly at the window edge is inside it" do
          rate(intent: "service", negative: 5, at: NOW - 7.days + 1.second)

          assert_equal ChatFeedbackAlert::ALERT, alert.rows.first[:status]
        end

        test "another organization's ratings never reach this organization's alert" do
          rate(intent: "service", negative: 6, organization: @other_organization)
          rate(intent: "service", negative: 1)

          assert_empty alert.alerting_rows
          assert_equal 1, alert.rated_turns_total
          assert_equal 6, alert(organization: @other_organization).rated_turns_total
          assert_equal 1, alert(organization: @other_organization).alerting_rows.size
        end

        test "buckets are separated by locale" do
          rate(intent: "service", negative: 6, locale: "sr")
          rate(intent: "service", negative: 6, locale: "sr-Cyrl")

          keys = alert.alerting_rows.map { |row| row[:incident_key] }

          assert_equal ["chat_feedback.service.sr", "chat_feedback.service.sr-Cyrl"], keys.sort
        end

        # A consent click is not a rating. Counting it would inflate the
        # denominator and silence a bucket that should alert.
        test "share_question consent clicks are not rated turns" do
          rate(intent: "service", negative: 5)
          rate(intent: "service", value: "share_question", count: 20)

          row = alert.rows.first

          assert_equal 5, row[:rated_turns]
          assert_equal ChatFeedbackAlert::ALERT, row[:status]
        end

        # The reason the rule is keyed on answer_intent and not on outcome:
        # every feedback row the platform has ever stored carries
        # outcome "success", including refusals.
        test "the bucket ignores the outcome metadata field" do
          rate(intent: "service", negative: 3, outcome: "success")
          rate(intent: "service", negative: 3, outcome: "fallback")

          assert_equal 1, alert.rows.size
          assert_equal ChatFeedbackAlert::ALERT, alert.rows.first[:status]
        end

        test "missing intent metadata falls into an explicit unknown bucket" do
          rate(intent: nil, negative: 6)

          assert_equal "chat_feedback.unknown.sr", alert.rows.first[:incident_key]
        end

        test "repeated runs over unchanged data produce identical rows" do
          rate(intent: "service", negative: 6)

          assert_equal alert.rows, alert.rows
        end

        test "an organization with no ratings produces no rows and no alert" do
          assert_empty alert.rows
          assert_empty alert.alerting_rows
          assert_equal 0, alert.rated_turns_total
        end

        test "the analytics summary hands back the same bounded-window alert" do
          rate(intent: "service", negative: 6)
          summary = Decidim::Bih::Admin::AnalyticsSummary.new(organization: @organization, now: NOW)

          assert_equal alert.rows, summary.chat_feedback_alert.rows
        end

        private

        def alert(organization: @organization, **)
          ChatFeedbackAlert.new(organization:, now: NOW, **)
        end

        # rubocop:disable Metrics/ParameterLists
        def rate(intent:, negative: 0, positive: 0, count: nil, value: nil, locale: "sr", outcome: "success",
                 at: NOW - 1.day, organization: @organization)
          if value
            count.times { create_feedback(intent:, value:, locale:, outcome:, at:, organization:) }
            return
          end
          negative.times { create_feedback(intent:, value: "not_helpful", locale:, outcome:, at:, organization:) }
          positive.times { create_feedback(intent:, value: "helpful", locale:, outcome:, at:, organization:) }
        end
        # rubocop:enable Metrics/ParameterLists

        def create_feedback(intent:, value:, locale:, outcome:, at:, organization:) # rubocop:disable Metrics/ParameterLists
          Decidim::Bih::ConciergeFeedback.create!(
            organization:,
            reply_id: SecureRandom.uuid,
            session_digest: SecureRandom.hex(8),
            value:,
            locale:,
            metadata: { "outcome" => outcome, "answer_intent" => intent }.compact,
            created_at: at,
            updated_at: at
          )
        end
      end
    end
  end
end
