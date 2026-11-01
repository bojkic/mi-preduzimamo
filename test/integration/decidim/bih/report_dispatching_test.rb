# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportDispatchingTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, description: "Private problem description", address: "Test street",
                                 category: "rasvjeta", severity: "normalan", review_state: "validated", reviewed_at: Time.current,
                                 forwarding_recipient: "intake@example.org")
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        clear_enqueued_jobs
        ActionMailer::Base.deliveries.clear
      end

      def queue(**attributes)
        ReportDispatching.queue!(report: @report, actor: @admin, digest: ReportCaseWorkflow.digest(@report), **attributes)
      end

      test "approved photo bytes survive source removal and reach City as attachments" do
        @report.photo.attach(io: Rails.root.join("test/fixtures/files/report-evidence.png").open, filename: "original.png", content_type: "image/png")
        ReportMailbox::ReplyAddress.ensure!(report: @report, audience: "service", correspondents: [@report.forwarding_recipient])
        mail = ReportDispatching.preview(report: @report)
        assert_equal 1, mail.attachments.size
        assert_includes ReportEvidence.snapshot(mail)[:body], @report.description
        dispatch = queue(approved_mail_digest: ReportDispatching.mail_digest(mail))
        original = @report.photo.download
        @report.photo.detach
        # Render the approved snapshot independently of the live report. Delivery
        # itself still cancels when the case version changes before transport.
        delivered = ReportDispatchMailer.delivery(dispatch.id).message
        assert_equal original, delivered.attachments.first.body.decoded
        assert_includes delivered.text_part.body.decoded, @report.description
        assert_equal "image/png", delivered.attachments.first.mime_type
        assert_not_includes dispatch.snapshot_ciphertext, Base64.strict_encode64(original)
        ReportDispatchJob.perform_now(dispatch.id)
        assert_equal "cancelled", dispatch.reload.state
      end

      test "supplement attaches citizen photo and hashes bytes while followup omits photos" do
        upload = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/report-evidence.png"), "image/png")
        reply = ReportCaseWorkflow.new(@report, nil).reply(body: "Photograph for police", photo: upload)
        @report.update!(status: "proslijedjeno", forwarded_at: 2.days.ago, review_state: "validated")
        preview = ReportDecision.new(@report, @admin).preview(action: "supplement", values: { body: "Requested evidence" }, version: ReportReviewVersion.digest(@report))
        assert_equal 1, preview[:attachments].size
        assert_not preview[:attachments].first.has_key?(:content)
        mail = ReportDispatching.preview(report: @report, kind: "supplement", text: "Requested evidence")
        assert_includes ReportEvidence.snapshot(mail)[:body], "Requested evidence"
        before = ReportDispatching.mail_digest(mail)
        mail.attachments.first.body = "changed bytes"
        assert_not_equal before, ReportDispatching.mail_digest(mail)
        dispatch = queue(kind: "supplement", text: "Requested evidence")
        ReportDispatchJob.perform_now(dispatch.id)
        assert_equal "accepted", dispatch.reload.state
        assert_equal reply.photo.download, ActionMailer::Base.deliveries.last.attachments.first.body.decoded
        assert_empty ReportDispatching.preview(report: @report, kind: "followup", text: "Any update?").attachments
      end

      test "new accepted evidence dispatch renews a superseded City wait without clearing commitments" do
        @report.update!(status: "proslijedjeno", forwarded_at: 2.days.ago)
        old = ReportObligations.open!(@report, kind: "city_response", effect_key: "old-city-wait")
        ReportObligations.supersede!(old, by: @admin)
        commitment = ReportObligations.open!(@report, kind: "city_commitment", due_at: 30.days.from_now)
        dispatch = queue(kind: "supplement", text: "Requested evidence")
        2.times { ReportDispatchJob.perform_now(dispatch.id) }
        task = @report.obligations.find_by!(source: dispatch, kind: "city_response")
        assert task.open?
        assert_equal ReportObligations.deadline(:city_response, at: dispatch.reload.accepted_at), task.due_at
        assert commitment.reload.open?
        assert_equal 1, @report.obligations.where(source: dispatch).count
        assert_equal task.id, ReportObligations.next_action(@report.reload).id
        assert_equal task.due_at, ReportWorkQueue.due_at(@report)
      end

      test "delivery reconciliation resumes AI review for a reply that arrived while sending" do
        Setting.put(@organization, "report_review", "case_agent", "shadow")
        [true, false].each do |accepted|
          @report = Report.create!(organization: @organization, description: "Lamp", address: "Test street", category: "rasvjeta",
                                   review_state: "validated", reviewed_at: Time.current, forwarding_recipient: "intake@example.org")
          dispatch = queue
          dispatch.update!(state: "unknown")
          ReportCaseWorkflow.new(@report, nil).reply(body: "New details after approval")
          clear_enqueued_jobs
          assert_enqueued_with(job: ReportReviewProposalJob, args: [@report.id]) do
            ReportDispatching.reconcile!(dispatch:, actor: @admin, accepted:, evidence: "Checked transport outcome")
          end
          assert_equal "pending", @report.reload.review_state
          assert_equal accepted ? "accepted" : "not_sent", dispatch.reload.state
        end
      end

      test "approved snapshot is encrypted immutable and sent once" do
        dispatch = queue
        assert_equal "queued", dispatch.state
        assert_not_includes dispatch.snapshot_ciphertext, @report.description
        assert_includes dispatch.snapshot.fetch("body"), @report.description
        2.times { ReportDispatchJob.perform_now(dispatch.id) }
        assert_equal 1, ActionMailer::Base.deliveries.size
        assert_equal "accepted", dispatch.reload.state
        assert_equal "proslijedjeno", @report.reload.status
        assert @report.forwarded_at
        assert_equal dispatch.message_id, ActionMailer::Base.deliveries.last.message_id
        assert_equal "city", @report.deadline_kind
        dispatch.snapshot = { body: "changed" }
        assert_not dispatch.save
      end

      test "legacy forwarding cannot bypass an approved or uncertain dispatch" do
        dispatch = queue
        calls = 0
        forwarder = Object.new
        forwarder.define_singleton_method(:call) do |_payload|
          calls += 1
          true
        end
        %w(queued unknown).each do |state|
          dispatch.update!(state:)
          ReportProcessing.new(forwarder:).call(report: @report, forward: true, reviewed: true)
        end
        assert_equal 0, calls
        assert_nil @report.reload.forwarded_at
      end

      test "new reply cancels queued content without sending" do
        dispatch = queue
        ReportCaseWorkflow.new(@report, nil).reply(body: "Corrected location")
        ReportDispatchJob.perform_now(dispatch.id)
        assert_equal "cancelled", dispatch.reload.state
        assert_empty ActionMailer::Base.deliveries
        assert_nil @report.reload.forwarded_at
      end

      test "reply during initial delivery preserves its review task and deadline" do
        dispatch = queue
        reply = nil
        delivery = Object.new
        delivery.define_singleton_method(:deliver_now) do
          reply = ReportCaseWorkflow.new(Report.find(dispatch.report_id), nil).reply(body: "Additional location detail during delivery")
        end
        ReportDispatchMailer.stub(:delivery, delivery) { ReportDispatchJob.perform_now(dispatch.id) }

        assert_equal "accepted", dispatch.reload.state
        assert_equal "proslijedjeno", @report.reload.status
        assert_equal "pending", @report.review_state
        assert_equal "review", @report.deadline_kind
        assert_equal reply.created_at, @report.review_pending_since
        assert_in_delta (reply.created_at + ReportWorkQueue::REVIEW_DAYS.days).to_f, @report.response_due_at.to_f, 0.001
        assert_nil @report.last_reviewed_message_id
        assert_includes ReportWorkQueue.new(organization: @organization).scope("review"), @report
      end

      test "reply during supplement preserves original sending evidence and review deadline" do
        original_sent_at = 3.days.ago.change(usec: 0)
        @report.update!(status: "proslijedjeno", forwarded_at: original_sent_at)
        dispatch = queue(kind: "supplement", text: "Approved additional information")
        reply = nil
        delivery = Object.new
        delivery.define_singleton_method(:deliver_now) do
          reply = ReportCaseWorkflow.new(Report.find(dispatch.report_id), nil).reply(body: "One more detail")
        end
        ReportDispatchMailer.stub(:delivery, delivery) { ReportDispatchJob.perform_now(dispatch.id) }

        assert_equal "accepted", dispatch.reload.state
        assert_equal original_sent_at, @report.reload.forwarded_at
        assert_equal "pending", @report.review_state
        assert_equal "review", @report.deadline_kind
        assert_in_delta (reply.created_at + ReportWorkQueue::REVIEW_DAYS.days).to_f, @report.response_due_at.to_f, 0.001
      end

      test "uncertain delivery is not retried and blocks a second dispatch" do
        dispatch = queue
        calls = 0
        delivery = Object.new
        delivery.define_singleton_method(:deliver_now) do
          calls += 1
          raise IOError, "connection lost after remote acceptance"
        end
        ReportDispatchMailer.stub(:delivery, delivery) do
          2.times { ReportDispatchJob.perform_now(dispatch.id) }
        end
        assert_equal 1, calls
        assert_equal "unknown", dispatch.reload.state
        assert_nil @report.reload.forwarded_at
        assert_raises(ReportDispatching::Invalid) { queue }
        assert_equal 1, @report.dispatches.count
      end

      test "interrupted sending is recovered as unknown without a resend" do
        dispatch = queue
        dispatch.update!(state: "sending", started_at: 20.minutes.ago)
        clear_enqueued_jobs
        ReportDispatching.recover!
        assert_equal "unknown", dispatch.reload.state
        assert_no_enqueued_jobs only: ReportDispatchJob
        ReportDispatchJob.perform_now(dispatch.id)
        assert_empty ActionMailer::Base.deliveries
      end

      test "verified acceptance reconciles status without resending" do
        dispatch = queue
        dispatch.update!(state: "unknown")
        ReportDispatching.reconcile!(dispatch:, actor: @admin, accepted: true, evidence: "Provider confirmed acceptance")
        assert_equal "accepted", dispatch.reload.state
        assert_equal "proslijedjeno", @report.reload.status
        assert_empty ActionMailer::Base.deliveries
      end

      test "verified non-delivery permits a new explicitly approved attempt" do
        dispatch = queue
        dispatch.update!(state: "unknown")
        ReportDispatching.reconcile!(dispatch:, actor: @admin, accepted: false, evidence: "Provider confirms no acceptance")
        retry_dispatch = queue
        assert_not_equal dispatch.id, retry_dispatch.id
        assert_equal "not_sent", dispatch.reload.state
        ReportDispatchJob.perform_now(retry_dispatch.id)
        assert_equal 1, ActionMailer::Base.deliveries.size
      end

      test "changed routing cancels before sending" do
        dispatch = queue
        Setting.put(@organization, "sistem48_routing", "central_intake", "new@example.org")
        ReportDispatchJob.perform_now(dispatch.id)
        assert_equal "cancelled", dispatch.reload.state
        assert_empty ActionMailer::Base.deliveries
      end

      test "revoked authorization cancels before sending" do
        dispatch = queue
        @admin.update!(admin: false)
        ReportDispatchJob.perform_now(dispatch.id)
        assert_equal "cancelled", dispatch.reload.state
        assert_empty ActionMailer::Base.deliveries
      end

      test "supplement preserves the original forwarding evidence and sends only its reviewed text" do
        original_sent_at = 3.days.ago.change(usec: 0)
        @report.update!(status: "proslijedjeno", forwarded_at: original_sent_at)
        dispatch = queue(kind: "supplement", text: "The location is the northern end of the street.")
        assert_includes dispatch.snapshot.fetch("subject"), @report.reference
        assert_not_includes dispatch.snapshot.fetch("body"), @report.description
        ReportDispatchJob.perform_now(dispatch.id)
        assert_equal original_sent_at, @report.reload.forwarded_at
        assert_equal "accepted", dispatch.reload.state
      end

      test "cross tenant actor cannot approve or reconcile a dispatch" do
        outsider = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
        assert_raises(Decidim::ActionForbidden) do
          ReportDispatching.queue!(report: @report, actor: outsider, digest: ReportCaseWorkflow.digest(@report))
        end
        dispatch = queue
        dispatch.update!(state: "unknown")
        assert_raises(Decidim::ActionForbidden) do
          ReportDispatching.reconcile!(dispatch:, actor: outsider, accepted: true, evidence: "Untrusted")
        end
      end
    end
  end
end
