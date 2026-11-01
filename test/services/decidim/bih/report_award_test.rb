# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Decidim
  module Bih
    # R7 — civic-report recognition. A LOGGED-IN reporter earns report:20 once;
    # anonymous/Viber reports earn nothing; a recognition failure never breaks
    # the report.
    class ReportAwardTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      def noop_processing_job
        Object.new.tap do |stub|
          stub.define_singleton_method(:perform_later) { |*_args, **_kwargs| true }
        end
      end

      def intake
        Decidim::Bih::ReportIntake.new(processing_job: noop_processing_job)
      end

      def contribution_for(user)
        Decidim::Bih::Goodwill::Ledger.new.account_for(user).contribution_score
      end

      test "a logged-in reporter earns report:20 and the report is attributed" do
        report = intake.call(
          organization: @organization, description: "Rupa na putu", author: @user
        )

        assert_equal @user.id, report.decidim_user_id
        assert_equal 20, contribution_for(@user)
      end

      test "an anonymous report (no author) earns nothing and has no attribution" do
        report = intake.call(organization: @organization, description: "Anonimna prijava")

        assert_nil report.decidim_user_id
        # No account/credit should have been created for anyone.
        assert_equal 0, Decidim::Bih::Goodwill::Transaction.where(organization: @organization).count
      end

      test "the award is idempotent per report (no double pay on re-award)" do
        report = intake.call(
          organization: @organization, description: "Rupa", author: @user
        )
        # Re-running the award for the SAME report must not add points again.
        Decidim::Bih::Goodwill::EarningRules.new.award(
          @user, :report, idempotency_key: "bih_report:#{report.id}"
        )

        assert_equal 20, contribution_for(@user)
      end

      test "respects the per-day report cap (anti-farming)" do
        cap = Decidim::Bih::Goodwill::EarningRules::DEFAULT_DAILY_CAPS[:report]
        (cap + 2).times do |i|
          intake.call(organization: @organization, description: "Prijava #{i}", author: @user)
        end

        assert_equal cap * 20, contribution_for(@user)
      end

      test "a goodwill failure never loses the report" do
        boom = Class.new(Decidim::Bih::Goodwill::EarningRules) do
          def award(*) = raise("ledger down")
        end

        report = nil
        assert_nothing_raised do
          Decidim::Bih::Goodwill::EarningRules.stub(:new, boom.new) do
            report = intake.call(
              organization: @organization, description: "Rupa", author: @user
            )
          end
        end

        assert report.persisted?
        assert_equal @user.id, report.decidim_user_id
      end
    end
  end
end
