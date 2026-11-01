# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Decidim
  module Bih
    module Sistem48
      # Tests for the ArchiveSync service that mirrors the city's Sistem 48
      # resolution status onto our reports, closing the civic feedback loop.
      class ArchiveSyncTest < ActiveSupport::TestCase
        ARCHIVE_URL = "https://community.example.invalid/archive/?tip_zahteva=-1&zahtevi_status=-1&datum=0"

        def fixture_html
          file_fixture("synthetic/sistem48_archive.html").read
        end

        setup do
          @archive_env = ENV["SISTEM48_ARCHIVE_URL"]
          @archive_config = Decidim::Bih.sistem48_archive_url
          ENV.delete("SISTEM48_ARCHIVE_URL")
          Decidim::Bih.sistem48_archive_url = ARCHIVE_URL
          config = WebMock::Config.instance
          @webmock_config = %i(allow_net_connect allow_localhost allow net_http_connect_on_start).to_h { |key| [key, config.public_send(key)] }
          WebMock.disable_net_connect!(allow_localhost: true)
          @organization = create_organization
        end

        teardown do
          WebMock.reset!
          @webmock_config.each { |key, prior| WebMock::Config.instance.public_send("#{key}=", prior) }
          Decidim::Bih.sistem48_archive_url = @archive_config
          @archive_env.nil? ? ENV.delete("SISTEM48_ARCHIVE_URL") : ENV["SISTEM48_ARCHIVE_URL"] = @archive_env
        end

        def stub_archive
          stub_request(:get, ARCHIVE_URL).to_return(
            status: 200, body: fixture_html, headers: { "Content-Type" => "text/html" }
          )
        end

        # Helper: a non-terminal report carrying a Sistem 48 reference.
        def report_with(reference:, status: "proslijedjeno", **attrs)
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "IZMIŠLJENI TESTNI PREDMET",
            status: status,
            sistem48_reference: reference,
            **attrs
          )
        end

        test "matches a non-terminal report by digits-only reference and stores the city status" do
          stub_archive
          # Fixture carries 2040900002 => "Obrada u toku". The stored reference is
          # the '#'-prefixed form to prove digits-only matching.
          report = report_with(reference: "# 2040900002")

          Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call

          report.reload
          assert_equal "Obrada u toku", report.sistem48_status
          assert_not_nil report.sistem48_synced_at
          event = report.events.where(event_type: "sistem48_status_synced").last
          assert_not_nil event
          assert_equal "background", event.source
          assert_equal "Obrada u toku", event.metadata["sistem48_status"]
        end

        test "unchanged polling does not renew followup and changed city data preserves citizen review" do
          stub_archive
          report = report_with(reference: "2040900002", review_state: "validated", forwarded_at: 40.days.ago)
          Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call
          deadline = report.reload.response_due_at
          assert deadline
          travel 1.day do
            Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call
            assert_equal deadline, report.reload.response_due_at
            assert_equal false, report.events.where(event_type: "sistem48_status_synced").last.metadata["changed"]
            Decidim::Bih::ReportCaseWorkflow.new(report, nil).reply(body: "New location detail")
            review_due = report.reload.response_due_at
            stub_request(:get, ARCHIVE_URL).to_return(status: 200, body: fixture_html.gsub("Obrada u toku", "Dodatna obrada"), headers: { "Content-Type" => "text/html" })
            Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call
            assert_equal "Dodatna obrada", report.reload.sistem48_status
            assert_equal review_due, report.response_due_at
            assert_equal "review", report.deadline_kind
          end
        end

        test "fetches the archive exactly once regardless of report count (no N+1)" do
          stub = stub_archive
          report_with(reference: "2040900002")
          report_with(reference: "2040900003")
          report_with(reference: "2040900004")

          Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call

          assert_requested stub, times: 1
        end

        test "skips terminal reports (rijeseno / odbijeno)" do
          stub_archive
          resolved = report_with(reference: "2040900001", status: "rijeseno")
          rejected = report_with(reference: "2040900004", status: "odbijeno")

          Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call

          assert_nil resolved.reload.sistem48_status
          assert_nil rejected.reload.sistem48_status
        end

        test "ignores reports without a sistem48_reference" do
          stub_archive
          report = report_with(reference: nil)

          Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call

          assert_nil report.reload.sistem48_status
        end

        test "leaves a report untouched when its reference is absent from the archive" do
          stub_archive
          report = report_with(reference: "9999999999")

          Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call

          assert_nil report.reload.sistem48_status
          assert_nil report.reload.sistem48_synced_at
          assert_equal 0, report.events.where(event_type: "sistem48_status_synced").count
        end

        test "is org-scoped and does not touch reports of other organizations" do
          stub_archive
          other_org = create_organization(host: "other-#{SecureRandom.hex(4)}.lvh.me")
          other_report = Decidim::Bih::Report.create!(
            organization: other_org,
            description: "IZMIŠLJENI PREDMET DRUGE ZAJEDNICE",
            status: "proslijedjeno",
            sistem48_reference: "2040900002"
          )

          Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call

          assert_nil other_report.reload.sistem48_status
        end

        test "is a no-op (no error, no request) when the scraper is unconfigured" do
          report = report_with(reference: "2040900002")

          # An unconfigured scraper has a blank archive URL.
          unconfigured = ArchiveScraper.new(archive_url: "")
          assert_not unconfigured.configured?

          assert_nothing_raised do
            Decidim::Bih::Sistem48::ArchiveSync.new(@organization, scraper: unconfigured).call
          end

          assert_nil report.reload.sistem48_status
          # No HTTP request should have been issued at all.
          assert_not_requested :get, ARCHIVE_URL
        end

        test "rescues a scrape failure: logs and returns without raising or mutating" do
          stub_request(:get, ARCHIVE_URL).to_return(status: 503, body: "")
          report = report_with(reference: "2040900002")

          assert_nothing_raised do
            Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call
          end

          assert_nil report.reload.sistem48_status
          assert_nil report.reload.sistem48_synced_at
        end

        test "returns the number of reports updated" do
          stub_archive
          report_with(reference: "2040900002") # in archive
          report_with(reference: "9999999999") # not in archive

          updated = Decidim::Bih::Sistem48::ArchiveSync.new(@organization).call

          assert_equal 1, updated
        end
      end
    end
  end
end
