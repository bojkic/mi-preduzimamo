# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # T10a — read model behind the admin "Goodwill economy" dashboard.
      # Verifies the headline figures, the bounded N-of-M queues, the
      # stale-report figures, and the cache-key behaviour the controller used to
      # compute inline. Behaviour-preserving extraction: these figures must match
      # what GoodwillController#index rendered before.
      class DashboardSummaryTest < ActiveSupport::TestCase
        setup do
          @previous_cache = Rails.cache
          Rails.cache = ActiveSupport::Cache::MemoryStore.new
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @alice = FactoryBot.create(:user, :confirmed, organization: @organization)
          @bob = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        teardown do
          Rails.cache = @previous_cache
        end

        def summary
          DashboardSummary.new(@organization).to_h
        end

        test "to_h exposes every key the dashboard view consumes" do
          expected = [
            :total_issued, :top_earners, :metrics, :anomalies, :anomaly_scan, :monitoring,
            :recent_redemptions, :recent_transactions,
            :pending_match_requests_total, :pending_match_requests,
            :approved_match_payouts_total, :approved_match_payouts,
            :recent_paid_match_requests_total, :recent_paid_match_requests,
            :pending_organization_spending_total, :pending_organization_spending,
            :pending_reward_fulfillments_total, :pending_reward_fulfillments,
            :report_forwarding_failures_total, :report_forwarding_failures,
            :stale_reports_count, :oldest_stale_report
          ]
          assert_equal expected.sort, summary.keys.sort
        end

        test "total_issued sums positive earn credits for the organization" do
          @ledger.award(@alice, 40, reason: "proposal")
          @ledger.award(@bob, 75, reason: "proposal")

          assert_equal 115, summary.fetch(:total_issued)
        end

        test "total_issued is scoped to the organization" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          @ledger.award(@alice, 40, reason: "proposal")
          @ledger.award(outsider, 999, reason: "proposal")

          assert_equal 40, summary.fetch(:total_issued)
        end

        test "top_earners lists contributors with display name and score" do
          @ledger.award(@alice, 40, reason: "proposal")

          row = summary.fetch(:top_earners).find { |r| r[:owner_id] == @alice.id }
          assert_not_nil row
          assert_equal @alice.name, row[:owner_name]
          assert_equal 40, row[:score]
        end

        test "metrics is the two-window snapshot" do
          metrics = summary.fetch(:metrics)
          assert metrics.has_key?(:current)
          assert metrics.has_key?(:previous)
          assert metrics.has_key?(:window_days)
        end

        test "recent_redemptions only includes redeem transactions" do
          @ledger.award(@alice, 600, reason: "proposal")
          Decidim::Bih::Goodwill::RedeemReward.call(@alice, "majica")

          kinds = summary.fetch(:recent_redemptions).map(&:kind).uniq
          assert_equal ["redeem"], kinds
        end

        test "recent_transactions is bounded to RECENT_LIMIT, newest first" do
          (DashboardSummary::RECENT_LIMIT + 5).times do |i|
            @ledger.award(@alice, 1, reason: "engagement", idempotency_key: "e#{i}")
          end

          recent = summary.fetch(:recent_transactions)
          assert_equal DashboardSummary::RECENT_LIMIT, recent.size
          timestamps = recent.map(&:created_at)
          assert_equal timestamps.sort.reverse, timestamps
        end

        test "volunteering queues remain owned by the dedicated roster" do
          opportunity = Decidim::Bih::VolunteerOpportunity.create!(
            organization: @organization, title: "Velika akcija", active: true
          )
          create_legacy_volunteer_log!(
            organization: @organization, opportunity:, user: @alice,
            hours: 1, status: "pending"
          )

          assert_not summary.has_key?(:pending_logs_total)
          assert_not summary.has_key?(:pending_logs)
          assert_not summary.has_key?(:pending_opportunities_total)
          assert_not summary.has_key?(:pending_opportunities)
        end

        test "queues are scoped to the organization" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          MatchRequest.create!(
            organization: other,
            owner: outsider,
            points: 50,
            status: "pending",
            created_by: outsider
          )

          assert_equal 0, summary.fetch(:pending_match_requests_total)
          assert_empty summary.fetch(:pending_match_requests)
        end

        test "pending match requests surface total and bounded list" do
          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          MatchRequest.create!(
            organization: @organization, owner: group, points: 50,
            status: "pending", created_by: @alice
          )

          assert_equal 1, summary.fetch(:pending_match_requests_total)
          assert_equal 1, summary.fetch(:pending_match_requests).size
        end

        test "pending organization spending requests surface total and bounded list" do
          source = partner_profile("Izvor", "izvor")
          target = partner_profile("Cilj", "cilj")
          Decidim::Bih::Goodwill::OrganizationSpendingRequest.create!(
            organization: @organization,
            source_partner_profile: source,
            target_partner_profile: target,
            requested_by: @alice,
            request_type: "inter_org_support",
            points: 50,
            category: "collaboration",
            status: "pending"
          )

          assert_equal 1, summary.fetch(:pending_organization_spending_total)
          assert_equal 1, summary.fetch(:pending_organization_spending).size
        end

        test "approved match payouts and recent paid requests are scoped queues" do
          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          approved = MatchRequest.create!(
            organization: @organization, owner: group, points: 50,
            status: "approved", created_by: @alice, decided_by: @alice,
            decided_at: 1.hour.ago
          )
          paid = MatchRequest.create!(
            organization: @organization, owner: group, points: 75,
            status: "approved", created_by: @alice, decided_by: @alice,
            decided_at: 2.hours.ago, payout_status: "paid",
            payout_amount_minor_units: 7_500, payout_currency: "BAM",
            payout_paid_on: Date.current, payout_reference: "BANK-75",
            payout_recorded_by: @alice, payout_recorded_at: 30.minutes.ago
          )
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          MatchRequest.create!(
            organization: other, owner: outsider, points: 500,
            status: "approved", created_by: outsider, decided_by: outsider,
            decided_at: 1.hour.ago
          )

          assert_equal 1, summary.fetch(:approved_match_payouts_total)
          assert_equal [approved.id], summary.fetch(:approved_match_payouts).map(&:id)
          assert_equal 1, summary.fetch(:recent_paid_match_requests_total)
          assert_equal [paid.id], summary.fetch(:recent_paid_match_requests).map(&:id)
        end

        def partner_profile(name, slug)
          Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: name,
            slug:,
            kind: "association",
            verification_status: "verified",
            verified_at: Time.current
          )
        end

        test "stale report figures are computed" do
          assert_equal 0, summary.fetch(:stale_reports_count)
          assert_nil summary.fetch(:oldest_stale_report)
        end

        test "the cached summary is reused until a new ledger transaction posts" do
          @ledger.award(@alice, 40, reason: "proposal")
          assert_equal 40, summary.fetch(:total_issued)

          # A new transaction changes the ledger version => new cache key => fresh figure.
          @ledger.award(@bob, 75, reason: "proposal")
          assert_equal 115, summary.fetch(:total_issued)
        end

        test "the cache key folds in org, locale and the ledger/referral/membership versions" do
          summ = DashboardSummary.new(@organization)
          key = summ.send(:cache_key)

          assert_includes key, "decidim-bih"
          assert_includes key, "admin-goodwill"
          assert_includes key, @organization.id.to_s
          assert_includes key, I18n.locale.to_s
        end
      end
    end
  end
end
