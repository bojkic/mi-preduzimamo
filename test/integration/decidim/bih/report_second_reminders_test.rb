# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportSecondRemindersTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, author: @citizen,
                                 reference: "BR-2026-0008", description: "Private street safety concern",
                                 latitude: 44.75, longitude: 19.21)
        @question = @report.case_messages.create!(actor_role: "staff", kind: "question", body: "Which crossing needs a review?")
        @report.update!(review_state: "needs_information", response_due_at: 1.day.ago, deadline_kind: "citizen")
        host! @organization.host
        clear_enqueued_jobs
      end

      test "preparation stores an encrypted phone intent once" do
        reminder = prepare_reminder

        assert_equal @question, reminder.question
        assert_equal ["viber"], reminder.account_notification.payload.fetch("channels")
        assert_includes reminder.account_notification.payload.fetch("text"), @question.body
        assert_includes reminder.account_notification.payload.fetch("text"), @report.tokenized_status_path
        assert_not_includes reminder.account_notification.payload_ciphertext, @report.status_token
        assert_not_includes enqueued_jobs.inspect, @report.status_token
        assert_nil reminder.response_due_at
        assert_raises(ArgumentError) { prepare_reminder }
      end

      test "daily job reminds any expired question, but not answered or future ones" do
        answered = Report.create!(organization: @organization, author: @citizen, description: "Answered concern")
        answered.case_messages.create!(actor_role: "staff", kind: "question", body: "Which street?")
        answered.update!(review_state: "needs_information", response_due_at: 1.day.ago, deadline_kind: "citizen",
                         last_citizen_reply_at: Time.current)
        future = Report.create!(organization: @organization, author: @citizen, description: "Future concern")
        future.case_messages.create!(actor_role: "staff", kind: "question", body: "Which house?")
        future.update!(review_state: "needs_information", response_due_at: 1.day.from_now, deadline_kind: "citizen")

        assert_equal [@report.id, answered.id].sort, ReportSecondReminders.due_reports.pluck(:id).sort
        AccountNotifications.stub(:preview, { channels: %w(viber whatsapp), reasons: {} }) do
          ReportCaseReminderJob.perform_now
        end
        assert @report.reload.second_reminder
        assert_equal %w(viber whatsapp), @report.second_reminder.account_notification.payload.fetch("channels")
        assert_nil answered.reload.second_reminder
        assert_nil future.reload.second_reminder
      end

      test "Viber opt-out stops preparation without a fallback intent" do
        AccountNotifications.stub(:preview, { channels: [], reasons: { "viber" => "permission_required" } }) do
          assert_no_difference ["ReportSecondReminder.count", "AccountNotification.count"] do
            assert_raises(ArgumentError) { ReportSecondReminders.prepare!(@report) }
          end
        end
      end

      test "citizen reply before the queued send prevents provider contact" do
        reminder = prepare_reminder
        ReportCaseWorkflow.new(@report, @citizen).reply(body: "At the school gate")
        calls = []
        AccountNotifications.stub(:dispatch!, ->(notification) { calls << notification.id }) do
          ReportSecondReminderJob.perform_now(reminder.id)
        end

        assert_empty calls
        assert_equal "skipped", reminder.reload.outcome
        assert_equal "skipped", reminder.account_notification.reload.status
        assert_nil reminder.response_due_at
      end

      test "retry does not repeat an accepted provider request and acceptance does not start the deadline" do
        reminder = prepare_reminder
        calls = []
        AccountNotifications.stub(:dispatch!, lambda { |notification|
          calls << notification.id
          notification.update!(status: "accepted", channels: ["viber"])
        }) do
          2.times { ReportSecondReminderJob.perform_now(reminder.id) }
        end

        assert_equal [reminder.account_notification_id], calls
        assert_equal "accepted", reminder.reload.outcome
        assert_nil reminder.response_due_at
        assert_equal :not_due, ReportSecondReminders.close_due!(reminder)
        assert_nil @report.reload.removed_from_public_at
      end

      test "worker failure after durable claim stays uncertain and cannot resend" do
        reminder = prepare_reminder
        AccountNotifications.stub(:dispatch!, ->(_notification) { raise IOError, "simulated worker exit" }) do
          assert_raises(IOError) { ReportSecondReminderJob.perform_now(reminder.id) }
        end
        assert_equal "claimed", reminder.reload.outcome
        assert_equal "pending", reminder.account_notification.reload.status

        calls = []
        AccountNotifications.stub(:dispatch!, ->(notification) { calls << notification.id }) do
          ReportSecondReminderJob.perform_now(reminder.id)
        end
        assert_empty calls
        assert_nil reminder.reload.response_due_at
      end

      test "eligibility lost before dispatch is recorded without a deadline" do
        reminder = prepare_reminder
        AccountNotifications.stub(:dispatch!, ->(notification) { notification.update!(status: "skipped", reason: "eligibility_changed") }) do
          ReportSecondReminderJob.perform_now(reminder.id)
        end
        assert_equal "skipped", reminder.reload.outcome
        assert_nil reminder.response_due_at
        assert_equal :not_due, ReportSecondReminders.close_due!(reminder)
      end

      test "a reminder still unconfirmed after it expires hands the case to staff once" do
        reminder = prepare_reminder
        reminder.account_notification.update!(status: "accepted", reason: "provider_undeliverable")
        AccountNotifications.stub(:reconcile!, reminder.account_notification) { ReportSecondReminders.reconcile!(reminder) }
        assert_empty @report.obligations.open.where(actor: "staff")

        travel_to(reminder.account_notification.expires_at + 1.minute) do
          2.times do
            AccountNotifications.stub(:reconcile!, reminder.account_notification) { ReportSecondReminders.reconcile!(reminder) }
          end
          assert_includes ReportWorkQueue.new(organization: @organization).scope("review"), @report
        end
        task = @report.obligations.open.find_by!(actor: "staff", kind: "review")
        assert_equal "second_reminder_undelivered", task.metadata["reason"]
        assert_equal @question, task.source
        assert_equal 1, @report.obligations.where(kind: "review").count
        assert_equal "accepted", reminder.reload.outcome
        assert_equal "needs_information", @report.reload.review_state
        assert_includes ReportTaskExplanation.call(task), I18n.t("decidim.bih.report_tasks.explain.second_reminder_undelivered", locale: :sr).first(20)
      end

      test "a provider failure at send hands the case to staff, a skipped send after a reply does not" do
        reminder = prepare_reminder
        AccountNotifications.stub(:dispatch!, ->(notification) { notification.update!(status: "failed", reason: "provider_rejected") }) do
          ReportSecondReminderJob.perform_now(reminder.id)
        end
        assert_equal "failed", reminder.reload.outcome
        assert_equal "second_reminder_undelivered", @report.obligations.open.find_by!(actor: "staff", kind: "review").metadata["reason"]

        other = Report.create!(organization: @organization, author: @citizen, description: "Another concern")
        other.case_messages.create!(actor_role: "staff", kind: "question", body: "Which house?")
        other.update!(review_state: "needs_information", response_due_at: 1.day.ago, deadline_kind: "citizen")
        skipped = AccountNotifications.stub(:preview, { channels: ["viber"], reasons: {} }) { ReportSecondReminders.prepare!(other) }
        ReportCaseWorkflow.new(other, @citizen).reply(body: "Number 4")
        ReportSecondReminderJob.perform_now(skipped.id)
        assert_equal "skipped", skipped.reload.outcome
        assert_empty other.obligations.open.where(actor: "staff", kind: "review").where("metadata ->> 'reason' = ?", "second_reminder_undelivered")
      end

      test "confirmed delivery sets three days and an unanswered case then closes automatically" do
        reminder = prepare_reminder
        delivered_at = Time.current.change(usec: 0)
        reminder.account_notification.update!(status: "delivered", channels: ["whatsapp"], delivered_at:)
        AccountNotifications.stub(:reconcile!, reminder.account_notification) do
          ReportSecondReminders.reconcile!(reminder)
        end
        assert_equal delivered_at + 3.days, reminder.reload.response_due_at
        assert_equal reminder.response_due_at, @report.reload.response_due_at
        assert_equal :not_due, ReportSecondReminders.close_due!(reminder)

        travel_to(reminder.response_due_at + 1.second) do
          assert_equal :closed, ReportSecondReminders.close_due!(reminder)
          assert_equal :not_due, ReportSecondReminders.close_due!(reminder)
        end
        assert_equal "odbijeno", @report.reload.status
        assert_equal "rejected", @report.review_state
        assert_equal ReportSecondReminders::CLOSURE_REASON, @report.status_note
        assert @report.removed_from_public_at
        assert_equal "closed", reminder.reload.outcome
        assert reminder.closed_at
        assert_equal 1, @report.events.where(event_type: "case_second_reminder_closed").count
        assert_empty @report.obligations.open.where(actor: %w(citizen city))
      end

      test "a reply after delivery prevents closure even when three days pass" do
        reminder = prepare_reminder
        delivered_at = Time.current.change(usec: 0)
        reminder.account_notification.update!(status: "delivered", channels: ["viber"], delivered_at:)
        AccountNotifications.stub(:reconcile!, reminder.account_notification) { ReportSecondReminders.reconcile!(reminder) }
        ReportCaseWorkflow.new(@report, @citizen).reply(body: "At the school gate")

        travel_to(delivered_at + 3.days + 1.hour) do
          assert_equal :changed, ReportSecondReminders.close_due!(reminder)
        end
        assert_equal "primljeno", @report.reload.status
        assert_nil @report.removed_from_public_at
      end

      test "late private reply reopens historical automatic closure for visible review and preserves history" do
        reminder = historically_closed_reminder
        closure = @report.events.find_by!(event_type: "case_second_reminder_closed")
        history = @report.reload.status_history.deep_dup
        evidence = reminder.reload.attributes.slice("closed_at", "delivered_at", "response_due_at", "account_notification_id", "question_id")

        travel_to(reminder.closed_at + 1.hour) do
          post @report.tokenized_status_path, params: { case_message: { body: "Private late crossing details" } }
          assert_response :redirect
        end

        reply = @report.case_messages.order(:id).last
        assert_equal "primljeno", @report.reload.status
        assert_equal "pending", @report.review_state
        assert_nil @report.removed_from_public_at
        assert_nil @report.status_note
        assert_equal reply.created_at, @report.review_pending_since
        assert_equal reply.created_at + ReportWorkQueue::REVIEW_DAYS.days, @report.response_due_at
        assert_equal "review", @report.deadline_kind
        assert_includes ReportWorkQueue.new(organization: @organization).scope("review"), @report
        assert_equal history, @report.status_history[0...-1]
        assert_equal "primljeno", @report.status_history.last.fetch("status")
        assert_equal "replied", reminder.reload.outcome
        assert_equal evidence, reminder.attributes.slice(*evidence.keys)
        assert_equal closure.attributes, closure.reload.attributes
        assert @report.case_messages.exists?(@question.id)
        event = @report.events.find_by!(event_type: "status_changed")
        assert_equal "public", event.source
        assert_equal "citizen", event.actor_role
        assert_equal({ "from_status" => "odbijeno", "to_status" => "primljeno", "reason" => "late_reply_after_second_reminder",
                       "reminder_id" => reminder.id, "message_id" => reply.id }, event.metadata)

        get "/biceriseno/prijave"
        assert_includes response.body, @report.reference
        get "/biceriseno/prijave/#{@report.reference}"
        assert_response :success
        assert_not_includes response.body, reply.body
        get "/biceriseno/mapa.json"
        assert_includes response.body, @report.reference
      end

      test "repeated reconciliation and send timers cannot reclose or resend after a late reply" do
        reminder = historically_closed_reminder
        closed_at = reminder.closed_at
        travel_to(closed_at + 1.hour) do
          post @report.tokenized_status_path, params: { case_message: { body: "At the school gate" } }
          assert_response :redirect
        end
        reply = @report.case_messages.order(:id).last
        assert_no_difference ["ReportEvent.count", "ReportMessage.count", "AccountNotification.count"] do
          @report.with_lock { assert_not ReportSecondReminders.reopen_after_reply!(@report, message: reply) }
          travel_to(closed_at + 3.days) do
            AccountNotifications.stub(:dispatch!, ->(*) { flunk "must not resend" }) do
              2.times do
                ReportSecondReminders.reconcile!(reminder)
                assert_equal :not_due, ReportSecondReminders.close_due!(reminder)
                ReportSecondReminderJob.perform_now(reminder.id)
              end
            end
          end
        end
        assert_equal "primljeno", @report.reload.status
        assert_nil @report.removed_from_public_at
        assert_equal closed_at, reminder.reload.closed_at
        assert_equal 1, @report.events.where(event_type: "status_changed").count
      end

      %w(reject resolve duplicate).each do |decision|
        test "citizen reply does not reopen deliberate #{decision} with a second reminder" do
          prepare_reminder
          admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          target = Report.create!(organization: @organization, description: "Another concern")
          values = { reason: "Deliberate staff decision", resolution_evidence: "Inspected on site", duplicate_reference: target.reference }
          ReportDecision.new(@report, admin).call(action: decision, values:, version: ReportReviewVersion.digest(@report), confirmed: true)
          before = @report.reload.attributes.slice("status", "review_state", "status_note", "duplicate_of_report_id", "status_history")

          post @report.tokenized_status_path, params: { case_message: { body: "Additional detail" } }
          assert_response :redirect
          assert_equal before, @report.reload.attributes.slice(*before.keys)
          assert_nil @report.second_reminder.closed_at
        end
      end

      %w(save_draft claim assign note).each do |action|
        test "late reply reopens historical automatic closure after staff #{action}" do
          reminder = historically_closed_reminder
          admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          travel_to(reminder.closed_at + 1.hour) do
            ReportDecision.new(@report, admin).call(action:, values: { body: "Review when details arrive", assigned_to_id: admin.id },
                                                    version: ReportReviewVersion.digest(@report.reload), confirmed: true)
            post @report.tokenized_status_path, params: { case_message: { body: "At the school gate" } }
            assert_response :redirect
          end
          assert_equal "primljeno", @report.reload.status
          assert_equal "pending", @report.review_state
          assert_nil @report.removed_from_public_at
          assert_equal "replied", reminder.reload.outcome
          assert @report.events.exists?(event_type: "case_second_reminder_closed")
        end
      end

      test "later staff rejection with the same closure wording prevents reopening" do
        reminder = historically_closed_reminder
        admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        travel_to(reminder.closed_at + 1.hour) do
          ReportCaseWorkflow.new(@report, admin).update(review_state: "rejected", confirm_review: "1", status_note: ReportSecondReminders::CLOSURE_REASON)
          post @report.tokenized_status_path, params: { case_message: { body: "Additional detail" } }
          assert_response :redirect
        end
        assert_equal "odbijeno", @report.reload.status
        assert @report.removed_from_public_at
        assert_equal "closed", reminder.reload.outcome
        assert_empty @report.events.where(event_type: "status_changed")
      end

      test "later decision provenance prevents reopening even without a review timestamp" do
        reminder = historically_closed_reminder
        travel_to(reminder.closed_at) do
          @report.record_event!("case_reviewed", source: "admin", metadata: { review_state: "rejected" })
          assert_nil @report.reviewed_at
          post @report.tokenized_status_path, params: { case_message: { body: "Additional detail" } }
          assert_response :redirect
        end
        assert_equal "odbijeno", @report.reload.status
        assert @report.removed_from_public_at
        assert_equal "closed", reminder.reload.outcome
      end

      test "closure wording and reminder state without automatic closure provenance do not reopen" do
        reminder = prepare_reminder
        reminder.update!(outcome: "closed", closed_at: Time.current)
        @report.update!(status: "odbijeno", review_state: "rejected", status_note: ReportSecondReminders::CLOSURE_REASON,
                        removed_from_public_at: Time.current)
        post @report.tokenized_status_path, params: { case_message: { body: "Additional detail" } }
        assert_response :redirect
        assert_equal "odbijeno", @report.reload.status
        assert @report.removed_from_public_at
      end

      private

      def historically_closed_reminder
        reminder = prepare_reminder
        reminder.account_notification.update!(status: "delivered", channels: ["viber"], delivered_at: Time.current.change(usec: 0))
        AccountNotifications.stub(:reconcile!, reminder.account_notification) { ReportSecondReminders.reconcile!(reminder) }
        travel_to(reminder.response_due_at + 1.second) do
          @report.update!(status: "odbijeno", review_state: "rejected", status_note: ReportSecondReminders::CLOSURE_REASON,
                          removed_from_public_at: Time.current, response_due_at: nil, deadline_kind: nil)
          reminder.update!(outcome: "closed", closed_at: Time.current)
          @report.record_event!("case_second_reminder_closed", source: "system", metadata: { reminder_id: reminder.id })
        end
        reminder.reload
      end

      def prepare_reminder
        AccountNotifications.stub(:preview, { channels: ["viber"], reasons: { "viber" => nil } }) do
          ReportSecondReminders.prepare!(@report)
        end
      end
    end
  end
end
