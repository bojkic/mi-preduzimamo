# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Wave-1 security/correctness hardening regressions.
      class HardeningTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        def group!
          FactoryBot.create(:user, :confirmed, organization: @organization, extended_data: { "group" => true })
        end

        # C1 — volunteer hours ceiling (no runaway minting on verify)
        test "volunteer log rejects hours over the daily ceiling" do
          opp = Decidim::Bih::VolunteerOpportunity.create!(organization: @organization, title: "x", active: true)
          zone = Time.find_zone!("Europe/Sarajevo")
          start_at = zone.parse("2026-09-15 00:00")
          end_at = zone.parse("2026-09-16 00:00")
          log = Decidim::Bih::VolunteerLog.new(
            organization: @organization, opportunity: opp, user: @user,
            work_date: Date.new(2026, 9, 15), worked_from_at: start_at, worked_until_at: end_at,
            hours: 1_000_000, status: "pending"
          )
          assert_not log.valid?
          log.hours = 24
          assert log.valid?
          log.hours = 25
          assert_not log.valid?
        end

        # Groups never earn contribution via the rules engine
        test "groups cannot earn via the earning rules" do
          group = group!
          assert_nil EarningRules.new.award(group, :comment, idempotency_key: "c1")
          assert_equal 0, @ledger.account_for(group).contribution_score
        end

        # Groups excluded from the citizen leaderboard even if they hold earn credits
        test "groups are excluded from the contribution leaderboard" do
          group = group!
          @ledger.award(group, 500, reason: "seed") # direct award bypasses the rules guard
          @ledger.award(@user, 50, reason: "proposal")

          owner_ids = Account.contribution_leaderboard(@organization).map(&:owner_id)
          assert_includes owner_ids, @user.id
          assert_not_includes owner_ids, group.id
        end

        # Misconfigured reward (cost <= 0) degrades to :invalid, never 500
        test "redeeming a zero-cost reward broadcasts :invalid" do
          original = Decidim::Bih.goodwill_rewards_catalog
          Decidim::Bih.goodwill_rewards_catalog = [{ key: "broken", cost: 0 }]
          @ledger.award(@user, 100, reason: "x")
          state = nil
          RedeemReward.call(@user, "broken") do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end
          assert_equal :invalid, state
        ensure
          Decidim::Bih.goodwill_rewards_catalog = original
        end

        # Regrant-to-self is blocked (closes the self-gift -> self-regrant loop)
        test "regrant to self is rejected even for a group admin" do
          group = group!
          GroupMembership.create!(decidim_user_id: @user.id, decidim_user_group_id: group.id, role: "creator")
          @ledger.award(group, 100, reason: "seed") # fund the group wallet
          state = nil
          RegrantPoints.call(@user, group.id, @user.id, 10) do
            on(:ok) { state = :ok }
            on(:forbidden) { state = :forbidden }
            on(:invalid) { state = :invalid }
            on(:insufficient) { state = :insufficient }
          end
          assert_equal :invalid, state
          assert_equal 100, @ledger.account_for(group).balance # untouched
        end
      end
    end
  end
end
