# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Privacy
      class RetentionSweepTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @other_organization = create_organization
          @cutoff = 90.days.ago
          @komsiluk = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "k-retention",
            name: { "sr" => "Retention" }
          )
        end

        test "dry-run returns counts without changing records" do
          old_report = report(created_at: 120.days.ago, reporter_email: "old@example.org",
                              reporter_phone: "065123456", latitude: 44.756123, longitude: 19.214987)
          old_report.photo.attach(io: StringIO.new("fake"), filename: "old.png", content_type: "image/png")
          linkage = linkage(created_at: 120.days.ago, verified_at: 120.days.ago)
          availability = availability(
            updated_at: 120.days.ago,
            availability: "Vikendom",
            interests: "Parkovi",
            area_scope: "komsiluk",
            local_area: @komsiluk,
            day_keys: %w(saturday sunday),
            month_keys: %w(july august),
            time_slot_keys: %w(day afternoon),
            interest_keys: %w(environment),
            skill_keys: %w(field_work),
            capability_keys: %w(outdoor_work)
          )
          feedback = feedback(updated_at: 120.days.ago)
          old_partner = partner_profile(created_at: 120.days.ago, attach_document: true)
          old_message = operator_message(sent_at: 120.days.ago, body: "Private follow-up text")

          result = RetentionSweep.call(
            organization: @organization,
            report_contact_before: @cutoff,
            report_photo_before: @cutoff,
            report_coordinates_before: @cutoff,
            viber_linkage_before: @cutoff,
            volunteer_availability_before: @cutoff,
            chat_feedback_before: @cutoff,
            partner_private_contact_before: @cutoff,
            partner_verification_document_before: @cutoff,
            operator_message_body_before: @cutoff
          )

          assert result.dry_run
          assert_equal 1, result.counts[:report_contacts]
          assert_equal 1, result.counts[:report_photos]
          assert_equal 1, result.counts[:report_coordinates]
          assert_equal 1, result.counts[:viber_linkages]
          assert_equal 1, result.counts[:volunteer_availabilities]
          assert_equal 1, result.counts[:chat_feedback]
          assert_equal 1, result.counts[:partner_private_contacts]
          assert_equal 1, result.counts[:partner_verification_documents]
          assert_equal 1, result.counts[:operator_message_bodies]
          assert_equal 9, result.total

          old_report.reload
          assert_equal "old@example.org", old_report.reporter_email
          assert_equal "065123456", old_report.reporter_phone
          assert old_report.photo.attached?
          assert_in_delta 44.756123, old_report.latitude.to_f, 0.000001
          assert Decidim::Bih::Viber::Linkage.exists?(linkage.id)
          assert_equal "Vikendom", availability.reload.availability
          assert_equal "komsiluk", availability.area_scope
          assert Decidim::Bih::ConciergeFeedback.exists?(feedback.id)
          assert_equal "Private contact", old_partner.reload.private_contact_name
          assert old_partner.verification_documents.attached?
          assert_equal "Private follow-up text", old_message.reload.body
        end

        test "enabled sweep anonymizes only old records in the selected organization" do
          old_report = report(created_at: 120.days.ago, reporter_email: "old@example.org",
                              reporter_phone: "065123456", latitude: 44.756123, longitude: 19.214987)
          old_report.photo.attach(io: StringIO.new("fake"), filename: "old.png", content_type: "image/png")
          recent_report = report(created_at: 10.days.ago, reporter_email: "recent@example.org",
                                 reporter_phone: "065000111", latitude: 44.7, longitude: 19.2)
          other_report = report(organization: @other_organization, created_at: 120.days.ago,
                                reporter_email: "other@example.org", reporter_phone: "065222333",
                                latitude: 44.8, longitude: 19.3)
          other_report.photo.attach(io: StringIO.new("fake"), filename: "other.png", content_type: "image/png")
          old_linkage = linkage(created_at: 120.days.ago, verified_at: 120.days.ago)
          recent_linkage = linkage(sender: "recent", phone: "065000111", created_at: 10.days.ago, verified_at: 10.days.ago)
          old_availability = availability(
            updated_at: 120.days.ago,
            availability: "Vikendom",
            interests: "Parkovi",
            area_scope: "komsiluk",
            local_area: @komsiluk,
            day_keys: %w(saturday sunday),
            month_keys: %w(july august),
            time_slot_keys: %w(day afternoon),
            interest_keys: %w(environment),
            skill_keys: %w(field_work),
            capability_keys: %w(outdoor_work)
          )
          recent_availability = availability(user: create(:user, organization: @organization),
                                             updated_at: 10.days.ago, availability: "Danas", interests: "Drvece")
          old_feedback = feedback(updated_at: 120.days.ago)
          recent_feedback = feedback(reply_id: SecureRandom.uuid, updated_at: 10.days.ago)
          other_feedback = feedback(organization: @other_organization, reply_id: SecureRandom.uuid, updated_at: 120.days.ago)
          old_partner = partner_profile(created_at: 120.days.ago, attach_document: true)
          recent_partner = partner_profile(created_at: 10.days.ago, attach_document: true)
          other_partner = partner_profile(organization: @other_organization, created_at: 120.days.ago,
                                          attach_document: true)
          old_message = operator_message(sent_at: 120.days.ago, body: "Private follow-up text")
          recent_message = operator_message(sent_at: 10.days.ago, body: "Recent body")
          other_message = operator_message(organization: @other_organization, sent_at: 120.days.ago,
                                           body: "Other body")

          result = RetentionSweep.call(
            organization: @organization,
            dry_run: false,
            report_contact_before: @cutoff,
            report_photo_before: @cutoff,
            report_coordinates_before: @cutoff,
            report_coordinate_precision: 2,
            viber_linkage_before: @cutoff,
            volunteer_availability_before: @cutoff,
            chat_feedback_before: @cutoff,
            partner_private_contact_before: @cutoff,
            partner_verification_document_before: @cutoff,
            operator_message_body_before: @cutoff
          )

          assert_equal 1, result.counts[:report_contacts]
          assert_equal 1, result.counts[:report_photos]
          assert_equal 1, result.counts[:report_coordinates]
          assert_equal 1, result.counts[:viber_linkages]
          assert_equal 1, result.counts[:volunteer_availabilities]
          assert_equal 1, result.counts[:chat_feedback]
          assert_equal 1, result.counts[:partner_private_contacts]
          assert_equal 1, result.counts[:partner_verification_documents]
          assert_equal 1, result.counts[:operator_message_bodies]

          old_report.reload
          assert_nil old_report.reporter_email
          assert_nil old_report.reporter_phone
          assert_not old_report.photo.attached?
          assert_in_delta 44.76, old_report.latitude.to_f, 0.001
          assert_in_delta 19.21, old_report.longitude.to_f, 0.001
          assert_equal "BR", old_report.reference.split("-").first
          assert_equal "primljeno", old_report.status

          recent_report.reload
          assert_equal "recent@example.org", recent_report.reporter_email
          assert_in_delta 44.7, recent_report.latitude.to_f, 0.001
          assert_equal "other@example.org", other_report.reload.reporter_email
          assert other_report.photo.attached?
          assert_not Decidim::Bih::Viber::Linkage.exists?(old_linkage.id)
          assert Decidim::Bih::Viber::Linkage.exists?(recent_linkage.id)
          assert_nil old_availability.reload.availability
          assert_nil old_availability.interests
          assert_equal "city", old_availability.area_scope
          assert_nil old_availability.local_area_id
          assert_empty old_availability.availability_windows
          assert_empty old_availability.day_keys
          assert_empty old_availability.month_keys
          assert_empty old_availability.time_slot_keys
          assert_empty old_availability.interest_keys
          assert_empty old_availability.skill_keys
          assert_empty old_availability.capability_keys
          assert_equal "Danas", recent_availability.reload.availability
          assert_not Decidim::Bih::ConciergeFeedback.exists?(old_feedback.id)
          assert Decidim::Bih::ConciergeFeedback.exists?(recent_feedback.id)
          assert Decidim::Bih::ConciergeFeedback.exists?(other_feedback.id)
          assert_nil old_partner.reload.private_contact_name
          assert_nil old_partner.private_contact_email
          assert_nil old_partner.private_contact_phone
          assert_not old_partner.verification_documents.attached?
          assert_equal "Private contact", recent_partner.reload.private_contact_name
          assert recent_partner.verification_documents.attached?
          assert_equal "Private contact", other_partner.reload.private_contact_name
          assert other_partner.verification_documents.attached?
          assert_equal RetentionSweep::OPERATOR_MESSAGE_BODY_REDACTION, old_message.reload.body
          assert_equal "Recent body", recent_message.reload.body
          assert_equal "Other body", other_message.reload.body
        end

        test "coordinate sweep can remove precise coordinates entirely" do
          old_report = report(created_at: 120.days.ago, latitude: 44.756123, longitude: 19.214987)

          RetentionSweep.call(
            organization: @organization,
            dry_run: false,
            report_coordinates_before: @cutoff
          )

          assert_nil old_report.reload.latitude
          assert_nil old_report.longitude
        end

        test "second enabled sweep is idempotent" do
          report(created_at: 120.days.ago, reporter_email: "old@example.org", reporter_phone: "065123456")
          first = RetentionSweep.call(organization: @organization, dry_run: false, report_contact_before: @cutoff)
          second = RetentionSweep.call(organization: @organization, dry_run: false, report_contact_before: @cutoff)

          assert_equal 1, first.counts[:report_contacts]
          assert_equal 0, second.counts[:report_contacts]
        end

        test "login token retention deletes only old terminal tokens in the selected organization" do
          old = login_token(organization: @organization, terminal_at: 120.days.ago, phone: "065111222")
          recent = login_token(organization: @organization, terminal_at: 10.days.ago, phone: "065333444")
          other = login_token(organization: @other_organization, terminal_at: 120.days.ago, phone: "065555666")

          preview = RetentionSweep.call(organization: @organization, login_token_before: @cutoff)
          assert_equal 1, preview.counts[:login_tokens]
          assert Decidim::Bih::LoginToken.exists?(old.id)

          applied = RetentionSweep.call(
            organization: @organization,
            dry_run: false,
            login_token_before: @cutoff
          )

          assert_equal 1, applied.counts[:login_tokens]
          assert_not Decidim::Bih::LoginToken.exists?(old.id)
          assert Decidim::Bih::LoginToken.exists?(recent.id)
          assert Decidim::Bih::LoginToken.exists?(other.id)
        end

        test "community review retention clears only old private reasons and preserves workflow state" do
          old_submission, old_need, old_offer = community_review_records(reviewed_at: 120.days.ago)
          recent_submission, recent_need, recent_offer = community_review_records(reviewed_at: 10.days.ago)
          foreign_submission, foreign_need, foreign_offer = community_review_records(
            organization: @other_organization,
            reviewed_at: 120.days.ago
          )

          preview = RetentionSweep.call(
            organization: @organization,
            community_review_reason_before: @cutoff
          )

          assert_equal 3, preview.counts[:community_review_reasons]
          assert_equal "Project reason", old_submission.reload.rejection_reason
          assert_equal "Need reason", old_need.reload.rejection_reason
          assert_equal "Offer reason", old_offer.reload.decline_reason

          applied = RetentionSweep.call(
            organization: @organization,
            dry_run: false,
            community_review_reason_before: @cutoff
          )

          assert_equal 3, applied.counts[:community_review_reasons]
          assert_nil old_submission.reload.rejection_reason
          assert_nil old_need.reload.rejection_reason
          assert_nil old_offer.reload.decline_reason
          assert_equal "rejected", old_submission.review_status
          assert_equal "rejected", old_need.review_status
          assert_equal "declined", old_offer.status
          assert_equal "Project reason", recent_submission.reload.rejection_reason
          assert_equal "Need reason", recent_need.reload.rejection_reason
          assert_equal "Offer reason", recent_offer.reload.decline_reason
          assert_equal "Project reason", foreign_submission.reload.rejection_reason
          assert_equal "Need reason", foreign_need.reload.rejection_reason
          assert_equal "Offer reason", foreign_offer.reload.decline_reason
        end

        test "missing live approval persists a failed live attempt" do
          report(created_at: 120.days.ago, reporter_email: "old@example.org")

          assert_raises(RetentionSweep::GovernanceApprovalRequired) do
            RetentionSweep.authorized_live_call(
              organization: @organization,
              report_contact_before: @cutoff,
              record_run: true,
              run_source: "test"
            )
          end

          run = Decidim::Bih::Privacy::RetentionRun.where(organization: @organization).recent.first
          assert_equal "fail", run.status
          assert run.live?
          assert_equal "test", run.source
          assert_equal 1, run.total
          assert_equal "Decidim::Bih::Privacy::RetentionSweep::GovernanceApprovalRequired", run.error_class
        end

        test "explicit run recording persists aggregate counts and cutoffs" do
          report(created_at: 120.days.ago, reporter_email: "old@example.org", reporter_phone: "065123456")

          result = RetentionSweep.call(
            organization: @organization,
            report_contact_before: @cutoff,
            record_run: true,
            run_source: "test"
          )

          run = result.run
          assert run.persisted?
          assert_equal "ok", run.status
          assert run.dry_run?
          assert_equal "test", run.source
          assert_equal 1, run.counts["report_contacts"]
          assert_equal 1, run.total
          assert_equal @cutoff.utc.iso8601, run.cutoffs["report_contact_before"]
          assert_not_includes run.attributes.to_json, "old@example.org"
          assert_not_includes run.attributes.to_json, "065123456"
        end

        test "rounded coordinates are counted only until they are rounded" do
          report(created_at: 120.days.ago, latitude: 44.756123, longitude: 19.214987)

          first = RetentionSweep.call(
            organization: @organization,
            dry_run: false,
            report_coordinates_before: @cutoff,
            report_coordinate_precision: 2
          )
          second = RetentionSweep.call(
            organization: @organization,
            dry_run: false,
            report_coordinates_before: @cutoff,
            report_coordinate_precision: 2
          )

          assert_equal 1, first.counts[:report_coordinates]
          assert_equal 0, second.counts[:report_coordinates]
        end

        private

        def report(organization: @organization, **attrs)
          Decidim::Bih::Report.create!(
            {
              organization: organization,
              description: "Stara prijava",
              status: "primljeno"
            }.merge(attrs)
          )
        end

        def linkage(organization: @organization, sender: "sender", phone: "065123456", **attrs)
          Decidim::Bih::Viber::Linkage.create!(
            {
              organization: organization,
              viber_sender: sender,
              phone: phone,
              verified_at: Time.current
            }.merge(attrs)
          )
        end

        def availability(organization: @organization, user: create(:user, organization: @organization), **attrs)
          record = Decidim::Bih::VolunteerAvailability.create!(
            {
              organization: organization,
              user: user,
              availability: "Subota",
              interests: "Ciscenje"
            }.merge(attrs.except(:updated_at))
          )
          record.update_columns(updated_at: attrs[:updated_at]) if attrs[:updated_at] # rubocop:disable Rails/SkipsModelValidations
          record
        end

        def feedback(organization: @organization, reply_id: SecureRandom.uuid, **attrs)
          record = Decidim::Bih::ConciergeFeedback.create!(
            {
              organization: organization,
              reply_id: reply_id,
              session_digest: SecureRandom.hex(32),
              value: "helpful",
              locale: "sr",
              metadata: { "source" => "test" }
            }.merge(attrs.except(:updated_at))
          )
          record.update_columns(updated_at: attrs[:updated_at]) if attrs[:updated_at] # rubocop:disable Rails/SkipsModelValidations
          record
        end

        def login_token(organization:, terminal_at:, phone:)
          user = create(:user, :confirmed, organization: organization)
          Decidim::Bih::LoginToken.create!(
            organization: organization,
            user: user,
            purpose: "verify",
            token_digest: Digest::SHA256.hexdigest(SecureRandom.hex(24)),
            phone: phone,
            expires_at: terminal_at,
            consumed_at: terminal_at
          )
        end

        def partner_profile(created_at:, organization: @organization, attach_document: false, **attrs)
          record = Decidim::Bih::PartnerProfile.create!(
            {
              organization: organization,
              display_name: "Partner #{SecureRandom.hex(4)}",
              slug: "partner-#{SecureRandom.hex(8)}",
              kind: "association",
              verification_status: "submitted",
              private_contact_name: "Private contact",
              private_contact_email: "private@example.test",
              private_contact_phone: "+38765000111"
            }.merge(attrs)
          )
          if attach_document
            record.verification_documents.attach(
              io: StringIO.new("%PDF-test"),
              filename: "verification.pdf",
              content_type: "application/pdf"
            )
          end
          record.update_columns(created_at: created_at, updated_at: created_at) # rubocop:disable Rails/SkipsModelValidations
          record
        end

        def operator_message(sent_at:, body:, organization: @organization)
          sender = create(:user, :admin, :confirmed, organization: organization)
          recipient = create(:user, :confirmed, organization: organization)
          record = Decidim::Bih::OperatorMessage.create!(
            organization: organization,
            sender: sender,
            recipient: recipient,
            subject: "Follow-up",
            body: body,
            sent_at: sent_at
          )
          record.update_columns(created_at: sent_at, updated_at: sent_at) # rubocop:disable Rails/SkipsModelValidations
          record
        end

        def community_review_records(reviewed_at:, organization: @organization)
          reviewer = create(:user, :admin, :confirmed, organization:)
          representative = create(:user, :confirmed, organization:)
          profile = partner_profile(
            organization:,
            created_at: reviewed_at,
            verification_status: "verified",
            verified_at: reviewed_at
          )
          profile.memberships.create!(
            organization:,
            user: representative,
            role: "owner",
            status: "accepted",
            accepted_at: reviewed_at
          )
          submission = Decidim::Bih::PartnerProjectSubmission.create!(
            organization:,
            partner_profile: profile,
            representative:,
            title: "Project for review",
            description: "Detailed project description",
            budget_amount: 5_000,
            review_status: "submitted",
            submitted_at: reviewed_at
          )
          need = Decidim::Bih::ContributionNeed.create!(
            organization:,
            partner_profile: profile,
            author: representative,
            need_type: "equipment",
            title: "Equipment need",
            description: "Detailed equipment need",
            quantity: 2,
            unit: "items",
            review_status: "approved",
            fulfillment_status: "open",
            reviewed_at: reviewed_at,
            published_at: reviewed_at
          )
          offer = Decidim::Bih::ContributionOffer.create!(
            organization:,
            contribution_need: need,
            contributor: representative,
            quantity: 1,
            status: "offered"
          )
          submission.update_columns( # rubocop:disable Rails/SkipsModelValidations
            review_status: "rejected",
            rejection_reason: "Project reason",
            reviewed_by_id: reviewer.id,
            reviewed_at: reviewed_at,
            updated_at: reviewed_at
          )
          need.update_columns( # rubocop:disable Rails/SkipsModelValidations
            review_status: "rejected",
            rejection_reason: "Need reason",
            reviewed_by_id: reviewer.id,
            reviewed_at: reviewed_at,
            updated_at: reviewed_at
          )
          offer.update_columns( # rubocop:disable Rails/SkipsModelValidations
            status: "declined",
            decline_reason: "Offer reason",
            declined_by_id: reviewer.id,
            declined_at: reviewed_at,
            updated_at: reviewed_at
          )

          [submission, need, offer]
        end
      end
    end
  end
end
