# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportDecisionsControllerTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        @report = Report.create!(organization: @organization, description: "Original evidence", address: "Test street",
                                 category: "rasvjeta", severity: "normalan")
        host! @organization.host
        sign_in @admin
      end

      def path(suffix = "") = "/admin/bih/reports/#{@report.reference}#{suffix}"

      def preview
        post path("/decision"), params: { decision_action: "send", input_version: ReportReviewVersion.digest(@report),
                                          decision: { category: "rasvjeta", forwarding_note: "Approved text" },
                                          return_to: "/admin/bih/reports?view=all&page=2" }
        assert_response :success
        assert_select "[data-send-consequence='report.reporter_status_email']", count: 1
        css_select("input[name=preview_token]").first["value"]
      end

      test "detail presents one decision form and no raw status editor" do
        get path
        assert_response :success
        assert_select "#report-decision-form", count: 1
        assert_select "select[name=status]", count: 0
        assert_select "select[name='case_details[review_state]']", count: 0
        assert_select "#report-private-evidence", text: /Original evidence/
        assert_select "input[name='decision[department]']", count: 0
        assert_select "select[name='decision[forwarding_recipient]']", count: 0
        assert_select "fieldset[data-actions='reject resolve reopen']"
        assert_includes response.headers["Cache-Control"], "no-store"
      end

      test "notification disclosure follows the chosen action without implying internal notes send" do
        get path
        assert_select "[data-actions]:not([hidden]) [data-send-consequence='report.reporter_status_email']", count: 1
        assert_select "[data-actions='ask message'][hidden] [data-send-consequence='report.case_message_to_author']", count: 1
        %w(note review claim assign save_draft supplement followup).each do |action|
          assert_empty ReportDecision.notification_consequences(action)
        end
        assert_equal ["report.case_message_to_author"], ReportDecision.notification_consequences("ask").pluck(:key)
      end

      test "question is one confirmed action and updates the case" do
        post path("/decision"), params: { decision_action: "ask", input_version: ReportReviewVersion.digest(@report),
                                          decision: { body: "Which crossing?" }, confirm_decision: "1" }
        assert_response :redirect
        assert_equal "needs_information", @report.reload.review_state
        assert_equal "Which crossing?", @report.case_messages.last.body
      end

      test "preview does not write and confirmation ignores unsigned extra fields" do
        version = ReportReviewVersion.digest(@report)
        token = preview
        assert_equal version, ReportReviewVersion.digest(@report.reload)
        assert_empty @report.dispatches
        post path("/decision/confirm"), params: { preview_token: token, confirm_decision: "1", decision: { forwarding_note: "UNAPPROVED" } }
        assert_response :redirect
        assert_equal 1, @report.dispatches.count
        assert_includes @report.dispatches.last.snapshot.fetch("body"), "Approved text"
        assert_not_includes @report.dispatches.last.snapshot.fetch("body"), "UNAPPROVED"
        assert_includes response.location, "return_to="
        assert_nil @report.reload.forwarded_at
      end

      test "a new reply invalidates confirmation" do
        token = preview
        ReportCaseWorkflow.new(@report, nil).reply(body: "Corrected location")
        post path("/decision/confirm"), params: { preview_token: token, confirm_decision: "1" }
        assert_response :redirect
        assert_empty @report.dispatches
        assert_nil @report.reload.reviewed_at
      end

      test "a preview belongs to its actor and expires" do
        token = preview
        another_admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        sign_in another_admin
        post path("/decision/confirm"), params: { preview_token: token, confirm_decision: "1" }
        assert_empty @report.dispatches
        sign_in @admin
        travel 11.minutes do
          post path("/decision/confirm"), params: { preview_token: token, confirm_decision: "1" }
          assert_empty @report.dispatches
        end
      end

      test "draft button saves the selected action without making a decision" do
        post path("/decision"), params: { decision_action: "ask", intent: "draft", input_version: ReportReviewVersion.digest(@report), decision: { body: "Draft question" } }
        assert_response :redirect
        assert_equal "ask", @report.reload.review_draft.fetch("values").fetch("draft_action")
        assert_empty @report.case_messages
        get path
        assert_response :success
        assert_select "option[value=ask][selected]"
      end

      test "next action keeps the filtered queue and draft stays on the current case" do
        other = Report.create!(organization: @organization, description: "Next evidence", address: "Test street", category: "rasvjeta", severity: "normalan")
        Report.create!(organization: @organization, description: "Different location", address: "Different street")
        return_to = "/admin/bih/reports?view=review&q=Test&page=1"
        post path("/decision"), params: { decision_action: "ask", after_decision: "next", return_to:, input_version: ReportReviewVersion.digest(@report),
                                          decision: { body: "Which crossing?" }, confirm_decision: "1" }
        assert_response :redirect
        assert_includes URI.parse(response.location).path, other.reference
        returned = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("return_to")
        assert_equal "Test", Rack::Utils.parse_query(URI.parse(returned).query)["q"]
        get path, params: { return_to: }
        assert_select "a[href*='q=Test']"
        post path("/decision"), params: { decision_action: "ask", after_decision: "next", intent: "draft", return_to:,
                                          input_version: ReportReviewVersion.digest(@report.reload), decision: { body: "Draft" } }
        assert_equal path, URI.parse(response.location).path
      end

      test "queue return rejects external and nested query parameters" do
        get path, params: { return_to: "https://example.org/admin/bih/reports?view=all" }
        assert_select "input[name=return_to][value='/admin/bih/reports?view=review']"
        get path, params: { return_to: "/admin/bih/reports?q[]=bad&view=all" }
        assert_response :success
        assert_select "input[name=return_to][value='/admin/bih/reports?view=all']"
      end

      test "candidate comparison is private scoped and does not infer a duplicate from location" do
        candidate = Report.create!(organization: @organization, description: "Different physical problem <script>alert(1)</script>", address: "Test street", category: "putevi")
        ReportCaseWorkflow.new(candidate, nil).reply(body: "The other side of the street")
        outsider = Report.create!(organization: create_organization, description: "Hidden evidence", address: "Test street")
        get path("/duplicate-candidates")
        assert_response :success
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_select "button[data-select-duplicate='#{candidate.reference}']"
        assert_select "button[data-select-duplicate='#{@report.reference}']", count: 0
        assert_select "button[data-select-duplicate='#{outsider.reference}']", count: 0
        assert_select "script", count: 0
        assert_includes response.body, "The other side of the street"
        assert_nil @report.reload.duplicate_of_report_id
        get path("/duplicate-candidates"), params: { q: candidate.reference }
        assert_select "button[data-select-duplicate]", count: 1
        candidate.update!(duplicate_of: @report)
        get path("/duplicate-candidates"), params: { q: candidate.reference }
        assert_select "button[data-select-duplicate]", count: 0
      end

      test "other organization cannot read or mutate a case" do
        outsider = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
        sign_in outsider
        post path("/decision"), params: { decision_action: "reject", input_version: ReportReviewVersion.digest(@report), decision: { reason: "No" }, confirm_decision: "1" }
        assert_response :redirect
        assert_match %r{/admin/\z}, response.location
        assert_equal "primljeno", @report.reload.status
      end
    end
  end
end
