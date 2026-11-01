# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ReportCaseWorkflowTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, author: @citizen, description: "Private speeding details",
                                 address: "Račanska", category: "saobracaj", severity: "visok", anonymous: true)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        host! @organization.host
        clear_enqueued_jobs
      end

      test "private reply photo is retained served privately and returns forwarded case to review" do
        @report.update!(status: "proslijedjeno", forwarded_at: 2.days.ago, review_state: "needs_information")
        upload = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/report-evidence.png"), "image/png")
        post @report.tokenized_status_path, params: { case_message: { body: "Requested vehicle photo", photo: upload } }
        assert_response :redirect
        message = @report.case_messages.last
        assert message.photo.attached?
        assert_equal "pending", @report.reload.review_state
        assert_equal "proslijedjeno", @report.status
        get @report.tokenized_status_path
        assert_select "input[type=file][name=?]", "case_message[photo]"
        assert_select "a[href=?]", "?photo_message_id=#{message.id}"
        get @report.tokenized_status_path, params: { photo_message_id: message.id }
        assert_response :success
        assert_equal "image/png", response.media_type
        assert_includes response.headers["Cache-Control"], "no-store"
        get "/biceriseno/prijave/#{@report.reference}", params: { photo_message_id: message.id }
        assert_not_equal "image/png", response.media_type
        get "/biceriseno/prijave/#{@report.reference}/status/wrong", params: { photo_message_id: message.id }
        assert_not_equal "image/png", response.media_type
        sign_in @admin
        get "/admin/bih/reports/#{@report.reference}", params: { photo_message_id: message.id }
        assert_response :success
        assert_equal "image/png", response.media_type
        other = Report.create!(organization: @organization, description: "Other report")
        get other.tokenized_status_path, params: { photo_message_id: message.id }
        assert_not_equal "image/png", response.media_type
      end

      test "private reply selects one question and fulfils only its persisted request without changing legacy reply projections" do
        freeze_time do
          @report.update!(status: "proslijedjeno", forwarded_at: 2.days.ago, review_state: "needs_information")
          control = Report.create!(organization: @organization, author: @citizen, description: @report.description, address: @report.address,
                                   category: @report.category, severity: @report.severity, anonymous: true, status: @report.status,
                                   forwarded_at: @report.forwarded_at, review_state: @report.review_state)
          questions = ["Which crossing?", "Please attach a photograph."].map do |body|
            @report.case_messages.create!(actor: @admin, actor_role: "staff", kind: "question", body:)
          end
          requests = questions.map { |question| ReportObligations.open!(@report, kind: "info_request", source: question) }
          get @report.tokenized_status_path
          assert_select "select[name=?] option[value=?]", "case_message[answers_message_id]", questions.last.id.to_s, count: 1
          post @report.tokenized_status_path, params: { case_message: { body: "Requested detail", answers_message_id: questions.last.id } }
          assert_response :redirect
          reply = @report.case_messages.where(actor_role: "citizen").last
          assert_equal questions.last, reply.answers_message
          assert_equal "open", requests.first.reload.state
          assert_nil requests.first.fulfilled_by
          assert_equal "fulfilled", requests.last.reload.state
          assert_equal reply, requests.last.fulfilled_by
          ReportCaseWorkflow.new(control, nil).reply(body: "Requested detail")
          fields = %w(status review_state review_pending_since response_due_at deadline_kind forwarded_at reviewed_at closure_basis removed_from_public_reason)
          assert_equal control.reload.attributes.slice(*fields), @report.reload.attributes.slice(*fields)
        end
      end

      test "derived legacy question binds a reply without creating persisted tasks" do
        @report.update!(review_state: "needs_information")
        question = @report.case_messages.create!(actor: @admin, actor_role: "staff", kind: "question", body: "Which crossing?")
        get @report.tokenized_status_path
        assert_select "input[type=hidden][name=?][value=?]", "case_message[answers_message_id]", question.id.to_s, count: 1
        assert_no_difference "ReportObligation.count" do
          post @report.tokenized_status_path, params: { case_message: { body: "At the school", answers_message_id: question.id } }
        end
        assert_equal question, @report.case_messages.where(actor_role: "citizen").last.answers_message
      end

      test "ambiguous duplicate requests and general replies never fulfil every question" do
        question = @report.case_messages.create!(actor: @admin, actor_role: "staff", kind: "question", body: "Which crossing?")
        requests = 2.times.map { ReportObligations.open!(@report, kind: "info_request", source: question) }
        ReportCaseWorkflow.new(@report, nil).reply(body: "At the school", answers_message_id: question.id)
        assert(requests.all? { |request| request.reload.open? })
        ReportCaseWorkflow.new(@report, nil).reply(body: "General update")
        assert(requests.all? { |request| request.reload.open? })
        other = Report.create!(organization: @organization, description: "Other report")
        other_question = other.case_messages.create!(actor: @admin, actor_role: "staff", kind: "question", body: "Other question")
        assert_no_difference "ReportMessage.count" do
          assert_raises(ActiveRecord::RecordNotFound) do
            ReportCaseWorkflow.new(@report, nil).reply(body: "Wrong question", answers_message_id: other_question.id)
          end
        end
      end

      test "invalid photo and signed blob identifiers cannot silently create a reply" do
        assert_no_difference "ReportMessage.count" do
          post @report.tokenized_status_path, params: { case_message: { body: "Photo", photo: "forged-signed-blob" } }
        end
        assert_response :redirect
        assert_includes flash[:alert], I18n.t("decidim.bih.report_evidence.invalid_photo")
        fake = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/report-evidence.txt"), "image/png")
        assert_no_difference "ReportMessage.count" do
          post @report.tokenized_status_path, params: { case_message: { body: "Photo", photo: fake } }
        end
      end

      test "recording service response preserves grouped references without sending or closing" do
        @report.update!(status: "proslijedjeno", forwarded_at: 2.days.ago, review_state: "validated")
        sign_in @admin
        clear_enqueued_jobs
        assert_no_difference ["ReportMessage.count", "ReportDispatch.count", "AccountNotification.count"] do
          decide("service_response", body: "Please provide photographs", external_reference: "A/26; B/26; C/26 — mapping unconfirmed")
        end
        assert_nil flash[:alert], flash[:alert]
        assert_equal "pending", @report.reload.review_state
        assert_equal "proslijedjeno", @report.status
        assert_equal "review", @report.deadline_kind
        assert_includes @report.internal_note, "A/26; B/26; C/26 — mapping unconfirmed"
        assert_nil @report.sistem48_reference
        assert_includes ReportWorkQueue.new(organization: @organization).scope("review"), @report
        assert_not_includes ReportWorkQueue.new(organization: @organization).scope("city"), @report
        assert_no_enqueued_jobs only: ReportCaseMessageJob
      end

      test "staff messages create one durable external intent with report template context" do
        message = ReportCaseWorkflow.new(@report, @admin).message(body: "Which intersection?", question: false)
        2.times { ReportCaseMessageJob.perform_now(message.id) }
        intent = message.reload.account_notification
        assert intent
        assert_equal @citizen, intent.user
        assert_equal "report_updates", intent.topic
        assert_includes intent.payload.fetch("text"), "Which intersection?"
        assert_includes intent.payload.fetch("text"), "https://#{@organization.host}#{@report.tokenized_status_path}"
        assert_not_includes intent.payload_ciphertext, @report.status_token
        get @report.tokenized_status_path
        assert_response :success
        assert_select "#report-private-conversation textarea[name=?]", "case_message[body]"
        assert_equal "mi_status_prijave_v1", intent.payload.fetch("template").fetch("name")
        assert_equal @report.reference, intent.payload.fetch("template").fetch("body").fetch("1")
        assert_equal 1, AccountNotification.where(id: intent.id).count
        assert_equal 1, Decidim::Notification.where(event_name: "decidim.events.bih.report_case_message", user: @citizen).count
        AccountNotifications.dispatch!(intent)
        assert_equal "skipped", intent.reload.status
        assert_equal "ineligible", intent.reason
      end

      test "citizen replies do not create external copies for staff" do
        message = @report.case_messages.create!(actor: @citizen, actor_role: "citizen", kind: "reply", body: "At the crossing")
        assert_no_difference "AccountNotification.count" do
          ReportCaseMessageJob.perform_now(message.id)
        end
        assert_nil message.reload.account_notification
      end

      test "existing external copy is preserved without duplicate bell or intent" do
        message = ReportCaseWorkflow.new(@report, @admin).message(body: "More details", question: false)
        ReportCaseMessageJob.perform_now(message.id)
        original = message.reload.account_notification
        assert_no_difference ["AccountNotification.count", "Decidim::Notification.count"] do
          ReportCaseMessageJob.perform_now(message.id)
        end
        assert_equal original, message.reload.account_notification
      end

      def review_attributes
        { confirm_review: "1", review_state: "validated", category: "saobracaj", severity: "visok", department: "Traffic",
          assigned_to_id: @admin.id, response_due_at: 2.days.from_now.iso8601, forwarding_recipient: "intake@example.org" }
      end

      def decide(action, values = {})
        post "/admin/bih/reports/#{@report.reference}/decision", params: {
          decision_action: action, input_version: ReportReviewVersion.digest(@report.reload),
          decision: values, confirm_decision: "1"
        }
      end

      def validate_case
        ReportCaseWorkflow.new(@report, @admin).update(review_attributes)
      end

      test "admin evidence is private and case review is tenant scoped" do
        sign_in @admin
        get "/admin/bih/reports/#{@report.reference}"
        assert_response :success
        assert_includes response.body, @report.description
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_equal Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY, response.headers["Referrer-Policy"]
        assert_select "#report-case-review"
        get "/biceriseno/prijave/#{@report.reference}"
        assert_not_includes response.body, @report.description
        assert_select "#report-case-conversation", count: 0
      end

      test "validation saves owner and chosen recipient but rejects outside addresses and owners" do
        validate_case
        assert_equal "validated", @report.reload.review_state
        assert_equal @admin, @report.assigned_to
        assert_raises(ReportCaseWorkflow::Invalid) do
          ReportCaseWorkflow.new(@report, @admin).update(review_attributes.merge(forwarding_recipient: "unapproved@example.org"))
        end
        assert_raises(ReportCaseWorkflow::Invalid) do
          ReportCaseWorkflow.new(@report, @admin).update(review_attributes.merge(assigned_to_id: @citizen.id))
        end
      end

      test "question and private reply create a tracked exchange and notify both sides once" do
        message = ReportCaseWorkflow.new(@report, @admin).message(body: "Which intersection?", question: true, response_due_at: 2.days.from_now.iso8601)
        assert_equal "needs_information", @report.reload.review_state
        ReportCaseMessageJob.perform_now(message.id)
        ReportCaseMessageJob.perform_now(message.id)
        assert_equal 1, Decidim::Notification.where(event_name: "decidim.events.bih.report_case_message", user: @citizen).count
        get "/biceriseno/prijave/#{@report.reference}"
        assert_not_includes response.body, "Which intersection?"
        get @report.tokenized_status_path
        assert_response :success
        assert_includes response.body, "Which intersection?"
        assert_not_includes response.body, @report.status_token
        assert message.reload.read_at
        post @report.tokenized_status_path, params: { case_message: { body: "Near the school" } }
        assert_response :redirect
        assert_equal "pending", @report.reload.review_state
        reply = @report.case_messages.last
        ReportCaseMessageJob.perform_now(reply.id)
        assert_equal 1, Decidim::Notification.where(event_name: "decidim.events.bih.report_case_message", user: @admin).count
      end

      test "wrong token and another tenant cannot write replies" do
        assert_no_difference("ReportMessage.count") do
          post "/biceriseno/prijave/#{@report.reference}/status/wrong", params: { case_message: { body: "forged" } }
        end
        assert_response :not_found
        other = create_organization
        host! other.host
        assert_no_difference("ReportMessage.count") do
          post @report.tokenized_status_path, params: { case_message: { body: "forged" } }
        end
        assert_response :not_found
      end

      test "nonstaff cannot review a case" do
        sign_in @citizen
        patch "/admin/bih/reports/#{@report.reference}/case", params: { case_details: review_attributes }
        assert_redirected_to "/admin/"
        assert_equal "pending", @report.reload.review_state
      end

      test "active report triagers can review and preview and expired roles lose access" do
        role = OperatorRole.create!(organization: @organization, user: @citizen, role: "report_triager", expires_at: 1.day.from_now)
        sign_in @citizen
        decide("review", review_attributes)
        assert_equal "validated", @report.reload.review_state
        decide("send", review_attributes)
        assert_response :success
        role.update!(expires_at: 1.day.ago)
        decide("send", review_attributes)
        assert_response :redirect
        assert_empty @report.dispatches
      end

      test "preview does not approve and send requires the matching reviewed draft" do
        sign_in @admin
        decide("send", review_attributes)
        assert_response :success
        assert_equal "pending", @report.reload.review_state
        assert_includes response.body, "intake@example.org"
        assert_includes response.body, @report.description
        token = css_select('input[name="preview_token"]').first["value"]
        post "/admin/bih/reports/#{@report.reference}/decision/confirm", params: { preview_token: token, confirm_decision: "1" }
        assert_equal 1, @report.dispatches.count
        assert_equal @admin, @report.dispatches.sole.approved_by
        assert_nil @report.reload.forwarded_at
        @report.update!(forwarding_note: "New recipient information")
        assert_no_difference("ReportDispatch.count") do
          post "/admin/bih/reports/#{@report.reference}/decision/confirm", params: { preview_token: token, confirm_decision: "1" }
        end
      end

      test "delivery uses reviewed content and recipient once" do
        validate_case
        dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        assert_difference("ActionMailer::Base.deliveries.count", 1) do
          2.times { ReportDispatchJob.perform_now(dispatch.id) }
        end
        assert_equal ["intake@example.org"], ActionMailer::Base.deliveries.last.to
        assert_equal "proslijedjeno", @report.reload.status
        assert_equal "Traffic", @report.department
      end

      test "status dropdown cannot simulate a send and resolution requires evidence" do
        sign_in @admin
        patch "/admin/bih/reports/#{@report.reference}/status", params: { status: "proslijedjeno" }
        assert_nil @report.reload.forwarded_at
        decide("resolve", reason: "Checked")
        assert_equal "primljeno", @report.reload.status
        decide("resolve", reason: "Checked", resolution_evidence: "Speed control installed and checked")
        assert_equal "rijeseno", @report.reload.status
        post @report.tokenized_status_path, params: { case_message: { body: "Still speeding today", feedback: "problem_persists" } }
        assert_equal "u_obradi", @report.reload.status
        assert_equal "problem_persists", @report.resident_feedback
      end

      test "external submission requires an explicit receipt and does not send mail" do
        validate_case
        assert_no_difference("ActionMailer::Base.deliveries.count") do
          ReportCaseWorkflow.new(@report, @admin).record_external(reference: "Office receipt 42")
        end
        assert_equal "Office receipt 42", @report.reload.external_submission_reference
        assert_equal 1, @report.events.where(event_type: "case_external_submission_recorded").count
      end

      test "changed cases invalidate queued sends and uncertain sends require reconciliation" do
        validate_case
        dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        @report.update!(forwarding_note: "Changed after preview")
        assert_no_difference("ActionMailer::Base.deliveries.count") { ReportDispatchJob.perform_now(dispatch.id) }
        assert_equal "cancelled", dispatch.reload.state
        dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        delivery = Object.new
        def delivery.deliver_now = raise(IOError, "Delivery outcome unknown")
        ReportDispatchMailer.stub(:delivery, delivery) { ReportDispatchJob.perform_now(dispatch.id) }
        assert_equal "unknown", dispatch.reload.state
        assert_equal "IOError", dispatch.error_class
        assert_nil @report.reload.forwarded_at
        assert_no_difference("ActionMailer::Base.deliveries.count") { ReportDispatchJob.perform_now(dispatch.id) }
        ReportDispatching.reconcile!(dispatch: dispatch, actor: @admin, accepted: false, evidence: "Provider confirms non-delivery")
        retry_dispatch = ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report))
        assert_difference("ActionMailer::Base.deliveries.count", 1) { ReportDispatchJob.perform_now(retry_dispatch.id) }
      end

      test "questions require a future deadline and rejected decisions require confirmation" do
        assert_no_difference("ReportMessage.count") do
          assert_raises(ReportCaseWorkflow::Invalid) do
            ReportCaseWorkflow.new(@report, @admin).message(body: "More detail?", question: true, response_due_at: 1.day.ago.iso8601)
          end
        end
        assert_raises(ReportCaseWorkflow::Invalid) do
          ReportCaseWorkflow.new(@report, @admin).update(review_attributes.merge(review_state: "rejected", status_note: "Outside scope", confirm_review: "0"))
        end
        assert_equal "primljeno", @report.reload.status
      end

      test "rejection records the reason and queues one citizen notification" do
        workflow = ReportCaseWorkflow.new(@report, @admin)
        attributes = review_attributes.merge(review_state: "rejected", status_note: "Outside this service's scope")
        assert_no_enqueued_jobs(only: ReportCaseMessageJob) { workflow.update(attributes) }
        assert_equal 1, Decidim::Notification.where(user: @citizen, event_name: "decidim.events.bih.report_status_update").count
        workflow.update(attributes)
        assert_equal "odbijeno", @report.reload.status
        assert_equal 1, @report.case_messages.count
        assert_equal attributes[:status_note], @report.case_messages.first.body
      end

      test "cross-tenant administrator cannot mutate another case" do
        other_admin = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
        assert_raises(Decidim::ActionForbidden) { ReportCaseWorkflow.new(@report, other_admin).update(review_attributes) }
      end

      test "operator messaging copies are linked to the conversation with delivery state" do
        attributes = { organization: @organization, sender: @admin, recipient: @citizen, subject: "Follow-up", body: "Please clarify the location", context: @report,
                       external_notification: { topic: "report_updates", text: "Please clarify the location", deduplication_key: "case-copy-test" } }
        2.times { OperatorMessenger.call(**attributes) }
        assert_equal 1, @report.case_messages.count
        message = @report.case_messages.first
        assert message.account_notification
        message.account_notification.update!(status: "accepted", channels: ["whatsapp"])
        get @report.tokenized_status_path
        assert_includes response.body, I18n.t("decidim.bih.report_case.external_states.accepted")
        assert_not_includes response.body, I18n.t("decidim.bih.report_case.external_states.delivered")
        message.account_notification.delete
        assert_nil message.reload.account_notification
        assert_includes message.body, "Please clarify the location"
      end

      test "private replies reject missing CSRF tokens" do
        previous = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        assert_no_difference("ReportMessage.count") do
          post @report.tokenized_status_path, params: { case_message: { body: "forged" } }
        end
        assert_response :unprocessable_entity
      ensure
        ActionController::Base.allow_forgery_protection = previous
      end

      test "overdue reminders are once per deadline" do
        @report.update!(response_due_at: 1.day.ago, assigned_to: @admin)
        2.times { ReportCaseReminderJob.perform_now }
        assert_equal 1, Decidim::Notification.where(event_name: "decidim.events.bih.report_overdue", user: @admin).count
        assert_equal 1, @report.events.where(event_type: "case_deadline_reminded").count
      end
    end
  end
end
