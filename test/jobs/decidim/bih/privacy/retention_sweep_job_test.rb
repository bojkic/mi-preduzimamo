# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Privacy
      class RetentionSweepJobTest < ActiveJob::TestCase
        test "defaults to dry-run so enqueued retention checks do not mutate data" do
          organization = create_organization
          report = Decidim::Bih::Report.create!(
            organization: organization,
            description: "Stara prijava",
            reporter_email: "old@example.org",
            created_at: 120.days.ago
          )

          RetentionSweepJob.perform_now(
            organization_id: organization.id,
            report_contact_before: 90.days.ago.iso8601
          )

          assert_equal "old@example.org", report.reload.reporter_email
          run = Decidim::Bih::Privacy::RetentionRun.where(organization: organization).recent.first
          assert_equal "ok", run.status
          assert run.dry_run?
          assert_equal "job", run.source
          assert_equal 1, run.counts["report_contacts"]
        end

        test "missing organization is a no-op" do
          assert_nothing_raised do
            RetentionSweepJob.perform_now(organization_id: -1, report_contact_before: 90.days.ago.iso8601)
          end
        end

        test "komsiluk_post_body_before wired through job nullifies closed post body past cutoff" do
          organization = create_organization
          cutoff = 90.days.ago
          mz = Decidim::Bih::LocalArea.create!(
            organization: organization, kind: "mz", slug: "mz-job-ret",
            name: { "sr" => "Test MZ" }
          )
          komsiluk = Decidim::Bih::LocalArea.create!(
            organization: organization, kind: "komsiluk", slug: "komsiluk-job-ret",
            name: { "sr" => "Test K" }, parent: mz
          )
          author = FactoryBot.create(:user, :confirmed, organization: organization)
          old_post = Decidim::Bih::KomsilukPost.create!(
            organization: organization, author: author, komsiluk: komsiluk,
            category: "general", title: "Old post", body: "Sensitive body",
            status: "closed"
          )
          old_post.update_columns(updated_at: 100.days.ago) # rubocop:disable Rails/SkipsModelValidations
          approve_live_retention!(organization:, cutoffs: { komsiluk_post_body_before: cutoff.iso8601 }, total: 1)

          RetentionSweepJob.perform_now(
            organization_id: organization.id,
            dry_run: false,
            komsiluk_post_body_before: cutoff.iso8601
          )

          assert_nil old_post.reload.body
        end

        test "chat_feedback_before wired through job deletes old bot feedback rows" do
          organization = create_organization
          cutoff = 90.days.ago
          feedback = Decidim::Bih::ConciergeFeedback.create!(
            organization: organization,
            reply_id: SecureRandom.uuid,
            session_digest: "session-digest",
            value: "helpful",
            locale: "bs",
            metadata: { "source" => "web_chat", "outcome" => "success" }
          )
          feedback.update_columns(updated_at: 100.days.ago) # rubocop:disable Rails/SkipsModelValidations
          approve_live_retention!(organization:, cutoffs: { chat_feedback_before: cutoff.iso8601 }, total: 1)

          RetentionSweepJob.perform_now(
            organization_id: organization.id,
            dry_run: false,
            chat_feedback_before: cutoff.iso8601
          )

          assert_not Decidim::Bih::ConciergeFeedback.exists?(feedback.id)
          run = Decidim::Bih::Privacy::RetentionRun.where(organization: organization).recent.first
          assert_equal 1, run.counts["chat_feedback"]
          assert_equal "job", run.source
        end

        test "partner and operator retention cutoffs are wired through job" do
          organization = create_organization
          cutoff = 90.days.ago
          sender = FactoryBot.create(:user, :admin, :confirmed, organization: organization)
          recipient = FactoryBot.create(:user, :confirmed, organization: organization)
          profile = Decidim::Bih::PartnerProfile.create!(
            organization: organization,
            display_name: "Partner retention",
            slug: "partner-retention-#{SecureRandom.hex(4)}",
            kind: "association",
            verification_status: "submitted",
            private_contact_name: "Private contact",
            private_contact_email: "private@example.test",
            private_contact_phone: "+38765000111"
          )
          profile.verification_documents.attach(
            io: StringIO.new("%PDF-test"),
            filename: "verification.pdf",
            content_type: "application/pdf"
          )
          profile.update_columns(created_at: 100.days.ago, updated_at: 100.days.ago) # rubocop:disable Rails/SkipsModelValidations
          message = Decidim::Bih::OperatorMessage.create!(
            organization: organization,
            sender: sender,
            recipient: recipient,
            subject: "Follow-up",
            body: "Private body",
            sent_at: 100.days.ago
          )
          approve_live_retention!(organization:, cutoffs: { partner_private_contact_before: cutoff.iso8601, partner_verification_document_before: cutoff.iso8601, operator_message_body_before: cutoff.iso8601 }, total: 3)

          RetentionSweepJob.perform_now(
            organization_id: organization.id,
            dry_run: false,
            partner_private_contact_before: cutoff.iso8601,
            partner_verification_document_before: cutoff.iso8601,
            operator_message_body_before: cutoff.iso8601
          )

          assert_nil profile.reload.private_contact_name
          assert_not profile.verification_documents.attached?
          assert_equal RetentionSweep::OPERATOR_MESSAGE_BODY_REDACTION, message.reload.body
          run = Decidim::Bih::Privacy::RetentionRun.where(organization: organization).recent.first
          assert_equal 1, run.counts["partner_private_contacts"]
          assert_equal 1, run.counts["partner_verification_documents"]
          assert_equal 1, run.counts["operator_message_bodies"]
        end

        private

        def approve_live_retention!(organization:, cutoffs:, total:)
          approver = FactoryBot.create(:user, :admin, :confirmed, organization:)
          Decidim::Bih::GovernanceApproval.create!(
            organization:,
            user: approver,
            governance_kind: "privacy_retention",
            approval_role: "admin",
            status: "approved",
            scope_key: RetentionSweep.scope_key(**cutoffs),
            evidence_summary: "Dry-run aggregate reviewed for live retention test.",
            metadata: { "dry_run_status" => "warn", "dry_run_total" => total }
          )
        end
      end
    end
  end
end
