# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Admin
      class RetentionSummaryTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @cutoff = Date.new(2023, 6, 17)
          @log_path = Rails.root.join("tmp/retention-summary-#{SecureRandom.hex(6)}.log")
        end

        teardown do
          FileUtils.rm_f(@log_path)
        end

        test "returns dry-run counts without changing private source records" do
          travel_to Time.zone.local(2026, 6, 17, 12, 0, 0) do
            old_report = report(
              created_at: 4.years.ago,
              reporter_email: "retention-private@example.org",
              reporter_phone: "+387 65 111 222",
              latitude: 44.756123,
              longitude: 19.214987
            )
            old_report.photo.attach(io: StringIO.new("fake"), filename: "old.png", content_type: "image/png")
            linkage = linkage(created_at: 4.years.ago, verified_at: 4.years.ago)
            availability = availability(updated_at: 4.years.ago)
            post = komsiluk_post(updated_at: 4.years.ago)
            feedback = feedback(updated_at: 4.years.ago)
            profile = partner_profile(created_at: 4.years.ago, attach_document: true)
            message = operator_message(sent_at: 4.years.ago)

            summary = RetentionSummary.new(organization: @organization, cutoff_on: @cutoff, log_path: @log_path).summary

            assert_equal "warn", summary[:status]
            assert_equal 10, summary[:total]
            assert_equal @cutoff.iso8601, summary[:cutoff_on]
            assert_row_count summary, "report_contacts", 1
            assert_row_count summary, "report_photos", 1
            assert_row_count summary, "report_coordinates", 1
            assert_row_count summary, "viber_linkages", 1
            assert_row_count summary, "volunteer_availabilities", 1
            assert_row_count summary, "komsiluk_post_bodies", 1
            assert_row_count summary, "chat_feedback", 1
            assert_row_count summary, "partner_private_contacts", 1
            assert_row_count summary, "partner_verification_documents", 1
            assert_row_count summary, "operator_message_bodies", 1
            assert_row_count summary, "login_tokens", 0

            assert_equal "retention-private@example.org", old_report.reload.reporter_email
            assert_equal "+387 65 111 222", old_report.reporter_phone
            assert old_report.photo.attached?
            assert Decidim::Bih::Viber::Linkage.exists?(linkage.id)
            assert_equal "Subota", availability.reload.availability
            assert_equal "Private komsiluk body", post.reload.body
            assert Decidim::Bih::ConciergeFeedback.exists?(feedback.id)
            assert_equal "Private contact", profile.reload.private_contact_name
            assert profile.verification_documents.attached?
            assert_equal "Private message body", message.reload.body
          end
        end

        test "parses the latest structured retention wrapper log without raw log output" do
          @log_path.write(<<~LOG)
            [2026-06-17T02:00:00Z] privacy-retention-sweep START cutoff=2023-06-17
            organization=1 host=example.org
            dry_run=false apply=true total=2
            report_contacts=1
            report_photos=0
            report_coordinates=1
            viber_linkages=0
            volunteer_availabilities=0
            komsiluk_post_bodies=0
            chat_feedback=0
            partner_private_contacts=0
            partner_verification_documents=0
            operator_message_bodies=0
            [2026-06-17T02:00:03Z] privacy-retention-sweep END
          LOG

          last_run = RetentionSummary.new(organization: @organization, cutoff_on: @cutoff, log_path: @log_path)
                                     .summary
                                     .fetch(:last_run)

          assert_equal "ok", last_run[:status]
          assert_equal "2023-06-17", last_run[:cutoff_on]
          assert_equal "true", last_run[:apply]
          assert_equal "2", last_run[:total]
          assert_equal 1, last_run[:counts]["report_contacts"]
          assert_equal "structured summary present", last_run[:detail]
          assert_not_includes last_run.values.join(" "), "example.org"
        end

        test "uses durable run history before wrapper log fallback" do
          @log_path.write(<<~LOG)
            [2026-06-17T02:00:00Z] privacy-retention-sweep START cutoff=2023-06-17
            dry_run=false apply=true total=9
            report_contacts=9
            [2026-06-17T02:00:01Z] privacy-retention-sweep END
          LOG
          create_retention_run(
            organization: create_organization,
            started_at: Time.zone.parse("2026-06-17T03:00:00Z"),
            counts: { report_contacts: 7 }
          )
          older = create_retention_run(
            started_at: Time.zone.parse("2026-06-17T03:00:00Z"),
            counts: { report_contacts: 1 }
          )
          newer = create_retention_run(
            dry_run: false,
            started_at: Time.zone.parse("2026-06-17T04:00:00Z"),
            counts: {
              report_contacts: 2,
              report_photos: 1,
              private_sentinel: "retention-private@example.org"
            }
          )

          summary = RetentionSummary.new(organization: @organization, cutoff_on: @cutoff, log_path: @log_path).summary
          last_run = summary.fetch(:last_run)
          history = summary.fetch(:run_history)

          assert_equal "ok", last_run[:status]
          assert_equal "false", last_run[:dry_run]
          assert_equal "true", last_run[:apply]
          assert_equal "3", last_run[:total]
          assert_equal "2023-06-17", last_run[:cutoff_on]
          assert_equal 2, last_run[:counts]["report_contacts"]
          assert_nil last_run[:counts]["private_sentinel"]
          assert_equal newer.started_at.utc.iso8601, history.first[:started_at]
          assert_equal older.started_at.utc.iso8601, history.second[:started_at]
          assert_equal 2, history.size
          assert_not_includes history.to_json, "retention-private@example.org"
          assert_not_includes history.to_json, "host=example.org"
        end

        test "marks an unfinished wrapper log as failing" do
          @log_path.write("[2026-06-17T02:00:00Z] privacy-retention-sweep START cutoff=2023-06-17\n")

          last_run = RetentionSummary.new(organization: @organization, cutoff_on: @cutoff, log_path: @log_path)
                                     .summary
                                     .fetch(:last_run)

          assert_equal "fail", last_run[:status]
          assert_equal "last run did not finish", last_run[:detail]
        end

        test "last run reports the latest live attempt instead of a newer dry run" do
          failed_live = Decidim::Bih::Privacy::RetentionRun.create!(
            organization: @organization,
            status: "fail",
            dry_run: false,
            source: "cron",
            started_at: 2.hours.ago,
            finished_at: 2.hours.ago + 1.second,
            counts: {},
            total: 0,
            cutoffs: {},
            error_class: "GovernanceApprovalRequired",
            error_message: "approval required"
          )
          create_retention_run(dry_run: true, started_at: 1.hour.ago)

          last_run = RetentionSummary.new(organization: @organization, cutoff_on: @cutoff, log_path: @log_path)
                                     .summary
                                     .fetch(:last_run)

          assert_equal failed_live.started_at.utc.iso8601, last_run[:started_at]
          assert_equal "fail", last_run[:status]
          assert_equal "true", last_run[:apply]
        end

        private

        def assert_row_count(summary, key, count)
          row = summary[:rows].find { |candidate| candidate[:key] == key }
          assert row, "missing retention row #{key}"
          assert_equal count, row[:count]
        end

        def create_retention_run(organization: @organization, dry_run: true, started_at: Time.current, counts: {})
          safe_counts = counts.transform_keys(&:to_s).transform_values(&:to_i)
          Decidim::Bih::Privacy::RetentionRun.create!(
            organization: organization,
            status: "ok",
            dry_run: dry_run,
            source: "test",
            started_at: started_at,
            finished_at: started_at + 3.seconds,
            counts: safe_counts,
            total: safe_counts.values.sum,
            cutoffs: {
              "report_contact_before" => @cutoff.to_time.utc.iso8601,
              "report_photo_before" => @cutoff.to_time.utc.iso8601
            }
          )
        end

        def report(**attrs)
          Decidim::Bih::Report.create!(
            {
              organization: @organization,
              description: "Private retention report body",
              status: "primljeno"
            }.merge(attrs)
          )
        end

        def linkage(**attrs)
          Decidim::Bih::Viber::Linkage.create!(
            {
              organization: @organization,
              viber_sender: "retention-#{SecureRandom.hex(3)}",
              phone: "+38765111222",
              verified_at: Time.current
            }.merge(attrs)
          )
        end

        def availability(updated_at:)
          record = Decidim::Bih::VolunteerAvailability.create!(
            organization: @organization,
            user: create(:user, organization: @organization),
            availability: "Subota",
            interests: "Parkovi"
          )
          record.update_columns(updated_at:) # rubocop:disable Rails/SkipsModelValidations
          record
        end

        def komsiluk_post(updated_at:)
          mz = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "retention-mz",
            name: { "sr" => "Retention MZ" }
          )
          komsiluk = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "retention-komsiluk",
            name: { "sr" => "Retention komsiluk" },
            parent: mz
          )
          post = Decidim::Bih::KomsilukPost.create!(
            organization: @organization,
            author: create(:user, :confirmed, organization: @organization),
            komsiluk: komsiluk,
            category: "general",
            title: "Private retention post",
            body: "Private komsiluk body",
            status: "closed"
          )
          post.update_columns(updated_at:) # rubocop:disable Rails/SkipsModelValidations
          post
        end

        def feedback(updated_at:)
          record = Decidim::Bih::ConciergeFeedback.create!(
            organization: @organization,
            reply_id: SecureRandom.uuid,
            session_digest: SecureRandom.hex(32),
            value: "not_helpful",
            locale: "sr",
            metadata: { "source" => "test", "outcome" => "success" }
          )
          record.update_columns(updated_at:) # rubocop:disable Rails/SkipsModelValidations
          record
        end

        def partner_profile(created_at:, attach_document: false)
          record = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Retention partner #{SecureRandom.hex(4)}",
            slug: "retention-partner-#{SecureRandom.hex(8)}",
            kind: "association",
            verification_status: "submitted",
            private_contact_name: "Private contact",
            private_contact_email: "private@example.test",
            private_contact_phone: "+38765000111"
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

        def operator_message(sent_at:)
          record = Decidim::Bih::OperatorMessage.create!(
            organization: @organization,
            sender: create(:user, :admin, :confirmed, organization: @organization),
            recipient: create(:user, :confirmed, organization: @organization),
            subject: "Follow-up",
            body: "Private message body",
            sent_at: sent_at
          )
          record.update_columns(created_at: sent_at, updated_at: sent_at) # rubocop:disable Rails/SkipsModelValidations
          record
        end
      end
    end
  end
end
