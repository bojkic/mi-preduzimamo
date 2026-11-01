# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # 2026-10-06: staff could not close a task handled outside a decision, a
    # notice after a City answer left the case in review, and a no-reply
    # rejection could not keep race points from the interface.
    class ReportTasksUi20261006Test < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, author: @citizen, description: "Parking blocks the sidewalk", address: "Test street",
                                 category: "saobracaj", review_state: "validated", reviewed_at: 2.days.ago, status: "proslijedjeno",
                                 forwarded_at: 2.days.ago, forwarding_recipient: "intake@example.org")
        host! @organization.host
        sign_in @admin
      end

      def path = "/admin/bih/reports/#{@report.reference}"

      test "an open staff task is listed and can be closed with a reason" do
        task = @report.obligations.create!(kind: "dispatch_approval", actor: "staff", due_at: 1.day.from_now,
                                           metadata: { reason: "approve_police_channel_and_referral", traffic_police_phone: "055/235-128" })
        get path
        assert_response :success
        assert_select "#report-open-tasks [data-open-task='dispatch_approval'] form"
        assert_select "#report-open-tasks [data-task-explanation]", text: /Saobraćajnoj policiji.*055\/235-128/
        post "#{path}/tasks/#{task.id}/close", params: { reason: "handled_elsewhere" }
        assert_redirected_to path
        assert_equal "superseded", task.reload.state
        assert_equal "handled_elsewhere", task.metadata["closed_reason"]
        assert @report.events.exists?(event_type: "case_task_closed")
      end

      test "a citizen notice after recording a City answer completes the review" do
        decision = ->(action, values) { ReportDecision.new(@report.reload, @admin).call(action:, values:, version: ReportReviewVersion.digest(@report.reload), confirmed: true) }
        decision.call("service_response", { body: "Proslijeđeno odjeljenju za stambeno-komunalne poslove." })
        assert_equal "pending", @report.reload.review_state
        decision.call("message", { body: "Grad je Vašu prijavu proslijedio nadležnom odjeljenju." })
        assert_equal "validated", @report.reload.review_state
        assert_not_includes ReportWorkQueue.new(organization: @organization).scope("review"), @report
      end

      test "a no-reply rejection records its basis" do
        ReportDecision.new(@report, @admin).call(action: "reject", values: { reason: "Bez odgovora.", closure_basis: "bez_odgovora" },
                                                 version: ReportReviewVersion.digest(@report), confirmed: true)
        assert_equal %w(odbijeno bez_odgovora), [@report.reload.status, @report.closure_basis]
      end
    end
  end
end
