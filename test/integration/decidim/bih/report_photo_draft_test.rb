# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportPhotoDraftTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper
      setup do
        @organization = create_organization
        @owner = SecureRandom.hex(32)
      end

      def draft
        upload = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/chat_photo.jpg"), "image/jpeg")
        ReportPhotoDraft.store!(organization: @organization, owner: @owner, upload:)
      end

      test "token requires the originating organization and session" do
        saved = draft
        assert_equal saved, ReportPhotoDraft.for_owner!(token: saved.token, organization: @organization, owner: @owner)
        ["", "another-session"].each do |owner|
          assert_raises(ReportPhotoDraft::Invalid) { ReportPhotoDraft.for_owner!(token: saved.token, organization: @organization, owner:) }
        end
        assert_raises(ReportPhotoDraft::Invalid) { ReportPhotoDraft.for_owner!(token: saved.token, organization: create_organization, owner: @owner) }
        assert_raises(ReportPhotoDraft::Invalid) { ReportPhotoDraft.for_owner!(token: "tampered", organization: @organization, owner: @owner) }
      end

      test "consumption preserves the photo and repeated submission returns the same report" do
        saved = draft
        report = saved.consume! { |photo| ReportIntake.new.call(organization: @organization, description: "Drugi problem", photo:) }
        assert report.photo.attached?
        assert_equal(report, saved.reload.consume! { flunk "must not create twice" })
        assert_equal saved.photo.blob.download, report.photo.blob.download
      end

      test "failed intake leaves a reusable draft and no report" do
        saved = draft
        assert_no_difference "Report.count" do
          assert_raises(ReportPhotoDraft::Invalid) do
            saved.consume! { Report.create!(organization: @organization, description: "Missing photo") }
          end
        end
        assert_nil saved.reload.consumed_report_id
        assert saved.photo.attached?
      end

      test "expiry purges the temporary copy and preserves a consumed report photo" do
        saved = draft
        temporary_blob = saved.photo.blob
        report = saved.consume! { |photo| ReportIntake.new.call(organization: @organization, description: "Drugi problem", photo:) }
        ReportPhotoDraftExpiryJob.perform_now(saved.id)
        assert ReportPhotoDraft.exists?(saved.id)

        travel 3.hours do
          perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { ReportPhotoDraftExpiryJob.perform_now(saved.id) }
          assert_not ReportPhotoDraft.exists?(saved.id)
          assert_not ActiveStorage::Blob.exists?(temporary_blob.id)
          assert report.reload.photo.attached?
          assert report.photo.blob.service.exist?(report.photo.blob.key)
          assert_nothing_raised { ReportPhotoDraftExpiryJob.perform_now(saved.id) }
        end
      end

      test "unprocessable uploads are rejected without an empty draft" do
        upload = Rack::Test::UploadedFile.new(StringIO.new("not an image"), "image/jpeg", original_filename: "bad.jpg")
        assert_no_difference "ReportPhotoDraft.count" do
          assert_raises(ReportPhotoDraft::Invalid) { ReportPhotoDraft.store!(organization: @organization, owner: @owner, upload:) }
        end
      end

      test "cleanup between token lookup and consumption gives an unavailable draft" do
        saved = draft
        ReportPhotoDraft.find(saved.id).destroy!
        assert_raises(ReportPhotoDraft::Invalid) { saved.consume! { flunk } }
      end

      test "expired drafts cannot be consumed and cleanup removes only expired drafts" do
        saved = draft
        token = saved.token
        travel 3.hours do
          fresh = draft
          assert_raises(ReportPhotoDraft::Invalid) { saved.consume! { flunk } }
          assert_raises(ReportPhotoDraft::Invalid) { ReportPhotoDraft.for_owner!(token:, organization: @organization, owner: @owner) }
          ReportPhotoDraft.cleanup!
          assert_not ReportPhotoDraft.exists?(saved.id)
          assert ReportPhotoDraft.exists?(fresh.id)
        end
      end
    end
  end
end
