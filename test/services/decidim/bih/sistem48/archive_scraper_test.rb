# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Decidim
  module Bih
    module Sistem48
      class ArchiveScraperTest < ActiveSupport::TestCase
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

        test "fetch_archive parses every report entry from the authored archive structure" do
          stub_archive
          entries = ArchiveScraper.new.fetch_archive

          assert_equal 4, entries.size
          entries.each do |entry|
            assert entry[:reference].present?
            assert entry[:category].present?
            assert entry[:status].present?
            assert entry[:date].present?
          end
        end

        test "fetch_archive maps the header, footer and dates of an entry" do
          stub_archive
          entry = ArchiveScraper.new.fetch_archive.first

          assert_equal "2040900001", entry[:reference]
          assert_equal "Prijava riješena", entry[:status]
          assert_equal "Izmišljena kategorija - Izmišljena služba", entry[:category]
          assert_equal "14-09-2040 u 15:15", entry[:date]
        end

        test "fetch_archive normalizes windows-1250 archive HTML to UTF-8" do
          body = fixture_html.encode("Windows-1250").b
          stub_request(:get, ARCHIVE_URL).to_return(
            status: 200,
            body: body,
            headers: { "Content-Type" => "text/html; charset=windows-1250" }
          )

          entry = ArchiveScraper.new.fetch_archive.first

          assert_equal "Prijava riješena", entry[:status]
          assert_equal "Izmišljena kategorija - Izmišljena služba", entry[:category]
        end

        test "isolated legacy bytes do not corrupt valid UTF-8 status labels" do
          # An authored mixed-encoding defect: one unrelated legacy byte
          # must not trigger whole-document transcoding of valid UTF-8.
          body = fixture_html.b.sub("</body>".b, "<p>".b + [0x9a].pack("C") + "</p></body>".b)
          stub_request(:get, ARCHIVE_URL).to_return(status: 200, body:, headers: { "Content-Type" => "text/html; charset=UTF-8" })
          entries = ArchiveScraper.new.fetch_archive
          assert_equal "Prijava riješena", entries.first[:status]
          assert_includes entries.map { |entry| entry[:status] }, "Nenadležni za prijavu"
        end

        test "already corrupted status labels fail closed instead of entering a sync" do
          html = fixture_html.sub("Prijava riješena", "Prijava rijeĹˇena")
          scraper = ArchiveScraper.new
          assert_raises(ScrapeError) { scraper.parse(html) }
        end

        test "fetch_archive retries one transient transport failure" do
          stub = stub_request(:get, ARCHIVE_URL)
                 .to_timeout
                 .then
                 .to_return(status: 200, body: fixture_html, headers: { "Content-Type" => "text/html" })

          entries = ArchiveScraper.new(retries: 1).fetch_archive

          assert_equal 4, entries.size
          assert_requested stub, times: 2
        end

        test "fetch_archive reads the warning and danger statuses too" do
          stub_archive
          statuses = ArchiveScraper.new.fetch_archive.map { |e| e[:status] }

          assert_includes statuses, "Obrada u toku"
          assert_includes statuses, "Nenadležni za prijavu"
        end

        test "status_for finds the matching entry by reference" do
          stub_archive
          entry = ArchiveScraper.new.status_for(reference: "2040900002")

          assert_not_nil entry
          assert_equal "Obrada u toku", entry[:status]
        end

        test "status_for tolerates the '#'-prefixed reference form" do
          stub_archive
          entry = ArchiveScraper.new.status_for(reference: "# 2040900003")

          assert_not_nil entry
          assert_equal "Nenadležni za prijavu", entry[:status]
        end

        test "status_for returns nil for an unknown reference" do
          stub_archive
          assert_nil ArchiveScraper.new.status_for(reference: "9999999999")
        end

        test "an authored fifteen-entry archive with a truncated excerpt preserves decoded statuses" do
          # Independently reproduce byte-length truncation in invented text.
          body = file_fixture("synthetic/sistem48_archive_fifteen.html").binread.sub("AUTHORED_FRAGMENT".b, "izmišljeni fragment ".b + [0xC5].pack("C"))
          assert_not body.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          entries = ArchiveScraper.new.parse(body)

          assert_equal 15, entries.size
          assert_equal({ "Prijava riješena" => 13, "Obrada u toku" => 2 }, entries.map { |entry| entry[:status] }.tally)
          entries.each do |entry|
            assert_match(/\A\d{10}\z/, entry[:reference])
            assert_match(/\A\d{2}-\d{2}-2040 u \d{2}:\d{2}\z/, entry[:date])
            assert entry[:category].present?
          end
        end

        test "a non-success HTTP response raises ScrapeError" do
          stub_request(:get, ARCHIVE_URL).to_return(status: 503, body: "")
          # ScrapeError is defined in archive_scraper.rb; touch the class first so
          # the constant exists whatever order the seed picks.
          scraper = ArchiveScraper.new
          assert_raises(Decidim::Bih::Sistem48::ScrapeError) { scraper.fetch_archive }
        end
      end
    end
  end
end
