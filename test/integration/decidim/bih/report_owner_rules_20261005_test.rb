# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Owner decisions of 2026-10-05: automatic City follow-up, held closure after
    # a channel message, no-reply points rule and AI agreement summary.
    class ReportOwnerRules20261005Test < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        clear_enqueued_jobs
      end

      def forwarded_report(**attributes)
        Report.create!({ organization: @organization, description: "Private problem description", address: "Test street",
                         category: "rasvjeta", severity: "normalan", review_state: "validated", reviewed_at: 30.days.ago,
                         status: "proslijedjeno", forwarded_at: 30.days.ago, forwarding_recipient: "intake@example.org" }.merge(attributes))
      end

      test "an overdue City task gets exactly one automatic follow-up on a weekday" do
        # Anchor every date to the fixed Monday: a task due "2 days before the real clock"
        # stops being overdue on that Monday once the real clock passes 2026-10-28.
        monday = Time.zone.parse("2026-10-26 08:20")
        travel_to(monday) do
          forwarded = { forwarded_at: monday - 30.days, reviewed_at: monday - 30.days }
          report = forwarded_report(**forwarded)
          report.obligations.create!(kind: "city_response", actor: "city", due_at: monday - 2.days)
          waiting_for_city = forwarded_report(description: "City already answered", **forwarded)
          waiting_for_city.obligations.create!(kind: "city_response", actor: "city", due_at: monday - 2.days, metadata: { inbound_email_id: 1 })

          sent = ReportCityFollowups.run!(organization: @organization)
          assert_equal [report.id], sent.map(&:report_id)
          assert_equal "followup", sent.first.kind
          assert_includes sent.first.snapshot.fetch("body"), report.reference
          assert report.events.exists?(event_type: ReportCityFollowups::EVENT)
          assert_empty ReportCityFollowups.run!(organization: @organization)
        end
        travel_to(Time.zone.parse("2026-10-25 08:20")) { assert_empty ReportCityFollowups.run!(organization: @organization) }
      end

      test "a Viber or WhatsApp message after the reminder holds the automatic closure for staff" do
        report = Report.create!(organization: @organization, author: @citizen, description: "Private street concern")
        question = report.case_messages.create!(actor_role: "staff", kind: "question", body: "Which crossing?")
        report.update!(review_state: "needs_information", response_due_at: 1.day.ago, deadline_kind: "citizen")
        reminder = AccountNotifications.stub(:preview, { channels: ["viber"], reasons: {} }) { ReportSecondReminders.prepare!(report) }
        reminder.account_notification.update!(status: "delivered", channels: ["viber"], delivered_at: Time.current)
        AccountNotifications.stub(:reconcile!, reminder.account_notification) { ReportSecondReminders.reconcile!(reminder) }
        assert_equal 1, ReportSecondReminders.note_channel_message!(user: @citizen, channel: "whatsapp")

        travel_to(reminder.reload.response_due_at + 1.minute) do
          assert_equal :held, ReportSecondReminders.close_due!(reminder)
          assert_equal :held, ReportSecondReminders.close_due!(reminder)
        end
        assert_equal "needs_information", report.reload.review_state
        assert_equal 1, report.obligations.where(kind: "review", state: "open").count
        assert_equal question.id, report.obligations.find_by(kind: "review").source_id
      end

      test "the citizen task follows the reminder so the case is not reported overdue" do
        report = Report.create!(organization: @organization, author: @citizen, description: "Private street concern")
        question = report.case_messages.create!(actor_role: "staff", kind: "question", body: "Which crossing?")
        report.update!(review_state: "needs_information", response_due_at: 1.day.ago, deadline_kind: "citizen")
        task = report.obligations.create!(kind: "info_request", actor: "citizen", due_at: 1.day.ago, source: question)
        assert ReportWorkQueue.overdue.exists?(id: report.id)
        reminder = AccountNotifications.stub(:preview, { channels: ["viber"], reasons: {} }) { ReportSecondReminders.prepare!(report) }
        assert_operator task.reload.due_at, :>, 2.days.from_now
        assert_not ReportWorkQueue.overdue.exists?(id: report.id)

        delivered_at = 1.hour.ago.change(usec: 0)
        reminder.account_notification.update!(status: "delivered", channels: ["viber"], delivered_at:)
        AccountNotifications.stub(:reconcile!, reminder.account_notification) { ReportSecondReminders.reconcile!(reminder) }
        assert_equal delivered_at + 3.days, task.reload.due_at
      end

      test "a race report closed for no reply keeps its points, a later one does not" do
        Decidim::Bih::Goodwill::EarningRules.stub(:points_for_action, 20) do
          race = forwarded_report(status: "odbijeno", review_state: "rejected", closure_basis: "bez_odgovora", created_at: Time.zone.parse("2026-10-01"))
          assert_equal 20, Goodwill::ReportEntitlement.outcome_target(race)
          rejected = forwarded_report(status: "odbijeno", review_state: "rejected", created_at: Time.zone.parse("2026-10-01"))
          assert_equal 0, Goodwill::ReportEntitlement.outcome_target(rejected)
          later = forwarded_report(status: "odbijeno", review_state: "rejected", closure_basis: "bez_odgovora", created_at: Time.zone.parse("2026-10-20"))
          assert_equal 0, Goodwill::ReportEntitlement.outcome_target(later)
        end
      end

      test "a case-agent suggestion leads the card and can be accepted into the decision form" do
        report = Report.create!(organization: @organization, description: "Lamp is broken", address: "Test street", category: "rasvjeta")
        digest = Ai::ReportReviewContext.new(report).digest
        draft = report.review_proposals.create!(input_digest: digest, prompt_version: "report-review-v8", state: "generating")
        draft.update!(state: "ready", proposal: { "action" => "ask", "question" => "Which lamp?" }, finished_at: Time.current)
        agent = report.review_proposals.create!(input_digest: "pending", prompt_version: Ai::CaseAgent::PROMPT_VERSION, state: "generating")
        agent.update!(state: "ready", input_digest: digest, finished_at: Time.current,
                      proposal: { "proposed_action" => "send_initial", "routing" => { "category" => "rasvjeta" },
                                  "city_message" => { "text" => "Lamp by the school" }, "citizen_message" => {} })
        assert_equal agent, ReportReviewProposal.for_review(report)
        values = agent.suggested_values
        assert_equal "send", values["draft_action"]
        ReportDecision.new(report, @admin).call(action: "save_draft", values:, version: ReportReviewVersion.digest(report))
        assert_equal "send", report.reload.review_draft.dig("values", "draft_action")

        waiting = report.review_proposals.new(prompt_version: Ai::CaseAgent::PROMPT_VERSION)
        waiting.proposal = { "proposed_action" => "wait", "citizen_message" => {} }
        assert_nil waiting.suggested_values["draft_action"]
      end

      test "agreement compares each suggestion with the next substantive staff decision" do
        report = Report.create!(organization: @organization, description: "Lamp is broken", address: "Test street", category: "rasvjeta")
        proposal = report.review_proposals.create!(input_digest: "x", prompt_version: Ai::CaseAgent::PROMPT_VERSION, state: "generating")
        proposal.update!(state: "ready", proposal: { "proposed_action" => "send_initial" }, finished_at: Time.current)
        assert_equal({ compared: 0, agreed: 0, waiting: 1 }, ReportAiAgreement.compute(report.review_proposals))
        report.record_event!("case_decision_applied", actor: @admin, metadata: { action: "save_draft" })
        report.record_event!("case_decision_applied", actor: @admin, metadata: { action: "review" })
        assert_equal({ compared: 1, agreed: 1, waiting: 0 }, ReportAiAgreement.compute(report.review_proposals))
      end
    end
  end
end
