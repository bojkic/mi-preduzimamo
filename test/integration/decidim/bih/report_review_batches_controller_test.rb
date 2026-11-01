# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportReviewBatchesControllerTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        host! @organization.host
        sign_in @admin
      end

      def draft(action: "review")
        report = Report.create!(organization: @organization, description: "Private lighting details", address: "Test street", category: "rasvjeta", severity: "normalan")
        ReportDecision.new(report, @admin).call(action: "save_draft", values: { draft_action: action, forwarding_note: "Approved detail" },
                                                version: ReportReviewVersion.digest(report))
        report.reload
      end

      def item(report, choose: "1")
        { reference: report.reference, action: report.review_draft["values"]["draft_action"], values: report.review_draft["values"],
          version: ReportReviewVersion.digest(report), choose: }
      end

      test "private table offers unchecked drafts and preserves context through editing" do
        report = draft
        Report.create!(organization: create_organization, description: "PRIVATE OTHER TENANT", address: "Other street")
        original_version = ReportReviewVersion.digest(report)
        get "/admin/bih/reports/batch", params: { return_to: "/admin/bih/reports?view=all&q=#{report.reference}" }
        assert_response :success
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_equal PRIVATE_PAGE_REFERRER_POLICY, response.headers["Referrer-Policy"]
        assert_select "input[type=checkbox][checked]", count: 0
        assert_select "input[name='batch_items[0][choose]']"
        assert_includes response.body, "Private lighting details"
        assert_not_includes response.body, "PRIVATE OTHER TENANT"
        assert_select "a[href*='batch%3D1']"
        assert_equal original_version, ReportReviewVersion.digest(report.reload)
      end

      test "selected cases preview and only independently approved rows execute" do
        first = draft
        second = draft
        post "/admin/bih/reports/batch/preview", params: { batch_items: { "0" => item(first), "1" => item(second) } }
        assert_response :success
        assert_select "input[type=checkbox][checked]", count: 0
        tokens = css_select("input[name$='[token]']").map { |input| input["value"] }
        assert_equal 2, tokens.size
        assert_nil first.reload.reviewed_at
        post "/admin/bih/reports/batch/confirm", params: { batch_items: { "0" => { token: tokens.first, approve: "1" }, "1" => { token: tokens.last } } }
        assert_response :success
        assert_equal @admin, first.reload.reviewed_by
        assert_nil second.reload.reviewed_at
        assert_includes response.body, I18n.t("decidim.bih.review_workspace.batch.states.skipped")
      end

      test "send preview displays exact content and accepts no unsigned replacement" do
        report = draft(action: "send")
        post "/admin/bih/reports/batch/preview", params: { batch_items: { "0" => item(report) } }
        assert_response :success
        assert_includes response.body, "intake@example.org"
        assert_includes response.body, "Approved detail"
        assert_includes response.body, ReportTaxonomy::CATEGORY_DEPARTMENT[:rasvjeta]
        token = css_select("input[name$='[token]']").sole["value"]
        post "/admin/bih/reports/batch/confirm", params: { batch_items: { "0" => { token:, approve: "1", values: { forwarding_note: "INJECTED" } } } }
        assert_response :success
        assert_equal "queued", report.dispatches.sole.state
        assert_not_includes report.dispatches.sole.snapshot["body"], "INJECTED"
        assert_nil report.reload.forwarded_at
      end

      test "batch preview discloses notifications only for the applicable decisions" do
        sending = draft(action: "send")
        reviewing = draft(action: "review")
        post "/admin/bih/reports/batch/preview", params: { batch_items: { "0" => item(sending), "1" => item(reviewing) } }
        assert_response :success
        assert_select ".report-batch-confirm", count: 2
        assert_select ".report-batch-confirm:first-of-type [data-send-consequence='report.reporter_status_email']", count: 1
        assert_select ".report-batch-confirm:last-of-type [data-send-consequences]", count: 0
        assert_empty sending.reload.dispatches
      end

      test "reply after table rendering invalidates only that preview" do
        report = draft
        values = item(report)
        ReportCaseWorkflow.new(report, nil).reply(body: "New location detail")
        post "/admin/bih/reports/batch/preview", params: { batch_items: { "0" => values } }
        assert_response :success
        assert_select "input[name$='[token]']", count: 0
        assert_nil report.reload.reviewed_at
        get "/admin/bih/reports/batch"
        assert_select "input[name$='[choose]']", count: 0
      end

      test "batch return context returns to filtered table and rejects external URLs" do
        draft
        get "/admin/bih/reports", params: { batch: "1", view: "all", q: "BR" }
        assert_response :redirect
        follow_redirect!
        assert_response :success
        assert_select "input[name=return_to][value*='q=BR']"
        get "/admin/bih/reports/batch", params: { return_to: "https://evil.example/admin/bih/reports" }
        assert_response :success
        assert_not_includes response.body, "evil.example"
      end

      test "current AI proposal can be individually approved and disabled AI stays hidden" do
        report = Report.create!(organization: @organization, description: "Broken lamp", address: "Test street", category: "rasvjeta", severity: "normalan")
        proposal = report.review_proposals.create!(input_digest: Ai::ReportReviewContext.new(report).digest,
                                                   prompt_version: Ai::CaseAgent::PROMPT_VERSION, state: "ready", model: "fixture",
                                                   proposal: { proposed_action: "review", routing: { category: "rasvjeta" }, rationale: "Review lighting" })
        get "/admin/bih/reports/batch"
        assert_select "input[name$='[choose]']", count: 0
        Setting.put(@organization, "report_review", "case_agent", "shadow")
        get "/admin/bih/reports/batch"
        assert_select "input[name$='[choose]']", count: 1
        assert_includes response.body, "Review lighting"
        post "/admin/bih/reports/batch/preview", params: { batch_items: { "0" => { reference: report.reference, action: "review", choose: "1",
                                                                                   version: ReportReviewVersion.digest(report), values: proposal.suggested_values } } }
        token = css_select("input[name$='[token]']").sole["value"]
        post "/admin/bih/reports/batch/confirm", params: { batch_items: { "0" => { token:, approve: "1" } } }
        assert_response :success
        assert_equal @admin, proposal.reload.decided_by
        assert_equal "review", proposal.approved_action
      end

      test "worker proposal remains available across request timezones and cached timestamps" do
        Setting.put(@organization, "report_review", "case_agent", "shadow")
        Rails.application.config.stub(:time_zone, "Europe/Sarajevo") do
          ["2026-01-15T10:00:00Z", "2026-07-15T10:00:00Z"].each do |instant|
            report = Report.create!(organization: @organization, description: "Timezone lamp fixture", address: "Test street", created_at: Time.iso8601(instant))
            digest = Time.use_zone("Europe/Sarajevo") { Ai::ReportReviewContext.new(report.reload).digest }
            proposal = report.review_proposals.create!(input_digest: digest, prompt_version: Ai::CaseAgent::PROMPT_VERSION,
                                                       state: "ready", model: "fixture", proposal: { proposed_action: "review", routing: { category: "rasvjeta" } })
            Time.use_zone("UTC") do
              report.reload.created_at # Cache the attribute in the request zone before building context.
              assert_equal digest, Ai::ReportReviewContext.new(report).digest
              assert proposal.reload.current?
              get "/admin/bih/reports/batch", params: { return_to: "/admin/bih/reports?view=all&q=#{report.reference}" }
              assert_response :success
              assert_select "input[name$='[values][ai_proposal_id]'][value='#{proposal.id}']", count: 1
            end
            # A genuine evidence edit must still invalidate the proposal.
            report.update!(description: "Changed evidence")
            assert_not proposal.reload.current?
          end
        end
      end

      test "batch preserves explicit staff category and leaves blank severity unset" do
        report = Report.create!(organization: @organization, description: "Unclassified fixture", address: "Test street")
        ReportDecision.new(report, @admin).call(action: "save_draft", values: { draft_action: "review", category: "putevi", severity: "" },
                                                version: ReportReviewVersion.digest(report))
        post "/admin/bih/reports/batch/preview", params: { batch_items: { "0" => item(report.reload) } }
        token = css_select("input[name$='[token]']").sole["value"]
        post "/admin/bih/reports/batch/confirm", params: { batch_items: { "0" => { token:, approve: "1" } } }
        assert_response :success
        assert_equal "putevi", report.reload.category
        assert_nil report.severity
        assert_empty report.dispatches
      end

      test "missing CSRF does not execute and ordinary citizen cannot view" do
        report = draft
        post "/admin/bih/reports/batch/preview", params: { batch_items: { "0" => item(report) } }
        token = css_select("input[name$='[token]']").sole["value"]
        previous = ActionController::Base.allow_forgery_protection
        begin
          ActionController::Base.allow_forgery_protection = true
          post "/admin/bih/reports/batch/confirm", params: { batch_items: { "0" => { token:, approve: "1" } } }
          assert_response :unprocessable_entity
          assert_nil report.reload.reviewed_at
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end
        sign_out @admin
        sign_in FactoryBot.create(:user, :confirmed, organization: @organization)
        get "/admin/bih/reports/batch"
        assert_response :redirect
        assert_not_includes response.body, "Private lighting details"
      end
    end
  end
end
