# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportWorkQueueTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        host! @organization.host
      end

      def report(**attrs)
        Report.create!({ organization: @organization, description: "Street lighting problem", address: "Test street",
                         category: "rasvjeta", severity: "normalan", author: @citizen }.merge(attrs))
      end

      test "human review attention includes replies when classifier fallback flag is false" do
        subject = report(review_state: "validated", reviewed_at: 1.day.ago)
        before = ReportCaseWorkflow.digest(subject)
        reply = ReportCaseWorkflow.new(subject, @citizen).reply(body: "The problem is beside the school")
        assert_equal "pending", subject.reload.review_state
        assert_equal reply.created_at, subject.last_citizen_reply_at
        assert_equal reply.created_at + 2.days, subject.response_due_at
        assert_not_equal before, ReportCaseWorkflow.digest(subject)
        assert_includes ReportWorkQueue.new(organization: @organization).scope, subject
        triage = Admin::ReportTriageSummary.new(organization: @organization)
        assert_equal 1, triage.scope_for("pending_review").count
        assert_not_includes Admin::ReportTriageSummary::BUCKETS, "needs_review"
      end

      test "opening a case does not consume a citizen reply" do
        subject = report
        message = ReportCaseWorkflow.new(subject, @citizen).reply(body: "Beside the school")
        sign_in @admin
        get "/admin/bih/reports/#{subject.reference}"
        assert_response :success
        assert_nil message.reload.read_at
        assert_equal "pending", subject.reload.review_state
      end

      test "waiting for information is not an overdue forwarding instruction" do
        subject = report(created_at: 10.days.ago, review_state: "needs_information", response_due_at: 3.days.from_now)
        subject.record_forwarding_failure!(StandardError.new("Earlier delivery failed"))
        triage = Admin::ReportTriageSummary.new(organization: @organization)
        assert_not_includes triage.scope_for("received_over_sla"), subject
        assert_not_includes ReportWorkQueue.new(organization: @organization).scope, subject
      end

      test "expired citizen deadline stays in waiting queue until a reply arrives" do
        subject = report(created_at: 10.days.ago, review_state: "needs_information", response_due_at: 1.day.ago)
        subject.case_messages.create!(actor: @admin, actor_role: "staff", kind: "question", body: "Which street?", created_at: 8.days.ago)
        queue = ReportWorkQueue.new(organization: @organization)
        assert_not_includes queue.scope("review"), subject
        assert_includes queue.scope("citizen"), subject
        assert_equal "citizen", ReportWorkQueue.waiting_on(subject)
        assert_equal "needs_information", ReportStatusPresenter.status_key(subject)

        ReportCaseWorkflow.new(subject, @citizen).reply(body: "School street")
        assert_equal "pending", subject.reload.review_state
        assert_includes queue.scope("review"), subject
        assert_not_includes queue.scope("citizen"), subject
      end

      test "duplicate candidates include inflected street names" do
        earlier = report(description: "Basketball court needs concrete", address: "Košarkaški teren u Vidovdanskoj ulici")
        subject = report(description: "Asphalt around the court", address: "Vidovdanska ulica")
        matches = ReportDuplicateCandidates.new(subject).call
        assert_includes matches.map { |match| match.report.id }, earlier.id
      end

      test "city followup starts at sending rather than report creation" do
        subject = report(created_at: 50.days.ago, status: "proslijedjeno", review_state: "validated", forwarded_at: 1.day.ago)
        triage = Admin::ReportTriageSummary.new(organization: @organization)
        assert_not_includes triage.scope_for("stale_city_followup"), subject
        subject.update!(forwarded_at: 40.days.ago)
        assert_includes triage.scope_for("stale_city_followup"), subject
      end

      test "reply after sending creates review work while keeping evidence of sending" do
        subject = report(status: "proslijedjeno", review_state: "validated", forwarded_at: 1.day.ago)
        sent_at = subject.forwarded_at
        ReportCaseWorkflow.new(subject, @citizen).reply(body: "Another lamp has failed")
        assert_equal "pending", subject.reload.review_state
        assert_equal "proslijedjeno", subject.status
        assert_equal sent_at, subject.forwarded_at
        assert_includes ReportWorkQueue.new(organization: @organization).scope, subject
      end

      test "pagination reaches all reports and search remains tenant scoped" do
        subjects = Array.new(26) { report }
        outsider = Report.create!(organization: create_organization, description: "Private outside case", address: "Outside location")
        sign_in @admin
        get "/admin/bih/reports", params: { view: "all" }
        assert_response :success
        assert_select "#admin-reports-list tbody tr", count: 25
        assert_select "nav a[href*='page=2']"
        get "/admin/bih/reports", params: { view: "all", page: 2 }
        assert_response :success
        assert_select "#admin-reports-list tbody tr", count: 1
        get "/admin/bih/reports", params: { view: "all", q: subjects.last.reference }
        assert_select "#admin-reports-list tbody tr", count: 1
        get "/admin/bih/reports", params: { view: "all", q: outsider.address }
        assert_select "#admin-reports-list tbody tr", count: 0
        assert_includes response.headers["Cache-Control"], "no-store"
      end
    end
  end
end
