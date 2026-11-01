# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportPlanningTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, author: @citizen, description: "Private original description",
                                 address: "Račanska", category: "saobracaj", severity: "visok")
        @collection = ReportCollection.create!(organization: @organization, title: "Traffic safety", topic: "Signage",
                                               assigned_to: @admin, review_due_at: 2.weeks.from_now, summary: "Please assess suitable traffic calming measures.")
        host! @organization.host
        sign_in @admin
      end

      def plan
        ReportPlanning.new(@report, @admin).plan(report_collection_id: @collection.id, report_subtype: "Traffic calming",
                                                 forwarding_note: "Assess the Račanska street section.", confirm_review: "1")
      end

      test "location edit preserves the original and clears exact public location consent" do
        @report.update!(public_location_exact: true)
        post "/admin/bih/reports/#{@report.reference}/decision", params: { decision_action: "review", input_version: ReportReviewVersion.digest(@report),
                                                                         confirm_decision: "1", decision: { edit_location: "1", address: "Račanska, Beogradska to Nestro", location_kind: "segment" } }
        assert_response :redirect
        assert_equal "Račanska, Beogradska to Nestro", @report.reload.address
        assert_equal "Račanska", @report.original_location["address"]
        assert_nil @report.latitude
        assert_not @report.public_location_exact
        assert_equal @admin, @report.location_reviewed_by
        assert_equal 1, @report.events.where(event_type: "case_location_updated").count
        assert_not_includes @report.events.last.metadata.to_json, "Nestro"
        ReportPlanning.new(@report, @admin).location(address: "Clarified section", location_kind: "segment")
        assert_equal "Račanska", @report.reload.original_location["address"]
      end

      test "point and segment coordinates require complete finite valid pairs" do
        service = ReportPlanning.new(@report, @admin)
        [{ latitude: "oops", longitude: "19" }, { latitude: "91", longitude: "19" }, { latitude: "44" }].each do |bad|
          assert_raises(ReportPlanning::Invalid) { service.location({ address: "Location", location_kind: "point" }.merge(bad)) }
        end
        assert_raises(ReportPlanning::Invalid) { service.location(address: "Section", location_kind: "segment", latitude: "44", longitude: "19") }
        service.location(address: "Section", location_kind: "segment", latitude: "44.75", longitude: "19.2", location_end_latitude: "44.76", location_end_longitude: "19.21")
        assert_equal 44.76, @report.reload.location_end_latitude
      end

      test "planning accepts one reviewed report without city messages" do
        assert_no_enqueued_jobs(only: [ActionMailer::MailDeliveryJob, ReportProcessingJob, ReportCaseForwardJob]) { plan }
        assert_equal "planirano", @report.reload.status
        assert_equal "validated", @report.review_state
        assert_equal @collection, @report.report_collection
        assert_equal @collection.review_due_at.to_i, @report.response_due_at.to_i
        assert_equal "planned", ReportServiceRequest.public_status_for(@report.status)
        assert_equal "#64748b", ReportStatusPresenter.color(@report.status)
        assert_nil @report.forwarded_at
      end

      test "all individual sending paths reject planned collection reports" do
        plan
        ReportCaseForwardJob.perform_now(@report.id, ReportCaseWorkflow.digest(@report))
        assert_nil @report.reload.forwarded_at
        processor = ReportProcessing.new
        assert_not processor.send(:ready_to_forward?, @report, reviewed: true)
        assert_raises(ReportCaseWorkflow::Invalid) { ReportCaseWorkflow.new(@report, @admin).record_external(reference: "one-off") }
        post "/admin/bih/reports/#{@report.reference}/forward", params: { confirm_send: "1" }
        assert_response :redirect
        assert_nil @report.reload.forwarded_at
        patch "/admin/bih/reports/#{@report.reference}/status", params: { status: "u_obradi" }
        assert_equal "planirano", @report.reload.status
      end

      test "collection preparation excludes citizen identity conversations and original description" do
        plan
        ReportCollectionWorkflow.new(@collection, @admin).ready
        get "/admin/bih/report-collections/#{@collection.id}/export"
        assert_response :success
        assert_includes response.body, @report.reference
        assert_includes response.body, @report.address
        assert_not_includes response.body, @report.description
        assert_not_includes response.body, @citizen.email
        assert_not_includes response.body, @report.status_token
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_equal "strict-origin", response.headers["Referrer-Policy"]
      end

      test "receipt recording requires ready content and updates members once without sending" do
        plan
        service = ReportCollectionWorkflow.new(@collection, @admin)
        assert_raises(ReportPlanning::Invalid) { service.record_submission(recipient: "City", reference: "Protocol 123", confirmed: "1") }
        service.ready
        assert_raises(ReportPlanning::Invalid) { service.record_submission(recipient: "City", reference: "Protocol 123", confirmed: "0") }
        assert_no_enqueued_jobs(only: [ActionMailer::MailDeliveryJob, ReportProcessingJob, ReportCaseForwardJob]) { service.record_submission(recipient: "City", reference: "Protocol 123", confirmed: "1") }
        assert_equal "submitted", @collection.reload.state
        assert_equal "proslijedjeno", @report.reload.status
        assert_equal "Protocol 123", @report.external_submission_reference
        assert_raises(ReportPlanning::Invalid) { service.record_submission(recipient: "City", reference: "Duplicate", confirmed: "1") }
        assert_raises(ReportPlanning::Invalid) { ReportPlanning.new(@report, @admin).location(address: "Changed", location_kind: "description") }
        assert_raises(ReportPlanning::Invalid) { ReportPlanning.new(@report, @admin).unplan }
      end

      test "collective cases can retain validation and record resolution evidence without an individual recipient" do
        plan
        workflow = ReportCaseWorkflow.new(@report, @admin)
        workflow.update(review_state: "validated", category: @report.category, department: @report.department,
                        severity: @report.severity, forwarding_note: @report.forwarding_note, confirm_review: "1", resolution_evidence: "City assessment received",
                        assigned_to_id: @admin.id, response_due_at: 2.weeks.from_now.iso8601)
        assert_equal "City assessment received", @report.reload.resolution_evidence
        assert_nil @report.forwarding_recipient
      end

      test "location changes invalidate readiness and original snapshot survives" do
        plan
        ReportCollectionWorkflow.new(@collection, @admin).ready
        ReportPlanning.new(@report, @admin).location(address: "New section", location_kind: "segment")
        assert_equal "collecting", @collection.reload.state
        get "/admin/bih/report-collections/#{@collection.id}/export"
        assert_response :redirect
      end

      test "draft report can return to regular handling" do
        plan
        post "/admin/bih/reports/#{@report.reference}/decision", params: { decision_action: "unplan", input_version: ReportReviewVersion.digest(@report.reload), confirm_decision: "1" }
        assert_response :redirect
        assert_nil @report.reload.report_collection
        assert_equal "u_obradi", @report.status
        assert_nil @report.forwarded_at
      end

      test "removing a rejected report from a draft does not reopen it" do
        plan
        @report.update!(status: "odbijeno", review_state: "rejected")
        ReportPlanning.new(@report, @admin).unplan
        assert_nil @report.reload.report_collection
        assert_equal "odbijeno", @report.status
        assert_equal "rejected", @report.review_state
      end

      test "editing a reviewed summary blocks export of the old snapshot" do
        plan
        ReportCollectionWorkflow.new(@collection, @admin).ready
        @report.update!(forwarding_note: "Changed summary")
        get "/admin/bih/report-collections/#{@collection.id}/export"
        assert_response :redirect
        assert_raises(ReportPlanning::Invalid) do
          ReportCollectionWorkflow.new(@collection, @admin).record_submission(recipient: "City", reference: "Receipt", confirmed: "1")
        end
      end

      test "new citizen information makes a planned report require another review" do
        plan
        ReportCollectionWorkflow.new(@collection, @admin).ready
        ReportCaseWorkflow.new(@report, @citizen).reply(body: "The affected section is different")
        assert_equal "pending", @report.reload.review_state
        assert_equal "planirano", @report.status
        get "/admin/bih/report-collections/#{@collection.id}/export"
        assert_response :redirect
      end

      test "cross tenant collections and unauthorized edits are rejected" do
        other_org = create_organization
        foreign = ReportCollection.create!(organization: other_org, title: "Other", topic: "Other")
        assert_raises(ReportPlanning::Invalid) { ReportPlanning.new(@report, @admin).plan(report_collection_id: foreign.id) }
        get "/admin/bih/report-collections/#{foreign.id}"
        assert_response :not_found
        assert_raises(Decidim::ActionForbidden) { ReportPlanning.new(@report, @citizen).location(address: "Changed", location_kind: "description") }
      end

      test "collection create and report page expose working protected forms" do
        post "/admin/bih/report-collections",
             params: { collection: { title: "New collection", topic: "Traffic", assigned_to_id: @admin.id, review_due_at: 2.weeks.from_now.iso8601 } }
        assert_response :redirect
        follow_redirect!
        assert_response :success
        get "/admin/bih/reports/#{@report.reference}"
        assert_response :success
        assert_select "#report-decision-form input[name='decision[edit_location]']"
        assert_select "#report-decision-form fieldset[data-actions=plan]"
        assert_equal "strict-origin", response.headers["Referrer-Policy"]
      end
    end
  end
end
