# frozen_string_literal: true

require "test_helper"
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module Goodwill
      class EarningRulesTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "awards the scheduled points for an action" do
          rules = Decidim::Bih::Goodwill::EarningRules.new(schedule: { proposal: 20 })
          txn = rules.award(@user, :proposal, idempotency_key: published_proposal_key)

          assert txn
          assert_equal 20, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).contribution_score
        end

        test "daily cap blocks low-effort awards beyond the cap" do
          rules = Decidim::Bih::Goodwill::EarningRules.new(
            schedule: { comment: 5 },
            daily_caps: { comment: 2 }
          )
          assert rules.award(@user, :comment, idempotency_key: "c1")
          assert rules.award(@user, :comment, idempotency_key: "c2")
          assert_nil rules.award(@user, :comment, idempotency_key: "c3")

          assert_equal 10, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).contribution_score
        end

        test "idempotency key prevents double award for the same source" do
          rules = Decidim::Bih::Goodwill::EarningRules.new(schedule: { proposal: 20 })
          key = published_proposal_key
          assert rules.award(@user, :proposal, idempotency_key: key)
          assert_nil rules.award(@user, :proposal, idempotency_key: key)

          assert_equal 20, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).contribution_score
        end

        test "the background job awards through the rules" do
          Decidim::Bih::Goodwill::GoodwillAwardJob.perform_now(
            owner: @user, action: "proposal", idempotency_key: published_proposal_key
          )
          assert_equal 25, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).contribution_score
        end

        # --- season_started_at must survive an out-of-range stored value -------
        #
        # A corrupt/out-of-range stored season-start can make Time.zone.parse
        # raise RangeError (not only ArgumentError/TypeError). A public wallet
        # read that consults the season must NEVER blow up — it must fall back to
        # the host config value.
        test "season_started_at falls back to config when the stored value raises RangeError" do
          Decidim::Bih::Setting.put(
            @organization,
            Decidim::Bih::Goodwill::EarningRules::SEASON_NAMESPACE,
            Decidim::Bih::Goodwill::EarningRules::SEASON_KEY,
            "out-of-range"
          )

          config_value = Time.zone.parse("2026-01-01 00:00:00")
          Decidim::Bih.stub(:goodwill_season_started_at, config_value) do
            Time.zone.stub(:parse, ->(*) { raise RangeError, "argument out of range" }) do
              assert_equal config_value,
                           Decidim::Bih::Goodwill::EarningRules.season_started_at(@organization)
            end
          end
        end

        test "season_started_at still falls back on ArgumentError (unparseable string)" do
          Decidim::Bih::Setting.put(
            @organization,
            Decidim::Bih::Goodwill::EarningRules::SEASON_NAMESPACE,
            Decidim::Bih::Goodwill::EarningRules::SEASON_KEY,
            "2026-13-45" # month/day out of range -> ArgumentError
          )

          config_value = Time.zone.parse("2026-01-01 00:00:00")
          Decidim::Bih.stub(:goodwill_season_started_at, config_value) do
            assert_equal config_value,
                         Decidim::Bih::Goodwill::EarningRules.season_started_at(@organization)
          end
        end

        private

        def published_proposal_key
          component = FactoryBot.create(:proposal_component, organization: @organization)
          proposal = FactoryBot.create(:proposal, component:, users: [@user], published_at: Time.current)
          IdempotencyKey.proposal(proposal.id, @user.id)
        end
      end
    end
  end
end
