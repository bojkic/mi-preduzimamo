# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "sidekiq/api"

module Decidim
  module Bih
    module Admin
      class ChatHealthSummaryTest < ActiveSupport::TestCase
        FakeSet = Struct.new(:jobs) do
          def scan(_match)
            jobs
          end
        end
        FakeEntry = Struct.new(:display_class)

        setup do
          @organization = create_organization
          @now = Time.zone.local(2026, 9, 13, 12)
          @today = Date.new(2026, 9, 13)
        end

        def summary(period_days: 7)
          ChatHealthSummary.new(organization: @organization, period_days:, now: @now)
        end

        def usage!(bucket_on:, outcome: "success", requests: 1, **counts)
          Decidim::Bih::ConciergeUsageAggregate.create!(
            {
              organization: @organization, bucket_on:, channel: "web_chat", outcome:,
              answer_intent: outcome == "success" ? "waste" : "fallback", locale: "sr", requests_count: requests
            }.merge(counts)
          )
        end

        def receipt!(channel:, state:, received_at:)
          Decidim::Bih::Viber::InboundDelivery.create!(
            organization: @organization, channel:, state:, phase: state == "processed" ? "complete" : "handler",
            provider_message_key: SecureRandom.hex(32), received_at:, expires_at: received_at + 7.days
          )
        end

        def rollup!(**attributes)
          Decidim::Bih::ConciergeMetricRollup.create!(
            { organization: @organization, latency_bucket: nil, release_sha: "b" * 40, prompt_version: 1 }.merge(attributes)
          )
        end

        test "period is bounded to the offered choices" do
          assert_equal 7, ChatHealthSummary.period(nil)
          assert_equal 7, ChatHealthSummary.period("abc")
          assert_equal 7, ChatHealthSummary.period(12)
          assert_equal 30, ChatHealthSummary.period("30")
          assert_equal((@today - 6)..@today, summary.period_range)
          assert_equal((@today - 29)..@today, summary(period_days: 30).period_range)
        end

        test "resolution counters sum the daily columns and leave uncolumned resolutions unknown" do
          usage!(bucket_on: @today, requests: 6, resolution_answered_count: 3, resolution_clarification_count: 1,
                 resolution_handoff_count: 2)
          usage!(bucket_on: @today - 3, requests: 2, resolution_unsupported_count: 1, resolution_source_unavailable_count: 1)
          usage!(bucket_on: @today - 10, requests: 5, resolution_answered_count: 5)
          usage!(bucket_on: @today, outcome: "fallback", requests: 2)
          usage!(bucket_on: @today - 1, outcome: "error", requests: 1)

          seven = summary.resolutions
          assert_equal 3, seven.fetch("answered")
          assert_equal 1, seven.fetch("clarification")
          assert_equal 2, seven.fetch("handoff")
          assert_equal 1, seven.fetch("unsupported")
          assert_equal 1, seven.fetch("source_unavailable")
          assert_nil seven.fetch("provider_unavailable")
          assert_nil seven.fetch("busy")
          assert_equal 8, summary(period_days: 30).resolutions.fetch("answered")

          assert_equal({ "fallback" => 2, "error" => 1, "requests" => 11 }, summary.failures)
          assert_equal 16, summary(period_days: 30).failures.fetch("requests")
        end

        test "an organization without aggregates reports zero for instrumented columns, not unknown" do
          assert_equal 0, summary.resolutions.fetch("answered")
          assert_equal({ "fallback" => 0, "error" => 0, "requests" => 0 }, summary.failures)
        end

        test "inbound receipts are counted per channel and state within the retention window" do
          receipt!(channel: "whatsapp", state: "processed", received_at: @now - 1.hour)
          receipt!(channel: "whatsapp", state: "failed", received_at: @now - 3.hours)
          receipt!(channel: "viber_bm", state: "processed", received_at: @now - 10.days)
          other = create_organization
          Decidim::Bih::Viber::InboundDelivery.create!(
            organization: other, channel: "whatsapp", state: "processed", phase: "complete",
            provider_message_key: SecureRandom.hex(32), received_at: @now - 1.hour, expires_at: @now + 6.days
          )

          rows = summary(period_days: 30).inbound_channels.index_by { |row| row[:channel] }

          whatsapp = rows.fetch("whatsapp")
          assert whatsapp[:instrumented]
          assert_equal 2, whatsapp[:total]
          assert_equal 1, whatsapp[:states].fetch("processed")
          assert_equal 1, whatsapp[:states].fetch("failed")
          assert_equal 0, whatsapp[:states].fetch("pending")
          assert_in_delta (@now - 1.hour).to_f, whatsapp[:last_inbound_at].to_f, 1.0

          viber_bm = rows.fetch("viber_bm")
          assert_equal 0, viber_bm[:total], "receipts older than retention are outside the readable window"
          assert_nil viber_bm[:last_inbound_at]

          web = rows.fetch("web_chat")
          assert_not web[:instrumented]
          assert_nil web[:total]
          assert_nil web[:states]

          assert_equal 7, summary(period_days: 30).inbound_window_days
          assert summary(period_days: 30).inbound_window_clamped?
          assert_not summary.inbound_window_clamped?
          assert_equal %w(web_chat viber viber_bm whatsapp messenger instagram), rows.keys
        end

        test "exhausted sends count only the chat text job in the dead and retry sets" do
          dead = FakeSet.new([
                               FakeEntry.new("Decidim::Bih::Infobip::SendChatTextJob"),
                               FakeEntry.new("Decidim::Bih::Infobip::SendChatTextJob"),
                               FakeEntry.new("Decidim::Bih::Infobip::SendTemplateJob")
                             ])
          retrying = FakeSet.new([FakeEntry.new("Decidim::Bih::Infobip::SendChatTextJob")])

          result = Sidekiq::DeadSet.stub(:new, dead) do
            Sidekiq::RetrySet.stub(:new, retrying) { summary.exhausted_sends }
          end

          assert_equal({ available: true, dead: 2, retrying: 1 }, result)
        end

        test "unreadable sidekiq is unknown, never zero" do
          result = Sidekiq::DeadSet.stub(:new, ->(*) { raise IOError, "redis down" }) { summary.exhausted_sends }

          assert_equal({ available: false, dead: nil, retrying: nil }, result)
        end

        test "rollup days, understanding latency and the release stamp come from the rollup table" do
          rollup!(day: @today - 1, kind: "answer", topic: "water", label: "answered", count: 8, release_sha: "a" * 40)
          rollup!(day: @today - 1, kind: "answer", topic: "water", label: "fallback", count: 2, release_sha: "a" * 40)
          # Today's rows were written by a newer release (prompt version 2); the stamp must come from them.
          rollup!(day: @today, kind: "answer", topic: "waste", label: "busy", count: 1, prompt_version: 2)
          rollup!(day: @today - 20, kind: "answer", topic: "waste", label: "answered", count: 4)
          rollup!(day: @today - 1, kind: "stage", topic: "understanding", label: "completed", latency_bucket: "250", count: 3)
          rollup!(day: @today, kind: "stage", topic: "understanding", label: "completed", latency_bucket: "1000", count: 1, prompt_version: 2)
          rollup!(day: @today, kind: "stage", topic: "understanding", label: "failed", latency_bucket: "overflow", count: 1, prompt_version: 2)
          rollup!(day: @today, kind: "stage", topic: "rendering", label: "completed", latency_bucket: "10", count: 5, prompt_version: 2)
          rollup!(day: @today, kind: "read", topic: "water", label: "ok", latency_bucket: "50", count: 9, prompt_version: 2)

          seven = summary
          assert seven.rollup_available?
          days = seven.rollup_days
          assert_equal([@today - 1, @today], days.map { |row| row[:day] })
          assert_equal({ day: @today - 1, answers: 10, technical_failures: 2, failure_rate_percent: 20.0 }, days.first)
          assert_equal({ day: @today, answers: 1, technical_failures: 1, failure_rate_percent: 100.0 }, days.last)
          assert_equal 3, summary(period_days: 30).rollup_days.size

          latency = seven.understanding_latency
          assert_equal 4, latency[:completed]
          assert_equal 1, latency[:failed]
          assert_equal "250", latency[:percentiles][:p50]
          assert_equal "1000", latency[:percentiles][:p95]
          assert_equal(Decidim::Bih::ConciergeMetricRollup::LATENCY_BUCKETS, latency[:buckets].map { |row| row[:bucket] })
          assert_equal 3, latency[:buckets].find { |row| row[:bucket] == "250" }[:completed]

          stamp = seven.release_stamp
          assert_equal "b" * 40, stamp[:release_sha]
          assert_equal 2, stamp[:prompt_version]
          assert_equal @today, stamp[:day]
        end

        test "without rollup rows every rollup-derived figure is unknown" do
          assert_not summary.rollup_available?
          assert_empty summary.rollup_days
          assert_nil summary.understanding_latency
          assert_nil summary.release_stamp
        end

        test "the analytics summary hands out one chat health reader per period" do
          analytics = Decidim::Bih::Admin::AnalyticsSummary.new(organization: @organization, now: @now)

          assert_same analytics.chat_health(period_days: 7), analytics.chat_health(period_days: 7)
          assert_equal 30, analytics.chat_health(period_days: 30).period_days
        end
      end
    end
  end
end
