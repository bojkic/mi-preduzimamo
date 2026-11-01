# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReporterMailerTest < ActionMailer::TestCase
      setup do
        @organization = create_organization
        @report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa na putu",
          address: "Vidovdanska 1",
          reporter_email: "gradjanin@example.org",
          reporter_phone: "+387 65 123 456",
          status: "proslijedjeno"
        )
      end

      test "status_update sends to reporter_email" do
        mail = Decidim::Bih::ReporterMailer.status_update(
          @report,
          locale: "sr",
          host: @organization.host
        )

        assert_equal ["gradjanin@example.org"], mail.to
        assert_includes mail.subject, @report.reference
        assert_includes mail.subject, I18n.t("decidim.bih.reports.public_statuses.sent_to_service", locale: :sr)
      end

      test "body includes reference and status" do
        mail = Decidim::Bih::ReporterMailer.status_update(
          @report, locale: "sr", host: @organization.host
        )
        body = mail.body.to_s

        assert_includes body, @report.reference
        assert_includes body, I18n.t("decidim.bih.reports.public_statuses.sent_to_service", locale: :sr)
      end

      test "body includes the tokenized reporter status URL" do
        mail = Decidim::Bih::ReporterMailer.status_update(
          @report, locale: "sr", host: "mi.example.test"
        )
        body = mail.body.to_s

        assert_includes(
          body,
          "https://mi.example.test/biceriseno/prijave/#{@report.reference}/status/#{@report.status_token}"
        )
      end

      test "body does NOT contain reporter_phone (PII guard)" do
        mail = Decidim::Bih::ReporterMailer.status_update(
          @report, locale: "sr", host: @organization.host
        )
        body = mail.body.to_s

        assert_not_includes body, "+387 65 123 456"
        assert_not_includes body, "65 123 456"
      end

      test "optional status_note is included when present" do
        report_with_note = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa",
          reporter_email: "gradjanin@example.org",
          status: "odbijeno",
          status_note: "Nije u nadležnosti komunalne službe"
        )
        mail = Decidim::Bih::ReporterMailer.status_update(
          report_with_note, locale: "sr", host: @organization.host
        )
        body = mail.body.to_s

        assert_includes body, "Nije u nadležnosti komunalne službe"
      end

      test "nil reporter_email returns nil mail" do
        report_without_email = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Anonimna prijava",
          status: "proslijedjeno"
        )
        mail = Decidim::Bih::ReporterMailer.status_update(report_without_email)

        assert_nil mail.message.to_addresses
      end

      test "mail is deliverable" do
        assert_emails 1 do
          Decidim::Bih::ReporterMailer
            .status_update(@report, locale: "sr", host: @organization.host)
            .deliver_now
        end
      end
    end
  end
end
