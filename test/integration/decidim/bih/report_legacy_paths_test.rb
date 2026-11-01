# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportLegacyPathsTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, description: "Original problem", address: "Test street", category: "rasvjeta", severity: "normalan",
                                 internal_note: "Existing private note")
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        @old_auto = Decidim::Bih.sistem48_auto_forward
        Decidim::Bih.sistem48_auto_forward = false
        host! @organization.host
        sign_in @admin
        clear_enqueued_jobs
      end

      teardown { Decidim::Bih.sistem48_auto_forward = @old_auto }

      test "all obsolete forms reopen current review without writes or delivery" do
        routes = [[:patch, "status"], [:patch, "internal-note"], [:patch, "duplicate"], [:delete, "duplicate"],
                  [:post, "retry-forwarding"], [:patch, "case"], [:patch, "location"], [:patch, "planning"],
                  [:delete, "planning"], [:post, "messages"], [:get, "forward-preview"], [:post, "forward"], [:post, "external-submission"]]
        version = ReportReviewVersion.digest(@report)
        routes.each do |method, suffix|
          assert_no_enqueued_jobs only: [ReportDispatchJob, ReportCaseForwardJob, ReportCaseMessageJob] do
            public_send(method, "/admin/bih/reports/#{@report.reference}/#{suffix}", params: {
                          status: "odbijeno", status_note: "Old approval", internal_note: "Overwrite attempt", confirm_send: "1",
                          confirm_external: "1", external_submission_reference: "Old receipt",
                          return_to: "/admin/bih/reports?view=all&page=2",
                          case_details: { review_state: "rejected", confirm_review: "1", status_note: "Old rejection" },
                          case_message: { body: "Old question", question: "1", response_due_at: 1.day.from_now.iso8601 }
                        })
          end
          assert_response :see_other, suffix
          assert_equal "/admin/bih/reports/#{@report.reference}", URI.parse(response.location).path
          assert_equal version, ReportReviewVersion.digest(@report.reload), suffix
          assert_equal I18n.t("decidim.bih.review_workspace.legacy_form"), flash[:alert]
        end
        assert_empty @report.dispatches
        assert_empty @report.case_messages
      end

      test "queued old approvals become a review task and never infer the approving actor" do
        @report.update!(review_state: "validated", reviewed_at: Time.current, reviewed_by: @admin, forwarding_recipient: "intake@example.org")
        digest = ReportCaseWorkflow.digest(@report)
        assert_no_difference "ActionMailer::Base.deliveries.count" do
          2.times { ReportCaseForwardJob.perform_now(@report.id, digest) }
        end
        assert_equal "pending", @report.reload.review_state
        assert_equal "review", @report.deadline_kind
        assert_nil @report.forwarded_at
        assert_empty @report.dispatches
        event = @report.events.where(event_type: "forwarding_held_for_review").sole
        assert_equal "retired_preview", event.metadata["reason"]
        assert_nil event.actor
      end

      test "old jobs do not change a newer approval or a finished case" do
        @report.update!(review_state: "validated", reviewed_at: Time.current)
        digest = ReportCaseWorkflow.digest(@report)
        @report.update!(forwarding_note: "New review")
        version = ReportReviewVersion.digest(@report)
        ReportCaseForwardJob.perform_now(@report.id, digest)
        assert_equal version, ReportReviewVersion.digest(@report.reload)
        @report.update!(status: "rijeseno")
        ReportCaseForwardJob.perform_now(@report.id, ReportCaseWorkflow.digest(@report))
        assert_equal "rijeseno", @report.reload.status
      end

      test "legacy forward flag cannot bypass a review-first host" do
        forwarded = []
        forwarder = Object.new
        forwarder.define_singleton_method(:call) do |payload|
          forwarded << payload
          true
        end
        [false, true].each do |reviewed|
          ReportProcessing.new(forwarder:).call(report: @report, forward: true, reviewed:)
        end
        assert_empty forwarded
        assert_nil @report.reload.forwarded_at
        assert_equal "primljeno", @report.status
      end

      test "case assistance preserves staff classification and queues a proposal" do
        Setting.put(@organization, "report_review", "case_agent", "shadow")
        ReportProcessing.new.call(report: @report, forward: true)
        assert_equal "rasvjeta", @report.reload.category
        assert_nil @report.reviewed_at
        assert_nil @report.forwarded_at
        assert_enqueued_with job: ReportReviewProposalJob, args: [@report.id]
      end

      test "processing after a human decision preserves classification" do
        ReportDecision.new(@report, @admin).call(action: "review", values: { category: "vodovod_kanalizacija", severity: "visok" },
                                                 version: ReportReviewVersion.digest(@report), confirmed: true)
        ReportProcessing.new.call(report: @report, forward: false)
        assert_equal "vodovod_kanalizacija", @report.reload.category
        assert_equal "visok", @report.severity
        assert_equal @admin.id, @report.reviewed_by_id
        assert_empty @report.events.where(event_type: "classification_updated")
      end
    end
  end
end
