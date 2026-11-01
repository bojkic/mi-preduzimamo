# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Admin
      class ReportTriageSummaryTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @now = Time.zone.local(2026, 6, 18, 12, 0, 0)
        end

        test "builds organization-scoped attention buckets without report PII" do
          old_received = report!(
            description: "Private triage received description",
            address: "Private triage received address",
            created_at: @now - 3.days
          )
          stale_city = report!(
            description: "Private triage stale description",
            address: "Private triage stale address",
            status: "u_obradi", review_state: "validated", forwarded_at: @now - 45.days,
            created_at: @now - 45.days
          )
          failed = report!(
            description: "Private triage failed description",
            address: "Private triage failed address",
            created_at: @now - 1.day
          )
          failed.record_forwarding_failure!(StandardError.new("Private triage timeout"), code: "private_timeout")
          failed.update_columns(forwarding_failed_at: @now - 4.days, updated_at: @now - 4.days) # rubocop:disable Rails/SkipsModelValidations
          report!(
            description: "Private triage review description",
            address: "Private triage review address",
            needs_review: true,
            created_at: @now - 1.day
          )
          other = report!(
            organization: create_organization,
            description: "Other private triage description",
            address: "Other private triage address",
            needs_review: true,
            created_at: @now - 45.days
          )
          other.record_forwarding_failure!(StandardError.new("Other private timeout"), code: "other_private")

          rows = summary.rows.index_by { |row| row[:bucket] }

          assert_not rows.has_key?("needs_review")
          assert_equal 1, rows.fetch("forwarding_failed").fetch(:count)
          assert_equal "high", rows.fetch("forwarding_failed").fetch(:review_priority)
          assert_equal "retry_forwarding", rows.fetch("forwarding_failed").fetch(:review_action)
          assert_equal "2026-06-14", rows.fetch("forwarding_failed").fetch(:oldest_attention_on)
          assert_equal "2026-06-17", rows.fetch("forwarding_failed").fetch(:oldest_reported_on)
          assert_equal 1, rows.fetch("received_over_sla").fetch(:count)
          assert_equal "high", rows.fetch("received_over_sla").fetch(:review_priority)
          assert_equal "forward_received_report", rows.fetch("received_over_sla").fetch(:review_action)
          assert_equal (old_received.created_at + 2.days).to_date.iso8601, rows.fetch("received_over_sla").fetch(:oldest_attention_on)
          assert_equal 1, rows.fetch("stale_city_followup").fetch(:count)
          assert_equal "watch", rows.fetch("stale_city_followup").fetch(:review_priority)
          assert_equal "check_city_followup", rows.fetch("stale_city_followup").fetch(:review_action)
          assert_equal (stale_city.forwarded_at + ReportWorkQueue::CITY_DAYS.days).to_date.iso8601, rows.fetch("stale_city_followup").fetch(:oldest_attention_on)

          rendered = rows.values.map(&:to_s).join("\n")
          assert_not_includes rendered, "Private triage"
          assert_not_includes rendered, "Other private"
          assert_not_includes rendered, "private_timeout"
          assert_not_includes rendered, old_received.reference
          assert_not_includes rendered, failed.reference
        end

        test "empty attention buckets remain monitor-only" do
          rows = summary.rows.index_by { |row| row[:bucket] }

          rows.each_value do |row|
            assert_equal 0, row.fetch(:count)
            assert_equal "monitor", row.fetch(:review_priority)
            assert_equal "continue_monitoring", row.fetch(:review_action)
          end
        end

        test "scope_for applies a bucket to an existing filtered scope" do
          matching = report!(mz_slug: "mz-one", created_at: @now - 3.days)
          report!(mz_slug: "mz-two", created_at: @now - 3.days)
          report!(mz_slug: "mz-one", created_at: @now - 1.day)

          scoped = summary.scope_for(
            "received_over_sla",
            base_scope: Decidim::Bih::Report.where(organization: @organization, mz_slug: "mz-one")
          )

          assert_equal [matching.id], scoped.pluck(:id)
        end

        test "report_rows builds a bounded pii-minimized escalation queue" do
          old_received = report!(
            description: "Private queue received description",
            address: "Private queue received address",
            category: "putevi",
            mz_slug: "mz-one",
            created_at: @now - 3.days
          )
          stale_city = report!(
            description: "Private queue stale description",
            address: "Private queue stale address",
            status: "u_obradi",
            category: "rasvjeta",
            mz_slug: "mz-two",
            created_at: @now - 45.days
          )
          failed = report!(
            description: "Private queue failed description",
            address: "Private queue failed address",
            needs_review: true,
            category: "vodovod_kanalizacija",
            created_at: @now - 1.day
          )
          failed.record_forwarding_failure!(StandardError.new("Private queue timeout"), code: "private_queue")
          failed.update_columns(forwarding_failed_at: @now - 4.days, updated_at: @now - 4.days) # rubocop:disable Rails/SkipsModelValidations
          report!(
            organization: create_organization,
            description: "Other private queue description",
            address: "Other private queue address",
            needs_review: true,
            created_at: @now - 45.days
          )

          rows = summary.report_rows(limit: 10)

          assert_equal [failed.reference, old_received.reference, stale_city.reference], rows.pluck(:reference)
          assert_equal "forwarding_failed", rows.first.fetch(:bucket)
          assert_equal "high", rows.first.fetch(:review_priority)
          assert_equal "retry_forwarding", rows.first.fetch(:review_action)
          assert_equal @now - 4.days, rows.first.fetch(:attention_at)
          assert_equal "putevi", rows.second.fetch(:category)
          assert_equal "mz-one", rows.second.fetch(:mz_slug)

          rendered = rows.map(&:to_s).join("\n")
          assert_not_includes rendered, "Private queue"
          assert_not_includes rendered, "Other private"
          assert_not_includes rendered, "private_queue"
          assert_not_includes rendered, old_received.address
          assert_not_includes rendered, failed.description
        end

        test "report_rows can focus one bucket on an existing filtered scope" do
          matching = report!(mz_slug: "mz-one", created_at: @now - 3.days)
          report!(mz_slug: "mz-two", created_at: @now - 3.days)
          report!(mz_slug: "mz-one", created_at: @now - 1.day)

          rows = summary.report_rows(
            bucket: "received_over_sla",
            base_scope: Decidim::Bih::Report.where(organization: @organization, mz_slug: "mz-one"),
            limit: 10
          )

          assert_equal [matching.reference], rows.pluck(:reference)
          assert_equal ["received_over_sla"], rows.pluck(:bucket)
        end

        private

        def summary
          Decidim::Bih::Admin::ReportTriageSummary.new(organization: @organization, now: @now)
        end

        def report!(organization: @organization, created_at: @now, **attributes)
          Decidim::Bih::Report.create!(
            {
              organization:,
              description: "Routine report",
              address: "Routine address",
              created_at:,
              updated_at: created_at
            }.merge(attributes)
          )
        end
      end
    end
  end
end
