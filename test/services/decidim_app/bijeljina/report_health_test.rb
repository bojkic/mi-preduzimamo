# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class ReportHealthTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @now = Time.current
        @scope = Decidim::Bih::Report.where(organization: @organization)
      end

      test "first response excludes cases already answered by staff and recent intake" do
        first = report("BR-2026-7001", created_at: @now - 2.hours)
        answered = report("BR-2026-7002", created_at: @now - 2.hours)
        answered.case_messages.create!(actor_role: "staff", kind: "question", body: "Which crossing?")
        reviewed = report("BR-2026-7003", created_at: @now - 2.hours, reviewed_at: @now - 1.hour)
        recent = report("BR-2026-7004", created_at: @now - 20.minutes)

        result = ReportHealth.first_response(@scope, now: @now, stale_minutes: 60)
        assert_equal [first.id], result.order(:id).pluck(:id)
        assert_not_includes result, answered
        assert_not_includes result, reviewed
        assert_not_includes result, recent
      end

      test "expired citizen question is separate and active or closed questions are excluded" do
        overdue = report("BR-2026-7011", review_state: "needs_information", response_due_at: @now - 1.hour)
        active = report("BR-2026-7012", review_state: "needs_information", response_due_at: @now + 1.hour)
        closed = report("BR-2026-7013", status: "odbijeno", review_state: "needs_information", response_due_at: @now - 1.hour)

        result = ReportHealth.citizen_reply_overdue(@scope, now: @now)
        assert_equal [overdue.id], result.order(:id).pluck(:id)
        assert_not_includes result, active
        assert_not_includes result, closed
        assert_empty ReportHealth.first_response(@scope.where(id: [overdue.id, active.id, closed.id]), now: @now, stale_minutes: 60)
      end

      private

      def report(reference, **attributes)
        Decidim::Bih::Report.create!(organization: @organization, reference:, description: "Private report", **attributes)
      end
    end
  end
end
