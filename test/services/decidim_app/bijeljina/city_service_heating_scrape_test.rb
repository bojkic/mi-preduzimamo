# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    # The heating domain is tested offline with authored synthetic pages.
    # Canonical reference hosts retain their host-keyed freshness contracts. Before this wiring the same listing produced nothing
    # at all: the shared path ingested the teaser, the teaser is incomplete, and
    # an incomplete article yields no events.
    class CityServiceHeatingScrapeTest < ActiveSupport::TestCase
      include PublicReferenceSourceRegistry
      include ActiveSupport::Testing::TimeHelpers

      LISTING = Rails.root.join("test/fixtures/files/synthetic/heating_listing.html")
      DETAIL = Rails.root.join("test/fixtures/files/synthetic/heating_detail.html")

      setup do
        @organization = create_organization
        @source = CityServiceSources.fetch("heating_service")
        @listing = LISTING.read
        @detail = DETAIL.read
        @now = Time.zone.local(2040, 9, 15, 9, 0, 0)
      end

      teardown { travel_back }

      test "the catalogue declares that heating follows its article links" do
        assert_equal true, @source.fetch(:follows_article_links)
        assert_equal "not_published", @source.fetch(:network_footprint)
        assert_equal CityServiceSources.all.select { |source| source[:follows_article_links] }.map { |source| source.fetch(:key) }.sort,
                     CityServiceSourceScrape::ARTICLE_FOLLOWERS.keys.sort
      end

      test "the teaser listing alone still yields nothing, which was the defect" do
        travel_to @now do
          result = CityServiceEventIngestor.new(organization: @organization)
                                           .ingest(source_key: "heating_service", html: @listing, source_url: @source.fetch(:source_url), fetched_at: Time.current)

          assert_equal 0, result.created
          assert_empty result.events
        end
      end

      test "owner disabled heating rejects even explicit scrape selection before fetching" do
        calls = 0
        fetcher = lambda do |**_arguments|
          calls += 1
          raise "disabled heating source was fetched"
        end
        scraper = CityServiceSourceScrape.new(organization: @organization, fetcher:)
        assert_raises(ArgumentError) { scraper.call(cadence: "daily", keys: ["heating_service"]) }
        assert_equal 0, calls
      end

      test "heating freshness may not be taken from an HTTP header" do
        assert CityServiceSources.content_freshness_only?("heating_service")
        assert_equal "no_last_modified_no_etag", CityServiceSources.http_freshness_evidence("heating_service")
        %w(water_service waste_schedule electricity_outages).each do |key|
          assert CityServiceSources.content_freshness_only?(key), key
        end
      end

      private

      def scrape(article_body: nil)
        follower = CityServiceHeatingArticles.new(source: @source, fetcher: lambda do |url:, timeout:, max_bytes:| # rubocop:disable Lint/UnusedBlockArgument
          { http_status: 200, final_url: url, content_type: "text/html; charset=UTF-8", body: article_body || @detail }
        end)
        CityServiceSourceScrape.new(organization: @organization, fetcher: listing_fetcher, now: Time.current, article_fetcher: follower)
                               .call(cadence: "daily", keys: ["heating_service"])
      end

      def listing_fetcher
        listing = @listing
        lambda do |source:, timeout:, max_bytes:, user_agent:| # rubocop:disable Lint/UnusedBlockArgument
          { http_status: 200, final_url: source.fetch(:source_url), content_type: "text/html; charset=UTF-8", body: listing }
        end
      end
    end
  end
end
