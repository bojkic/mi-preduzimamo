# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # R9 — native Decidim gamification badges driven off the goodwill ledger.
      # Ledger#award is the SINGLE writer into the :goodwill_contributor badge
      # score; the reset lambdas recompute from our source of truth (cached
      # contribution / confirmed+verified) so reset_badges is drift-free.
      class BadgesTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @alice = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "the goodwill badges are registered" do
          names = Decidim::Gamification.badges.map { |b| b.name.to_s }
          assert_includes names, "goodwill_contributor"
          assert_includes names, "verified_citizen"
        end

        test "awarding mirrors points into the goodwill_contributor badge score" do
          @ledger.award(@alice, 60, reason: "proposal")

          status = Decidim::Gamification.status_for(@alice, :goodwill_contributor)
          assert_equal 60, status.score
          # levels [10,50,200,600,1500] => score 60 is level 2.
          assert_equal 2, status.level
        end

        test "the badge score tracks cumulative earns (single writer)" do
          @ledger.award(@alice, 30, reason: "proposal")
          @ledger.award(@alice, 25, reason: "report")

          assert_equal 55, Decidim::Gamification.status_for(@alice, :goodwill_contributor).score
        end

        test "gifting/spending does NOT change the badge score (earn-only mirror)" do
          @ledger.award(@alice, 100, reason: "volunteer_hour")
          @ledger.spend(owner: @alice, amount: 40, kind: "redeem", reason: "reward")

          assert_equal 100, Decidim::Gamification.status_for(@alice, :goodwill_contributor).score
        end

        test "groups never earn a badge score" do
          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          # A direct award to a group (defensive: earning is normally blocked).
          @ledger.award(group, 50, reason: "proposal")

          assert_equal 0, Decidim::Gamification.status_for(group, :goodwill_contributor).score
        end

        test "reset_badges reconciles the contributor badge from cached_contribution" do
          @ledger.award(@alice, 70, reason: "proposal")
          # Simulate drift: stomp the badge score to a wrong value.
          Decidim::Gamification.set_score(@alice, :goodwill_contributor, 9999)
          assert_equal 9999, Decidim::Gamification.status_for(@alice, :goodwill_contributor).score

          Decidim::Gamification.reset_badges(Decidim::User.where(id: @alice.id))

          # The reset lambda recomputes from cached_contribution (the true 70).
          assert_equal 70, Decidim::Gamification.status_for(@alice, :goodwill_contributor).score
        end

        test "verified_citizen badge resets to 1 only when confirmed and verified" do
          # Confirmed but NOT verified => 0.
          Decidim::Gamification.reset_badges(Decidim::User.where(id: @alice.id))
          assert_equal 0, Decidim::Gamification.status_for(@alice, :verified_citizen).score

          Decidim::Authorization.create!(
            user: @alice, name: "id_documents", granted_at: Time.current, metadata: {}
          )
          Decidim::Gamification.reset_badges(Decidim::User.where(id: @alice.id))
          assert_equal 1, Decidim::Gamification.status_for(@alice, :verified_citizen).score
        end
      end
    end
  end
end
