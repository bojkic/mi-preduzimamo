# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportReviewProposalsControllerTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, description: "Broken lamp", address: "School street", category: "rasvjeta", severity: "normalan")
        Setting.put(@organization, "report_review", "case_agent", "shadow")
        @proposal = @report.review_proposals.create!(input_digest: Ai::ReportReviewContext.new(@report).digest, prompt_version: Ai::CaseAgent::PROMPT_VERSION,
                                                     state: "ready", model: "test-model", proposal: {
                                                       "proposed_action" => "ask", "routing" => { "category" => "rasvjeta" }, "rationale" => "Which crossing?",
                                                       "facts" => [{ "text" => "Lamp", "source_id" => "original", "quote" => "Broken lamp" }], "uncertainties" => ["Two crossings"],
                                                       "location_text" => "", "location_source_id" => "", "duplicate_reference" => "",
                                                       "collection_id" => 0, "citizen_message" => { "composed_text" => "Which crossing?" }, "forwarding_note" => ""
                                                     })
        host! @organization.host
        sign_in @admin
      end

      test "historical proposals remain readable but cannot be adopted or bind a new decision" do
        @proposal.destroy!
        @proposal = @report.review_proposals.create!(input_digest: Ai::ReportReviewContext.new(@report).digest,
                                                     prompt_version: "report-review-v8", state: "ready",
                                                     proposal: { "action" => "ask", "rationale" => "Historical explanation", "question" => "Old question" })
        get path
        assert_select "[data-historical-proposal]"
        assert_includes response.body, "Historical explanation"
        assert_select "#report-ai-proposal form[action$='/adopt']", count: 0
        assert_empty @proposal.suggested_values
        post adopt_path, params: { input_version: ReportReviewVersion.digest(@report) }
        assert_empty @report.reload.review_draft
        assert_raises(ReportDecision::Invalid) do
          ReportDecision.new(@report, @admin).call(action: "save_draft", values: { draft_action: "ask", ai_proposal_id: @proposal.id, body: "Edited question" },
                                                   version: ReportReviewVersion.digest(@report))
        end
      end

      test "saved historical draft keeps staff edits and can be saved as a human draft" do
        legacy = @report.review_proposals.create!(input_digest: "old", prompt_version: "report-review-v8", state: "ready", proposal: { "action" => "ask" })
        @report.update!(review_draft: { values: { draft_action: "ask", body: "Staff edited text", ai_proposal_id: legacy.id }, saved_at: Time.current.iso8601 })
        original = @report.review_draft.deep_dup
        get path
        assert_select "[data-historical-draft]"
        assert_select "input[name='decision[ai_proposal_id]'][value]", count: 0
        assert_select "textarea[name='decision[body]']", text: "Staff edited text"
        assert_equal original, @report.reload.review_draft
        get "/admin/bih/reports/batch"
        assert_select "input[name$='[ai_proposal_id]']", count: 0
        values = ReportReviewProposal.staff_draft_values(@report)
        ReportDecision.new(@report, @admin).call(action: "save_draft", values:, version: ReportReviewVersion.digest(@report))
        assert_equal "Staff edited text", @report.reload.review_draft.dig("values", "body")
        assert_nil @report.review_draft.dig("values", "ai_proposal_id")
        assert_nil legacy.reload.decided_at
      end

      test "unclassified forms and obsolete queue URLs make missing classification visible" do
        @report.update!(category: nil, severity: nil)
        get path
        assert_select "[data-category-missing]"
        %w(category severity).each do |field|
          assert_select "select[name='decision[#{field}]'] option:first-child[value='']"
          assert_select "select[name='decision[#{field}]'] option[selected]", count: 0
        end
        get "/admin/bih/reports", params: { needs_review: "1", attention: "needs_review" }
        assert_response :success
        assert_includes response.body, @report.reference
        assert_select "[data-category-missing]"
        row = css_select("#admin-reports-list tbody tr").sole
        assert_not_includes row.text, "=>"
        assert_not_includes row.text, I18n.t("decidim.bih.reports.severities.nizak")
        context = ReportQueueContext.new(organization: @organization, actor: @admin, params: { needs_review: "1", attention: "needs_review" })
        assert_equal "review", context.view
        assert_not_includes context.path, "needs_review"
      end

      test "blank classifications permit asking and saving but not review send or plan" do
        @report.update!(category: nil, severity: nil)
        values = { category: "", severity: "", draft_action: "ask", body: "Which crossing?" }
        ReportDecision.new(@report, @admin).call(action: "save_draft", values:, version: ReportReviewVersion.digest(@report))
        assert_nil @report.reload.review_draft.dig("values", "category")
        %w(review plan).each do |action|
          assert_raises(ReportDecision::Invalid) do
            ReportDecision.new(@report, @admin).call(action:, values:, version: ReportReviewVersion.digest(@report), confirmed: true)
          end
        end
        assert_raises(ReportDecision::Invalid) do
          ReportDecision.new(@report, @admin).preview(action: "send", values:, version: ReportReviewVersion.digest(@report))
        end
        ReportDecision.new(@report, @admin).call(action: "ask", values:, version: ReportReviewVersion.digest(@report), confirmed: true)
        assert_nil @report.reload.category
        assert_nil @report.severity
        assert_equal "needs_information", @report.review_state
      end

      test "every mapped and identity case action retains its staff decision binding" do
        expected = { "send_initial" => "send", "answer_city" => "followup", "close" => "reject", "wait" => nil }
        Ai::CaseDecision::ACTIONS.each do |action|
          row = @report.review_proposals.new(prompt_version: Ai::CaseAgent::PROMPT_VERSION)
          row.proposal = { "proposed_action" => action }
          mapped = expected.fetch(action, action)
          assert_equal mapped, row.suggested_values["draft_action"] if mapped
          assert_nil row.suggested_values["draft_action"] unless mapped
          assert_includes ReportDecision::AI_DECISION_ACTIONS, mapped if mapped
        end
      end

      test "another organization cannot request or adopt a proposal" do
        foreign = create_organization
        report = Report.create!(organization: foreign, description: "Foreign evidence")
        proposal = report.review_proposals.create!(input_digest: Ai::ReportReviewContext.new(report).digest, prompt_version: Ai::CaseAgent::PROMPT_VERSION,
                                                   state: "ready", proposal: { "proposed_action" => "review" })
        post "#{path}/review-proposals/#{proposal.id}/adopt", params: { input_version: ReportReviewVersion.digest(@report) }
        assert_response :not_found
        assert_no_enqueued_jobs(only: ReportReviewProposalJob) do
          post "/admin/bih/reports/#{report.reference}/review-proposals"
        end
        assert_redirected_to "/admin/"
        assert_empty @report.reload.review_draft
      end

      def path = "/admin/bih/reports/#{@report.reference}"

      def adopt_path = "#{path}/review-proposals/#{@proposal.id}/adopt"

      test "AI panel shows evidence and adoption fills a draft without approving or messaging" do
        get path
        assert_response :success
        assert_select "#report-ai-proposal", text: /Broken lamp/
        assert_select "#report-ai-proposal form[action='#{adopt_path}']"
        version = ReportReviewVersion.digest(@report)
        post adopt_path, params: { input_version: version }
        assert_response :redirect
        assert_equal "ask", @report.reload.review_draft.dig("values", "draft_action")
        assert_equal @proposal.id, @report.review_draft.dig("values", "ai_proposal_id")
        assert_nil @report.reviewed_at
        assert_empty @report.case_messages
        assert_empty @report.dispatches
        assert_nil @proposal.reload.decided_by_id
        get path
        assert_select "#report-decision-form option[value=ask][selected]"
        assert_select "#report-decision-form textarea[name='decision[body]']", text: "Which crossing?"
      end

      test "returning to earlier input selects its valid proposal in detail and batch review" do
        original_address = @report.address
        @report.update!(address: "Abandoned correction")
        newer = @report.review_proposals.create!(input_digest: Ai::ReportReviewContext.new(@report).digest,
                                                 prompt_version: Ai::CaseAgent::PROMPT_VERSION, state: "unavailable", error_code: "unavailable")
        @report.update!(address: original_address)
        before = @report.attributes
        assert_equal @proposal.id, ReportReviewProposal.for_review(@report).id
        assert_operator newer.id, :>, @proposal.id
        get path
        assert_response :success
        assert_select "#report-ai-proposal form[action='#{adopt_path}']"
        get "/admin/bih/reports/batch", params: { return_to: "/admin/bih/reports?view=all&q=#{@report.reference}" }
        assert_response :success
        assert_select "input[name='batch_items[0][values][ai_proposal_id]'][value='#{@proposal.id}']"
        assert_select "input[name='batch_items[0][choose]']"
        assert_equal before, @report.reload.attributes
      end

      test "a matching unavailable version takes precedence over a newer different-input ready proposal" do
        original = @report.address
        @report.update!(address: "Unavailable current address")
        failed = @report.review_proposals.create!(input_digest: Ai::ReportReviewContext.new(@report).digest,
                                                  prompt_version: Ai::CaseAgent::PROMPT_VERSION, state: "unavailable", error_code: "unavailable")
        @report.update!(address: "Different ready address")
        @report.review_proposals.create!(input_digest: Ai::ReportReviewContext.new(@report).digest,
                                         prompt_version: Ai::CaseAgent::PROMPT_VERSION, state: "ready", proposal: @proposal.proposal)
        @report.update!(address: "Unavailable current address")
        assert_equal failed.id, ReportReviewProposal.for_review(@report).id
        get path
        assert_select "#report-ai-proposal form[action$='/adopt']", count: 0
        @report.update!(address: original)
        assert_equal @proposal.id, ReportReviewProposal.for_review(@report).id
      end

      test "retained decision metadata renders after private proposal and mail content are removed" do
        @report.update!(review_state: "validated", reviewed_at: Time.current, forwarding_recipient: "intake@example.org")
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        dispatch.update!(state: "accepted", accepted_at: Time.current)
        Privacy::ReportReviewRetention.new(organization: @organization, cutoff: 1.day.from_now, dry_run: false).call
        get path
        assert_response :success
        assert_select "#report-ai-proposal", text: /#{Regexp.escape(I18n.t("decidim.bih.review_workspace.retention_removed"))}/
        assert_select "details#report-dispatch-#{dispatch.id} pre", count: 0
        assert_select "details#report-dispatch-#{dispatch.id}", text: /#{Regexp.escape(I18n.t("decidim.bih.review_workspace.retention_removed"))}/
        assert_equal "accepted", dispatch.reload.state
      end

      test "pending delivery shows waiting explanation instead of ineffective AI controls" do
        @report.update!(review_state: "validated", reviewed_at: Time.current, forwarding_recipient: "intake@example.org")
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        ReportCaseWorkflow.new(@report, nil).reply(body: "Later correction")
        %w(queued sending unknown).each do |state|
          dispatch.update!(state:)
          get path
          assert_response :success
          assert_select "[data-ai-waiting-for-delivery]"
          assert_select "#report-ai-proposal form", count: 0
          assert_select "#report-decision-form"
        end
      end

      test "oversized AI context explains manual fallback without offering adoption" do
        @report.update!(description: "Too much evidence " * 4000)
        ReportReviewAssistant.new.call(@report)
        get path
        assert_response :success
        assert_select "[data-ai-context-too-large]"
        assert_select "#report-ai-proposal form[action$='/adopt']", count: 0
        assert_select "#report-decision-form"
      end

      test "AI citations link to the exact accepted outgoing message" do
        @report.update!(review_state: "validated", reviewed_at: Time.current, forwarding_recipient: "intake@example.org")
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        dispatch.update!(state: "accepted", accepted_at: Time.current)
        @report.update!(review_state: "pending", forwarded_at: Time.current, status: "proslijedjeno")
        value = @proposal.proposal.merge("facts" => [{ "text" => "Earlier sent description", "source_id" => "dispatch:#{dispatch.id}", "quote" => "Broken lamp" }])
        @report.review_proposals.create!(input_digest: Ai::ReportReviewContext.new(@report).digest, prompt_version: Ai::CaseAgent::PROMPT_VERSION,
                                         state: "ready", model: "test-model", proposal: value)
        get path
        assert_response :success
        assert_select "#report-ai-proposal a[href='#report-dispatch-#{dispatch.id}']"
        assert_select "details#report-dispatch-#{dispatch.id} pre", text: /Broken lamp/
      end

      test "replacing a human draft needs explicit confirmation and the version must match" do
        @report.update!(review_draft: { values: { draft_action: "ask", body: "Human draft" } })
        version = ReportReviewVersion.digest(@report)
        assert_equal version, ReportReviewVersion.digest(@report.reload)
        post adopt_path, params: { input_version: version }
        assert_equal "Human draft", @report.reload.review_draft.dig("values", "body")
        post adopt_path, params: { input_version: version, replace_draft: "1" }
        assert_equal "Which crossing?", @report.reload.review_draft.dig("values", "body")
        modified = @report.review_draft.deep_dup
        modified["values"]["body"] = "New human edit"
        @report.update!(review_draft: modified)
        post adopt_path, params: { input_version: version, replace_draft: "1" }
        assert_equal "New human edit", @report.reload.review_draft.dig("values", "body")
      end

      test "new reply disables adoption even with a freshly loaded form version" do
        ReportCaseWorkflow.new(@report, nil).reply(body: "The southern crossing")
        get path
        assert_select "#report-ai-proposal form[action='#{adopt_path}']", count: 0
        post adopt_path, params: { input_version: ReportReviewVersion.digest(@report.reload) }
        assert_empty @report.reload.review_draft
        assert_nil @proposal.reload.decided_by_id
      end

      test "proposal lookup is scoped to the report" do
        other = Report.create!(organization: @organization, description: "Different problem", category: "rasvjeta")
        post "/admin/bih/reports/#{other.reference}/review-proposals/#{@proposal.id}/adopt", params: { input_version: ReportReviewVersion.digest(other) }
        assert_response :not_found
        assert_empty other.reload.review_draft
      end

      test "generation is opt in and queues only a proposal job" do
        Setting.put(@organization, "report_review", "case_agent", "off")
        assert_no_enqueued_jobs(only: ReportReviewProposalJob) { post "#{path}/review-proposals" }
        Setting.put(@organization, "report_review", "case_agent", "shadow")
        assert_enqueued_jobs(1, only: ReportReviewProposalJob) { post "#{path}/review-proposals" }
        assert_response :redirect
        assert_nil @report.reload.reviewed_at
      end
    end
  end
end
