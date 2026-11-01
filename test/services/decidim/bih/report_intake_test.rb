# frozen_string_literal: true

require "test_helper"
require "mini_magick"
require "tempfile"

module Decidim
  module Bih
    class ReportIntakeTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
      end

      def processing_job_capturing(sink:)
        Object.new.tap do |stub|
          stub.define_singleton_method(:perform_later) do |report_id, locale:|
            sink << { report_id: report_id, locale: locale }
          end
        end
      end

      test "persists first and enqueues background processing" do
        enqueued = []

        report = Decidim::Bih::ReportIntake.new(
          processing_job: processing_job_capturing(sink: enqueued)
        ).call(
          organization: @organization,
          description: "Velika rupa na putu kod skole",
          locale: "bs"
        )

        assert report.persisted?
        assert_equal "primljeno", report.status
        assert_nil report.category
        assert_nil report.forwarded_at

        assert_equal [{ report_id: report.id, locale: "bs" }], enqueued
      end

      test "files a photo-less report when the photo is rejected (never drops the submission)" do
        oversized = {
          io: StringIO.new("x" * (Decidim::Bih::Report::PHOTO_MAX_BYTES + 1024)),
          filename: "big.png", content_type: "image/png"
        }
        enqueued = []

        report = Decidim::Bih::ReportIntake.new(
          processing_job: processing_job_capturing(sink: enqueued)
        ).call(organization: @organization, description: "Prijava sa prevelikom slikom", photo: oversized)

        assert report.persisted?, "the report must be filed even when the photo is rejected"
        assert_not report.photo.attached?, "the oversized photo must be dropped, not crash the report"
        assert_equal [{ report_id: report.id, locale: "sr" }], enqueued
      end

      test "strips image metadata before attaching a report photo" do
        photo = image_with_comment("SecretCamera")
        enqueued = []

        report = Decidim::Bih::ReportIntake.new(
          processing_job: processing_job_capturing(sink: enqueued)
        ).call(
          organization: @organization,
          description: "Prijava sa slikom",
          photo: { io: File.open(photo.path, "rb"), filename: "photo.jpg", content_type: "image/jpeg" }
        )

        assert report.photo.attached?
        assert_equal "", image_comment(report.photo.download)
      ensure
        photo&.close!
      end

      private

      def image_with_comment(comment)
        file = Tempfile.new(["report-photo", ".jpg"], binmode: true)
        MiniMagick::Tool::Convert.new do |convert|
          convert.size "2x2"
          convert.xc "red"
          convert.set "comment", comment
          convert << file.path
        end
        file
      end

      def image_comment(bytes)
        file = Tempfile.new(["stored-photo", ".jpg"], binmode: true)
        file.write(bytes)
        file.close
        MiniMagick::Image.open(file.path)["%c"]
      ensure
        file&.close!
      end
    end
  end
end
