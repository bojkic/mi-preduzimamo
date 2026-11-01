# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportProcessingJobTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        clear_enqueued_jobs
        clear_performed_jobs
        @organization = create_organization
      end

      teardown do
        clear_enqueued_jobs
        clear_performed_jobs
      end

      test "deleted reports are a no-op" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Za brisanje")
        report_id = report.id
        report.destroy!
        service = Object.new
        service.define_singleton_method(:call) { |**| raise "processing should not run" }

        Decidim::Bih::ReportProcessing.stub(:new, ->(*) { service }) do
          assert_nothing_raised do
            Decidim::Bih::ReportProcessingJob.perform_now(report_id)
          end
        end
      end

      test "transient forwarding failures are retried on the reports queue" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Privremeni kvar")
        failure = Decidim::Bih::ReportProcessing::ForwardingFailed.new(
          "SMTP timeout for reporter@example.org",
          code: "smtp_timeout"
        )
        service = Object.new
        service.define_singleton_method(:call) { |**| raise failure }

        Decidim::Bih::ReportProcessing.stub(:new, ->(*) { service }) do
          assert_difference -> { enqueued_jobs.size }, 1 do
            Decidim::Bih::ReportProcessingJob.perform_now(report.id, locale: "sr")
          end
        end

        retry_job = enqueued_jobs.last
        assert_equal Decidim::Bih::ReportProcessingJob, retry_job[:job]
        assert_equal "reports", retry_job[:queue]
        assert retry_job[:at], "expected retry to be scheduled with backoff"
      end

      test "processing passes legacy forwarding options to the policy-enforcing service" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Prijava za pregled")
        calls = []
        service = Object.new
        service.define_singleton_method(:call) { |report:, locale:, **options| calls << [report.id, locale, options] }

        Decidim::Bih::ReportProcessing.stub(:new, ->(*) { service }) do
          [true, false].each do |forward|
            Decidim::Bih::ReportProcessingJob.perform_now(report.id, locale: "bs", forward:)
          end
        end

        assert_equal [[report.id, "bs", { forward: true }], [report.id, "bs", { forward: false }]], calls
      end

      test "missing or nil forwarding decision delegates to the host policy" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Prijava bez odluke operatera")
        calls = []
        service = Object.new
        service.define_singleton_method(:call) { |report:, locale:, **options| calls << [report.id, locale, options] }

        Decidim::Bih::ReportProcessing.stub(:new, ->(*) { service }) do
          Decidim::Bih::ReportProcessingJob.perform_now(report.id)
          Decidim::Bih::ReportProcessingJob.perform_now(report.id, forward: nil)
        end

        assert_equal [[report.id, "sr", {}], [report.id, "sr", {}]], calls
      end
    end
  end
end
