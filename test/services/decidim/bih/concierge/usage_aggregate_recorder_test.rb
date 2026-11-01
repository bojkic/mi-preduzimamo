# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Concierge
      class UsageAggregateRecorderTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
        end

        test "increments a daily aggregate row without storing conversation identifiers" do
          Decidim::Bih::Concierge::UsageAggregateRecorder.call(
            organization: @organization,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            message_length: 35,
            reply_length: 120,
            quick_replies_count: 2,
            sticker_present: true,
            occurred_at: Time.zone.local(2026, 6, 29, 10, 0, 0)
          )
          Decidim::Bih::Concierge::UsageAggregateRecorder.call(
            organization: @organization,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            message_length: 15,
            reply_length: 80,
            quick_replies_count: 0,
            occurred_at: Time.zone.local(2026, 6, 29, 11, 0, 0)
          )

          aggregate = Decidim::Bih::ConciergeUsageAggregate.find_by!(
            organization: @organization,
            bucket_on: Date.new(2026, 6, 29),
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr"
          )

          assert_equal 2, aggregate.requests_count
          assert_equal 50, aggregate.message_length_total
          assert_equal 200, aggregate.reply_length_total
          assert_equal 2, aggregate.quick_replies_total
          assert_equal 1, aggregate.sticker_count
          Decidim::Bih::ConciergeUsageAggregate::DIALOGUE_COUNTER_COLUMNS.each do |column|
            assert_equal 0, aggregate.public_send(column), "expected historical caller to leave #{column} unknown"
          end

          stored = aggregate.attributes.to_s
          assert_not_includes stored, "private citizen prompt"
          assert_not_includes stored, "private bot reply"
          assert_not_includes stored, "reply-id"
          assert_not_includes stored, "session"
          assert_not_includes stored, "38765"
        end

        test "bounds labels and floors negative counters" do
          Decidim::Bih::Concierge::UsageAggregateRecorder.call(
            organization: @organization,
            channel: "unknown-channel",
            outcome: "unexpected-outcome",
            answer_intent: "=cmd",
            locale: "",
            message_length: -10,
            reply_length: -20,
            quick_replies_count: -1,
            occurred_at: Time.zone.local(2026, 6, 29, 10, 0, 0)
          )

          aggregate = Decidim::Bih::ConciergeUsageAggregate.find_by!(organization: @organization)
          assert_equal "web_chat", aggregate.channel
          assert_equal "error", aggregate.outcome
          assert_equal "unknown", aggregate.answer_intent
          assert_equal I18n.default_locale.to_s, aggregate.locale
          assert_equal 1, aggregate.requests_count
          assert_equal 0, aggregate.message_length_total
          assert_equal 0, aggregate.reply_length_total
          assert_equal 0, aggregate.quick_replies_total
        end

        test "does nothing without an organization" do
          assert_no_difference -> { Decidim::Bih::ConciergeUsageAggregate.count } do
            Decidim::Bih::Concierge::UsageAggregateRecorder.call(
              organization: nil,
              channel: "web_chat",
              outcome: "success",
              answer_intent: "help"
            )
          end
        end

        test "normalizes additive truthful dimensions without changing historical outcome buckets" do
          dimensions = Decidim::Bih::Concierge::UsageAggregateRecorder.outcome_dimensions(
            resolution: "submitted",
            handoff_offered: true,
            handoff_completed: true,
            grounded_answer: true,
            action_receipt: true
          )

          assert_equal "submitted", dimensions.resolution
          assert dimensions.handoff_offered
          assert dimensions.handoff_completed
          assert dimensions.grounded_answer
          assert dimensions.action_receipt
          assert_equal %w(success blank fallback error), Decidim::Bih::ConciergeUsageAggregate::OUTCOMES
        end

        test "bounds unknown additive resolution and flags without mutating persisted counters" do
          dimensions = Decidim::Bih::Concierge::UsageAggregateRecorder.outcome_dimensions(
            resolution: "invented",
            handoff_offered: 1,
            handoff_completed: "yes",
            grounded_answer: nil,
            action_receipt: false
          )

          assert_equal "unsupported", dimensions.resolution
          refute dimensions.handoff_offered
          refute dimensions.handoff_completed
          refute dimensions.grounded_answer
          refute dimensions.action_receipt
        end

        test "increments each fixed resolution counter without changing aggregate identity" do
          recorder = Decidim::Bih::Concierge::UsageAggregateRecorder
          occurred_at = Time.zone.local(2026, 6, 29, 10, 0, 0)

          recorder::RESOLUTIONS.each do |resolution|
            recorder.call(
              organization: @organization,
              channel: "web_chat",
              outcome: "success",
              answer_intent: "waste",
              locale: "sr",
              occurred_at:,
              outcome_dimensions: recorder.outcome_dimensions(resolution:)
            )
          end

          assert_equal 1, Decidim::Bih::ConciergeUsageAggregate.where(organization: @organization).count
          aggregate = Decidim::Bih::ConciergeUsageAggregate.find_by!(organization: @organization)
          assert_equal recorder::RESOLUTIONS.size, aggregate.requests_count
          recorder::RESOLUTION_COUNTERS.slice(*recorder::PERSISTED_RESOLUTIONS).each_value do |column|
            assert_equal 1, aggregate.public_send(column), "expected #{column} to increment exactly once"
          end
        end

        test "provider_unavailable and busy count the turn but have no counter column yet" do
          recorder = Decidim::Bih::Concierge::UsageAggregateRecorder
          assert_equal %w(busy provider_unavailable), (recorder::RESOLUTIONS - recorder::PERSISTED_RESOLUTIONS).sort

          %w(provider_unavailable busy).each do |resolution|
            recorder.call(
              organization: @organization,
              channel: "web_chat",
              outcome: "fallback",
              answer_intent: "service",
              outcome_dimensions: recorder.outcome_dimensions(resolution:, handoff_offered: true)
            )
          end

          aggregate = Decidim::Bih::ConciergeUsageAggregate.find_by!(organization: @organization, outcome: "fallback")
          assert_equal 2, aggregate.requests_count
          assert_equal 2, aggregate.handoff_offered_count
          assert_not aggregate.has_attribute?("resolution_provider_unavailable_count")
          assert_not aggregate.has_attribute?("resolution_busy_count")
          Decidim::Bih::ConciergeUsageAggregate::DIALOGUE_COUNTER_COLUMNS.grep(/\Aresolution_/).each do |column|
            assert_equal 0, aggregate.public_send(column), "#{column} must not absorb a column-less resolution"
          end
        end

        test "increments only server-observed true evidence flags" do
          recorder = Decidim::Bih::Concierge::UsageAggregateRecorder
          dimensions = recorder::OutcomeDimensions.new(
            resolution: "submitted",
            handoff_offered: -1,
            handoff_completed: "yes",
            grounded_answer: true,
            action_receipt: true
          )

          recorder.call(
            organization: @organization,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "report_guidance",
            outcome_dimensions: dimensions
          )

          aggregate = Decidim::Bih::ConciergeUsageAggregate.find_by!(organization: @organization)
          assert_equal 1, aggregate.resolution_submitted_count
          assert_equal 0, aggregate.handoff_offered_count
          assert_equal 0, aggregate.handoff_completed_count
          assert_equal 1, aggregate.grounded_answer_count
          assert_equal 1, aggregate.action_receipt_count
        end

        test "ignores an untyped outcome hash while preserving the legacy aggregate" do
          Decidim::Bih::Concierge::UsageAggregateRecorder.call(
            organization: @organization,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "help",
            message_length: 12,
            outcome_dimensions: {
              resolution: "submitted", handoff_completed: true, action_receipt: true
            }
          )

          aggregate = Decidim::Bih::ConciergeUsageAggregate.find_by!(organization: @organization)
          assert_equal 1, aggregate.requests_count
          assert_equal 12, aggregate.message_length_total
          Decidim::Bih::ConciergeUsageAggregate::DIALOGUE_COUNTER_COLUMNS.each do |column|
            assert_equal 0, aggregate.public_send(column), "expected untyped input not to increment #{column}"
          end
        end

        test "keeps saving legacy counters when outcome columns are not installed" do
          legacy = Struct.new(
            :requests_count, :message_length_total, :reply_length_total,
            :quick_replies_total, :sticker_count, :saved, keyword_init: true
          ).new(
            requests_count: 0, message_length_total: 0, reply_length_total: 0,
            quick_replies_total: 0, sticker_count: 0, saved: false
          )
          legacy.define_singleton_method(:with_lock) { |&block| block.call }
          legacy.define_singleton_method(:has_attribute?) { |_column| false }
          legacy.define_singleton_method(:save!) { self.saved = true }

          dimensions = Decidim::Bih::Concierge::UsageAggregateRecorder.outcome_dimensions(
            resolution: "answered", grounded_answer: true
          )
          recorder = Decidim::Bih::Concierge::UsageAggregateRecorder.new(
            organization: @organization,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "help",
            message_length: 9,
            outcome_dimensions: dimensions
          )
          recorder.define_singleton_method(:find_or_create_aggregate) { legacy }

          assert_same legacy, recorder.call
          assert legacy.saved
          assert_equal 1, legacy.requests_count
          assert_equal 9, legacy.message_length_total
        end

        test "safety guidance persists separately and leaves historical answers and feedback untouched" do
          recorder = Decidim::Bih::Concierge::UsageAggregateRecorder
          common = { organization: @organization, channel: "web_chat", answer_intent: "safety", locale: "sr" }
          historical = recorder.call(**common, outcome: "success", outcome_dimensions: recorder.outcome_dimensions(resolution: "answered"))
          original = historical.attributes
          assert_no_difference -> { Decidim::Bih::ConciergeFeedback.count } do
            recorder.call(**common, outcome: "fallback", outcome_dimensions: recorder.outcome_dimensions(resolution: "safety_guidance"))
          end
          safety = Decidim::Bih::ConciergeUsageAggregate.find_by!(**common, outcome: "fallback")

          assert_equal original, historical.reload.attributes
          assert_equal 0, historical.resolution_safety_guidance_count
          assert_equal 1, safety.requests_count
          assert_equal 1, safety.resolution_safety_guidance_count
          assert_equal 0, safety.resolution_answered_count
          assert_equal 0, safety.resolution_submitted_count
          assert_equal 0, safety.action_receipt_count
          assert_equal 2, Decidim::Bih::ConciergeUsageAggregate.where(organization: @organization).sum(:requests_count)
        end

        test "database rejects negative safety guidance counts independently of model validation" do
          aggregate = Decidim::Bih::Concierge::UsageAggregateRecorder.call(
            organization: @organization, channel: "web_chat", outcome: "fallback", answer_intent: "safety"
          )
          assert_equal 0, aggregate.resolution_safety_guidance_count
          assert_raises(ActiveRecord::StatementInvalid) do
            aggregate.class.transaction(requires_new: true) do
              # Bypass Ruby validation to prove the database constraint itself.
              aggregate.update_columns(resolution_safety_guidance_count: -1) # rubocop:disable Rails/SkipsModelValidations
            end
          end
          assert_equal 0, aggregate.reload.resolution_safety_guidance_count
          aggregate.resolution_safety_guidance_count = -1
          assert_not aggregate.valid?
          assert aggregate.errors[:resolution_safety_guidance_count].any?
        end

        test "rejects negative installed outcome counters" do
          Decidim::Bih::Concierge::UsageAggregateRecorder.call(
            organization: @organization,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "help"
          )
          aggregate = Decidim::Bih::ConciergeUsageAggregate.find_by!(organization: @organization)

          aggregate.resolution_answered_count = -1

          refute aggregate.valid?
          assert aggregate.errors[:resolution_answered_count].any?
        end
      end
    end
  end
end
