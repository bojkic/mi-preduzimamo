# frozen_string_literal: true

require "test_helper"
require "rake"
require "webmock/minitest"

# Load all decidim_bih rake tasks for this test session. Guarded against
# double-loading (Rake enhances rather than replaces task actions).
Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:reports:sistem48_sync")

module Decidim
  module Bih
    # Tests for the `decidim_bih:reports:sistem48_sync` rake task that mirrors
    # the city's Sistem 48 status onto a single host's reports.
    class Sistem48SyncTaskTest < ActiveSupport::TestCase
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
        Rake::Task["decidim_bih:reports:sistem48_sync"].reenable if
          Rake::Task.task_defined?("decidim_bih:reports:sistem48_sync")
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

      test "syncs the city status onto the named host's reports" do
        stub_archive
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test",
          status: "proslijedjeno",
          sistem48_reference: "2040900002"
        )

        Rake::Task["decidim_bih:reports:sistem48_sync"].reenable
        Rake::Task["decidim_bih:reports:sistem48_sync"].invoke(@organization.host)

        assert_equal "Obrada u toku", report.reload.sistem48_status
      end

      test "is a no-op when the host is unknown" do
        stub = stub_archive

        assert_nothing_raised do
          Rake::Task["decidim_bih:reports:sistem48_sync"].reenable
          Rake::Task["decidim_bih:reports:sistem48_sync"].invoke("nope.example.test")
        end

        assert_not_requested stub
      end
    end
  end
end
