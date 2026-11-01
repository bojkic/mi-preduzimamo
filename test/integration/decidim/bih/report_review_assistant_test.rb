# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportReviewAssistantTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      class FakeClient
        attr_accessor :result, :on_call
        attr_reader :requests

        def initialize = @requests = []

        def generate_content(**args)
          requests << args
          returned = result.deep_dup
          on_call&.call
          returned
        end
      end

      class Meter
        def call(client:, **args) = client.generate_content(**args)
      end

      def run
        factory = Ai::CaseAgent.method(:new)
        Ai::CaseAgent.stub(:new, ->(report, **opts) { factory.call(report, client: @client, usage: Meter.new, **opts) }) { super }
      end

      setup do
        @organization = create_organization
        @report = Report.create!(organization: @organization, description: "Broken lamp by the school", address: "Test street")
        @client = FakeClient.new
        @client.result = valid_proposal
        @assistant = ReportReviewAssistant.new
        Setting.put(@organization, "report_review", "case_agent", "shadow")
      end

      def valid_proposal
        { "assessment" => { "in_scope" => true, "kind" => "kvar", "hazard_signal" => false, "hazard_quote" => "" },
          "missing_fields" => [], "citizen_message" => { "template_key" => "", "composed_text" => "", "slots" => { "text" => "", "date" => "" } },
          "duplicate" => { "reference" => "", "quote_new" => "", "quote_existing" => "" },
          "routing" => { "category" => "rasvjeta", "recipient_key" => "", "guidance_key" => "" },
          "city_message" => { "kind" => "initial", "text" => "", "evidence_item_ids" => [] },
          "service_response" => { "type" => "unclear", "quote" => "", "planned_date_quote" => "", "file_numbers" => [], "requested_evidence" => [] },
          "proposed_action" => "review", "obligation_updates" => [],
          "facts" => [{ "text" => "Broken lamp", "source_id" => "original", "quote" => "Broken lamp" }],
          "observations" => [], "rationale" => "Predlažem pregled.", "uncertainties" => [] }
      end
      test "context distinguishes accepted outgoing content from new replies and unfinished attempts" do
        admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report.update!(review_state: "validated", reviewed_at: Time.current, forwarding_recipient: "intake@example.org", reporter_email: "private@example.org")
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        initial = ReportDispatching.queue!(report: @report, actor: admin, digest: ReportCaseWorkflow.digest(@report))
        initial.update!(state: "accepted", accepted_at: 1.hour.ago)
        @report.update!(status: "proslijedjeno", forwarded_at: 1.hour.ago)
        supplement = ReportDispatching.queue!(report: @report, actor: admin, digest: ReportCaseWorkflow.digest(@report), kind: "supplement",
                                              text: "Earlier correction already sent")
        supplement.update!(state: "accepted", accepted_at: 30.minutes.ago)
        pending = ReportDispatching.queue!(report: @report, actor: admin, digest: ReportCaseWorkflow.digest(@report), kind: "followup", text: "Unsent secret draft")
        reply = ReportCaseWorkflow.new(@report, nil).reply(body: "New location evidence")
        context = Ai::ReportReviewContext.new(@report.reload)
        assert_includes context.sources["dispatch:#{supplement.id}"], "Earlier correction already sent"
        assert_includes context.sources["dispatch:#{initial.id}"], "Broken lamp"
        assert_equal "New location evidence", context.sources["message:#{reply.id}"]
        assert_nil context.sources["dispatch:#{pending.id}"]
        %w(private@example.org intake@example.org).each { |contact| assert_not_includes context.data.to_json, contact }
        assert_not_includes context.data.to_json, "Unsent secret draft"
        assert_equal(%w(accepted accepted queued), context.data[:dispatch_history].map { |item| item[:state] })
        # All timestamp-bearing history keeps the worker representation in a request zone.
        @report.obligations.create!(kind: "city_response", actor: "city", state: "open", due_at: 2.days.from_now)
        worker_zone = Rails.application.config.time_zone
        worker_context = Time.use_zone(worker_zone) { Ai::ReportReviewContext.new(@report.reload).data }
        Time.use_zone("UTC") do
          @report.reload.created_at
          assert_equal worker_context, Ai::ReportReviewContext.new(@report).data
        end
        before = Ai::ReportReviewContext.new(@report.reload).digest
        pending.update!(state: "unknown")
        assert_not_equal before, Ai::ReportReviewContext.new(@report.reload).digest
      end

      test "context includes all replies while removing contacts identities and private URLs" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Test Reporter")
        @report.update!(author: user, reporter_email: "test@example.org", reporter_phone: "+38766123456",
                        description: "Broken lamp. Test Reporter test@example.org +38766123456 https://example.org/private?token=secret password=topsecret")
        ReportCaseWorkflow.new(@report, nil).reply(body: "Earlier location")
        reply = ReportCaseWorkflow.new(@report, nil).reply(body: "Correction: Nušićeva near Gavrila Principa")
        context = Ai::ReportReviewContext.new(@report.reload)
        assert_equal "Correction: Nušićeva near Gavrila Principa", context.sources["message:#{reply.id}"]
        assert_equal 2, context.data[:conversation].length
        %w(test@example.org +38766123456 topsecret https://example.org/private).each { |private_value| assert_not_includes context.data.to_json, private_value }
        assert_not_includes context.data.to_json, "Test Reporter"
        assert_equal @report.reference, context.redact(@report.reference)
        assert_equal "absent", context.data[:photo]
      end

      test "the sole agent deduplicates encrypted suggestions without classifying or sending" do
        version = ReportReviewVersion.digest(@report)
        proposal = nil
        assert_no_enqueued_jobs(only: ReportDispatchJob) { proposal = @assistant.call(@report) }
        assert_equal "ready", proposal.state
        assert_equal Ai::CaseAgent::PROMPT_VERSION, proposal.prompt_version
        assert_not_includes proposal.proposal_ciphertext, "Broken lamp"
        assert_equal version, ReportReviewVersion.digest(@report.reload)
        assert_nil @report.category
        assert_nil @report.severity
        assert_nil @report.forwarded_at
        assert_equal proposal.id, @assistant.call(@report, retry_failed: true, shadow_only: true).id
        assert_equal 2, @client.requests.size
        assert_not proposal.update(proposal: { "proposed_action" => "reject" })
      end

      test "oversized evidence persists a deduplicated marker without any provider call" do
        @report.update!(description: "Private oversized evidence " * 4000)
        proposal = @assistant.call(@report)
        assert_equal "unavailable", proposal.state
        assert_equal "context_too_large", proposal.error_code
        assert_equal "context_too_large", proposal.failure_reason
        assert_equal Ai::CaseAgent::PROMPT_VERSION, proposal.prompt_version
        assert_nil proposal.proposal_ciphertext
        assert_equal proposal.id, @assistant.call(@report, retry_failed: true).id
        assert_equal proposal.id, ReportReviewProposal.for_review(@report).id
        assert_empty @client.requests
        assert_not proposal.current?
        assert_includes ReportDecision.allowed_actions(@report), "ask"
        @report.update!(description: "Broken lamp by the school")
        assert_equal "ready", @assistant.call(@report).state
      end

      test "oversized sweep result is unavailable rather than skipped" do
        @report.update!(description: "Private oversized evidence " * 4000)
        Setting.put(@organization, ReportShadowSweep::NAMESPACE, ReportShadowSweep::KEY,
                    { "state" => "running", "actor_id" => 0, "pending" => [@report.id], "results" => [] })
        ReportShadowSweep.new(@organization).call
        sweep = Setting.namespace_for(@organization, ReportShadowSweep::NAMESPACE)[ReportShadowSweep::KEY]
        assert_equal "complete", sweep["state"]
        assert_equal "unavailable", sweep["results"].sole["state"]
        assert_equal "context_too_large", sweep["results"].sole["reason"]
        assert_empty @client.requests
      end

      test "queued work rechecks activation and on remains shadow only" do
        ReportReviewAssistant.enqueue(@report)
        assert_enqueued_with(job: ReportReviewProposalJob, args: [@report.id])
        Setting.put(@organization, "report_review", "case_agent", "off")
        ReportReviewProposalJob.perform_now(@report.id, retry_failed: true)
        assert_empty @client.requests
        assert_empty @report.review_proposals
        Setting.put(@organization, "report_review", "case_agent", "on")
        assert_equal "shadow", ReportReviewAssistant.case_agent_mode(@organization)
        assert_equal "ready", @assistant.call(@report).state
        assert_empty @report.dispatches
      end

      test "closed cases and unsettled delivery cannot generate" do
        @report.update!(status: "rijeseno")
        assert_nil @assistant.call(@report)
        @report.update!(status: "primljeno", category: "rasvjeta", review_state: "validated", reviewed_at: Time.current, forwarding_recipient: "intake@example.org")
        admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        dispatch = ReportDispatching.queue!(report: @report, actor: admin, digest: ReportCaseWorkflow.digest(@report))
        %w(queued sending unknown).each do |state|
          dispatch.update!(state:)
          assert_nil @assistant.call(@report)
        end
        assert_empty @client.requests
      end

      test "failed repair persists bounded diagnostics without the retired alert" do
        @client.result["facts"].first["text"] = "PRIVATE INVALID OUTPUT"
        proposal = nil
        assert_no_enqueued_jobs { proposal = @assistant.call(@report) }
        assert_equal "unavailable", proposal.state
        assert proposal.repair_attempted
        assert_equal "fact_not_quoted", proposal.failure_reason
        assert_equal 2, @client.requests.length
        event = @report.events.where(event_type: "case_agent_validation_failed").sole
        assert_not_includes event.metadata.to_json, "PRIVATE"
        assert_not_includes @client.requests.last.to_json, "PRIVATE"
        assert_empty proposal.proposal
        assert_equal proposal.id, @assistant.call(@report).id
        assert_equal 2, @client.requests.length
        @client.result = valid_proposal
        assert_equal "ready", @assistant.call(@report, retry_failed: true).state
      end

      test "new evidence during generation cannot become a current proposal" do
        @client.on_call = -> { @report.update!(description: "Changed evidence") }
        proposal = @assistant.call(@report)
        assert_equal "unavailable", proposal.state
        assert_equal "stale", proposal.failure_reason
        assert_not proposal.current?
      end

      test "accepting agent classification leaves severity unset and records staff corrections" do
        proposal = @assistant.call(@report)
        admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        ReportDecision.new(@report, admin).call(action: "save_draft", values: proposal.suggested_values, version: ReportReviewVersion.digest(@report))
        assert_nil @report.reload.category
        values = @report.review_draft["values"].merge("category" => "putevi", "severity" => "")
        ReportDecision.new(@report, admin).call(action: "review", values:, version: ReportReviewVersion.digest(@report), confirmed: true)
        assert_equal "putevi", @report.reload.category
        assert_nil @report.severity
        assert_equal admin.id, proposal.reload.decided_by_id
        assert_includes proposal.changed_fields, "category"
        assert_empty @report.dispatches
      end

      test "changed source and redacted rows cannot be adopted with a fresh form version" do
        proposal = @assistant.call(@report)
        admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report.update!(description: "New evidence")
        assert_raises(ReportDecision::Invalid) do
          ReportDecision.new(@report, admin).call(action: "save_draft", values: proposal.suggested_values, version: ReportReviewVersion.digest(@report))
        end
        Privacy::ReportReviewRetention.new(organization: @organization, cutoff: 1.day.from_now, dry_run: false).call
        assert_not proposal.reload.current?
        assert_empty proposal.suggested_values
      end
    end
  end
end
