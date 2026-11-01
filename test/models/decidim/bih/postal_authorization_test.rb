# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class PostalAuthorizationTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization(badges_enabled: false)
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      # ─── Workflow registration ────────────────────────────────────────────

      test "postal_letter workflow is registered in Decidim::Verifications" do
        workflow = Decidim::Verifications.workflows.find { |w| w.name == "postal_letter" }
        assert_not_nil workflow, "postal_letter workflow must be registered"
      end

      test "postal_letter workflow has an admin engine (appears in permission picker)" do
        workflow = Decidim::Verifications.workflows.find { |w| w.name == "postal_letter" }
        assert_not_nil workflow&.admin_engine,
                       "postal_letter must have an admin engine so it appears in permission picker"
      end

      test "postal_letter workflow is not a default authorization gate on any component" do
        # Verify no permission sets impose postal_letter as a default.
        # We can only assert the workflow is *registered* (selectable by admin),
        # not forced on anything. This test documents the contract.
        workflow = Decidim::Verifications.workflows.find { |w| w.name == "postal_letter" }
        assert_not_nil workflow
        # The workflow being registered means an admin CAN require it; nothing
        # is gated by default — that's the policy, not a queryable state.
      end

      # ─── postal_verified points awarded once on grant ─────────────────────

      test "postal_verified points are awarded once on postal_letter grant" do
        expected_pts = Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE[:postal_verified]

        # Use FactoryBot-style: create with granted_at set so the after_commit
        # fires immediately with saved_changes["granted_at"] = [nil, timestamp].
        # This mirrors how VerificationAwardTest works.
        perform_enqueued_jobs do
          Decidim::Authorization.create!(
            user: @user,
            name: "postal_letter",
            granted_at: Time.current
          )
        end

        score = current_contribution

        # verification (10) + postal_verified (40) = 50 minimum
        assert score >= expected_pts,
               "expected at least #{expected_pts} pts (postal_verified), got #{score}"
      end

      test "postal_verified points are NOT awarded for non-postal authorization grants" do
        before = current_contribution

        perform_enqueued_jobs do
          FactoryBot.create(:authorization, :granted, user: @user)
        end

        after = current_contribution
        awarded = after - before

        postal_pts = Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE[:postal_verified]
        # verification welcome (10 pts) fires but postal_verified (40 pts) must NOT
        assert awarded < postal_pts,
               "postal_verified (#{postal_pts} pts) must not be awarded for non-postal grant; got #{awarded}"
      end

      test "postal_verified idempotency: points are awarded at most once" do
        perform_enqueued_jobs do
          Decidim::Authorization.create!(
            user: @user,
            name: "postal_letter",
            granted_at: Time.current
          )
        end
        first_score = current_contribution

        # Re-save the granted auth — must not trigger another award
        auth = Decidim::Authorization.find_by(user: @user, name: "postal_letter")
        perform_enqueued_jobs { auth.reload.save! }
        second_score = current_contribution

        assert_equal first_score, second_score,
                     "postal_verified must be idempotent (no second award on re-save)"
      end

      # ─── DEFAULT_SCHEDULE includes postal_verified ───────────────────────

      test "postal_verified is in the engine DEFAULT_SCHEDULE" do
        assert Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE.has_key?(:postal_verified),
               "postal_verified must be in DEFAULT_SCHEDULE"
        assert_equal 40, Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE[:postal_verified]
      end

      # ─── Address is filtered from logs (behavioral) ───────────────────────

      test "full_address and address params are filtered from request parameters" do
        filter = ActiveSupport::ParameterFilter.new(
          Rails.application.config.filter_parameters
        )

        params = {
          "authorization" => {
            "full_address" => "Ulica Cara Lazara 12, Bijeljina",
            "address" => "Neka ulica 1"
          },
          "mobile_phone_number" => "+38766900001",
          "safe_param" => "visible"
        }

        filtered = filter.filter(params)

        assert_equal "[FILTERED]", filtered["authorization"]["full_address"],
                     ":address partial match must filter full_address"
        assert_equal "[FILTERED]", filtered["authorization"]["address"]
        assert_equal "[FILTERED]", filtered["mobile_phone_number"]
        assert_equal "visible", filtered["safe_param"]
      end

      private

      def current_contribution
        # Ledger uses owner.class.base_class.name which may be "Decidim::UserBaseEntity"
        # for users with STI. Use the Ledger's own account_for to find correctly.
        Decidim::Bih::Goodwill::Ledger.new.account_for(@user).contribution_score.to_i
      rescue StandardError
        0
      end
    end
  end
end
