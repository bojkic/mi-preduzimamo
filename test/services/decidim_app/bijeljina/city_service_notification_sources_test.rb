# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceNotificationSourcesTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry

      setup do
        travel_to Time.utc(2040, 9, 29, 8)
      end

      teardown do
        travel_back
      end
      FIXTURES = Rails.root.join("test/fixtures/files/synthetic/notification_sources")

      test "City Hall article excludes page widgets and remains one complete article" do
        url = "https://city.example.invalid/notices/authored-call"
        articles = CityServiceArticle.extract(html: fixture("cityart.html"), source_url: url)

        assert_equal 1, articles.size
        assert articles.sole.complete
        assert_includes articles.sole.html, "entry__article"
        assert_not_includes articles.sole.html, "editors-picks-section"
        assert_not_includes articles.sole.html, "related-posts-section"
        assert_not CityServiceArticle.extract(html: "<article><p>Ovaj tekst je prekinut ...</p></article>", source_url: url).sole.complete
      end

      test "water listing with ten articles is complete and a cap still marks unseen links partial" do
        source = CityServiceSources.fetch("water_service")
        requested = []
        fetcher = lambda do |url:, **|
          requested << url
          { http_status: 200, final_url: url, content_type: "text/html",
            body: "<article><p>Potpuna objava o vodosnabdijevanju.</p></article>" }
        end
        listing = fixture("vodovod.html")
        result = CityServiceArticleFetcher.new(source:, fetcher:).call(html: listing)

        assert_equal :ok, result.status
        assert_equal 10, requested.size
        assert_equal 10, result.articles.size

        limited = CityServiceArticleFetcher.new(source:, fetcher:, max_items: 8).call(html: listing)
        assert_equal :unreviewed, limited.status
        assert_equal :article_selection_truncated, limited.error_code
      end

      test "authored bulky-waste listing verifies no current campaign without fetching old April teaser" do
        source = CityServiceSources.fetch("bulky_waste")
        requested = []
        fetcher = ->(url:, **) { requested << url; raise "unexpected old campaign fetch" }
        result = CityServiceArticleFetcher.new(source:, fetcher:).call(
          html: fixture("kom.html"), fetched_at: Time.utc(2040, 9, 29)
        )

        assert_equal :ok, result.status
        assert_empty result.articles
        assert_empty requested
      end

      test "authored current bulky-waste campaign follows full article and retains complete window" do
        source = CityServiceSources.fetch("bulky_waste")
        url = "https://bulky-waste.example.invalid/info-centar/aktuelnosti/authored-current"
        listing = "<div class='categoryBlog'><div class='categoryTitle'><h2><a href='#{url}'>" \
                  "ОдВозење кабастог отпада у октобру 2040.</a></h2></div></div>"
        detail = "<div class='item-page'><h1>Одвожење кабастог отпада у октобру 2040.</h1>" \
                 "<p>ИЗМИШЉЕНИ ТЕСТ — У Бијељини прикупљање кабастог отпада 16.10.2040. од 10:00 до 12:30.</p></div>"
        fetcher = ->(url:, **) { { http_status: 200, final_url: url, content_type: "text/html", body: detail } }
        result = CityServiceArticleFetcher.new(source:, fetcher:).call(html: listing, fetched_at: Time.utc(2040, 9, 29))

        assert_equal :ok, result.status
        assert_equal url, result.articles.sole.source_url
        assert result.articles.sole.complete
        parser = CityServiceOfficialPostParser.new(organization: create_organization, source:)
        events = parser.call(article: result.articles.sole, fetched_at: Time.utc(2040, 9, 29))
        assert_equal "bulky_waste_collection", events.sole.event_type
        assert events.sole.starts_at
        assert events.sole.ends_at
      end

      test "redesigned river page yields two timed station readings and missing latest fails" do
        source = CityServiceSources.fetch("water_levels")
        html = fixture("vod.html")
        response = ->(**) { { http_status: 200, final_url: source.fetch(:source_url), content_type: "text/html", body: html } }
        check = CityServiceNoticeCollector.check(keys: ["water_levels"], fetcher: response).sole

        assert_equal :ok, check.status
        readings = check.notices.sole.metadata.fetch("readings")
        assert_equal %w(RS45882 RS45084), readings.map { |reading| reading.fetch("station_id") }
        assert_equal [43.0, 157.0], readings.map { |reading| reading.fetch("value") }
        assert readings.all? { |reading| reading.fetch("observed_at").include?("2040-09-29T06:45:00+01:00") }

        broken = html.sub(/"latest":\{[^}]+\}/, '"latest":null')
        failed = CityServiceNoticeCollector.check(keys: ["water_levels"], fetcher: ->(**) {
          { http_status: 200, final_url: source.fetch(:source_url), content_type: "text/html", body: broken }
        }).sole
        assert_equal :malformed, failed.status
        assert_empty failed.notices
      end

      test "complete AMS document does not borrow an unresolved bridge window for source completeness" do
        source = CityServiceSources.fetch("road_conditions")
        parser = CityServiceOfficialPostParser.new(organization: create_organization, source:)
        html = fixture("ams.html")
        assert parser.complete_snapshot?(html:)
        events = parser.call(html:, fetched_at: Time.utc(2040, 9, 29))
        assert events.any?
        assert events.all? { |event| event.extraction_metadata["source_snapshot_complete"] == true }
        assert events.any? { |event| event.extraction_metadata["complete"] == false }
      end

      private

      def fixture(name)
        FIXTURES.join(name).binread
      end
    end
  end
end
