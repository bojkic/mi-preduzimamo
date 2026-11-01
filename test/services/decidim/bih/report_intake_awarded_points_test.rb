# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Decidim
  module Bih
    # Item 8 — Inline report feedback: ReportIntake#awarded_points exposes the
    # points earned so the web controller can surface "+N bodova" in the flash.
    class ReportIntakeAwardedPointsTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      def noop_job
        Object.new.tap do |stub|
          stub.define_singleton_method(:perform_later) { |*_args, **_kwargs| true }
        end
      end

      def intake
        Decidim::Bih::ReportIntake.new(processing_job: noop_job)
      end

      test "awarded_points returns the schedule amount for a logged-in reporter" do
        i = intake
        i.call(organization: @organization, description: "Pukla cijev", author: @user)

        assert_equal 20, i.awarded_points,
                     "awarded_points must return report:20 for a logged-in reporter"
      end

      test "awarded_points returns nil for an anonymous report" do
        i = intake
        i.call(organization: @organization, description: "Anonimna")

        assert_nil i.awarded_points,
                   "awarded_points must be nil when no author is present"
      end

      test "awarded_points is nil when the daily cap has been reached" do
        cap = Decidim::Bih::Goodwill::EarningRules::DEFAULT_DAILY_CAPS[:report]
        # Exhaust the daily cap first
        cap.times do |n|
          intake.call(organization: @organization, description: "Prijava #{n}", author: @user)
        end

        # The next intake should be capped
        i = intake
        i.call(organization: @organization, description: "Over cap", author: @user)
        assert_nil i.awarded_points,
                   "awarded_points must be nil when the daily cap blocks the award"
      end
    end
  end
end
