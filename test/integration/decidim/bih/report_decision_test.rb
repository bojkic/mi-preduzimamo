# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportDecisionTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        @report = Report.create!(organization: @organization, author: @citizen, description: "Lamp broken near school", address: "Test street",
                                 category: "rasvjeta", severity: "normalan")
        clear_enqueued_jobs
      end

      def decide(action, values = {}, **)
        ReportDecision.new(@report, @admin).call(action:, values:, version: ReportReviewVersion.digest(@report), confirmed: true, **)
      end

      test "asking combines question ownership review cursor and citizen deadline" do
        decide("ask", { body: "Which crossing?" })
        assert_equal "needs_information", @report.reload.review_state
        assert_equal @admin, @report.assigned_to
        assert_equal "citizen", @report.deadline_kind
        assert_in_delta 7.days.from_now.to_i, @report.response_due_at.to_i, 2
        assert_equal "Which crossing?", @report.case_messages.last.body
        assert_equal 1, @report.events.where(event_type: "case_decision_applied").count
      end

      test "preview is read only and confirmation uses that exact content" do
        version = ReportReviewVersion.digest(@report)
        values = { forwarding_note: "Reviewed: third lamp from crossing." }
        snapshot = ReportDecision.new(@report, @admin).preview(action: "send", values:, version:)
        assert_equal version, ReportReviewVersion.digest(@report.reload)
        assert_nil @report.reviewed_at
        assert_equal 0, @report.dispatches.count
        assert_includes snapshot[:body], values[:forwarding_note]
        dispatch = decide("send", values, approved_mail_digest: snapshot[:digest])
        assert_equal "queued", dispatch.state
        assert_equal snapshot[:body], dispatch.snapshot.fetch("body")
        assert_equal snapshot[:to], dispatch.snapshot.fetch("to")
        assert_equal "validated", @report.reload.review_state
        assert_nil @report.forwarded_at
      end

      test "changed mail after preview rolls back approval rather than sending unseen content" do
        snapshot = ReportDecision.new(@report, @admin).preview(action: "send", values: {}, version: ReportReviewVersion.digest(@report))
        assert_raises(ReportDispatching::Invalid) do
          decide("send", { forwarding_note: "Unseen addition" }, approved_mail_digest: snapshot[:digest])
        end
        assert_nil @report.reload.reviewed_at
        assert_nil @report.forwarding_note
        assert_empty @report.dispatches
      end

      test "stale form cannot approve a new reply or overwrite another draft" do
        version = ReportReviewVersion.digest(@report)
        ReportCaseWorkflow.new(@report, @citizen).reply(body: "Actually the next crossing")
        assert_raises(ReportDecision::Invalid) do
          ReportDecision.new(@report, @admin).call(action: "reject", values: { reason: "Old decision" }, version:, confirmed: true)
        end
        version = ReportReviewVersion.digest(@report)
        decide("save_draft", { forwarding_note: "Draft only" })
        assert_nil @report.reload.forwarding_note
        assert_nil @report.reviewed_at
        assert_raises(ReportDecision::Invalid) do
          ReportDecision.new(@report, @admin).call(action: "save_draft", values: { body: "Older tab" }, version:)
        end
      end

      test "duplicate decision links and closes once without an extra message send" do
        main = Report.create!(organization: @organization, description: "Same lamp", address: "Test street")
        assert_no_enqueued_jobs(only: ReportCaseMessageJob) { decide("duplicate", { duplicate_reference: main.reference }) }
        assert_equal main, @report.reload.duplicate_of
        assert_equal "odbijeno", @report.status
        assert_equal "rejected", @report.review_state
        assert_nil @report.response_due_at
        assert_equal 1, Decidim::Notification.where(user: @citizen, event_name: "decidim.events.bih.report_status_update").count
      end

      test "duplicate cannot cross tenants or create a chain" do
        outsider = Report.create!(organization: create_organization, description: "Other organization")
        assert_raises(ReportDecision::Invalid) { decide("duplicate", { duplicate_reference: outsider.reference }) }
        child = Report.create!(organization: @organization, description: "Child", duplicate_of: @report)
        main = Report.create!(organization: @organization, description: "Main")
        assert_raises(ReportDecision::Invalid) { decide("duplicate", { duplicate_reference: main.reference }) }
        assert_equal @report, child.reload.duplicate_of
      end

      test "inline collection creation and planning are one transaction" do
        decide("plan", { collection_title: "Lighting improvements", collection_topic: "Lighting", collection_summary: "Review street lighting",
                         forwarding_note: "Third lamp", report_subtype: "Lamp" })
        assert_equal "planirano", @report.reload.status
        assert_equal "planning", @report.deadline_kind
        assert_equal @admin, @report.report_collection.assigned_to
        assert_equal @report.report_collection.review_due_at, @report.response_due_at
        assert_equal "validated", @report.review_state
      end

      test "invalid planned summary does not leave an empty collection" do
        assert_no_difference "ReportCollection.count" do
          assert_raises(ReportPlanning::Invalid) do
            decide("plan", { collection_title: "Lighting", collection_topic: "Lighting", collection_summary: "Review lighting" })
          end
        end
        assert_equal "primljeno", @report.reload.status
      end

      test "resolution requires evidence and reopening retains historical evidence" do
        assert_raises(ReportDecision::Invalid) { decide("resolve", { reason: "Checked" }) }
        decide("resolve", { reason: "Checked", resolution_evidence: "Operator inspected repaired lamp" })
        assert_equal "rijeseno", @report.reload.status
        decide("reopen", { reason: "Citizen reports a recurrence" })
        assert_equal "pending", @report.reload.review_state
        assert_equal "primljeno", @report.status
        assert_equal "Operator inspected repaired lamp", @report.resolution_evidence
      end

      test "ordinary claim and private note do not validate or notify the citizen" do
        assert_no_enqueued_jobs(only: ReportCaseMessageJob) do
          decide("claim")
          decide("note", { body: "Internal context only" })
        end
        assert_equal @admin, @report.reload.assigned_to
        assert_nil @report.reviewed_at
        assert_equal "pending", @report.review_state
        assert_includes @report.internal_note, "Internal context only"
        assert_empty @report.case_messages
      end

      test "sent content is locked and review of a reply preserves forwarding evidence" do
        @report.update!(status: "proslijedjeno", forwarded_at: 2.days.ago, review_state: "pending")
        old_address = @report.address
        assert_raises(ReportDecision::Invalid) { decide("review", { edit_location: "1", address: "Elsewhere", location_kind: "description" }) }
        decide("review")
        assert_equal old_address, @report.reload.address
        assert_equal "validated", @report.review_state
        assert @report.forwarded_at
        assert_equal "city", @report.deadline_kind
      end

      test "confirmation and same tenant authorization are required" do
        version = ReportReviewVersion.digest(@report)
        assert_raises(ReportDecision::Invalid) { ReportDecision.new(@report, @admin).call(action: "reject", values: { reason: "Outside scope" }, version:) }
        outsider = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
        assert_raises(Decidim::ActionForbidden) { ReportDecision.new(@report, outsider).call(action: "review", values: {}, version:, confirmed: true) }
        assert_nil @report.reload.reviewed_at
      end
    end
  end
end
