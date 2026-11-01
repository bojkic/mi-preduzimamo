# frozen_string_literal: true
require "test_helper"

module DecidimApp
  module Bijeljina
    class CityServiceSyntheticSourceTest < ActiveSupport::TestCase
      setup do
        @body = file_fixture("synthetic/civil_protection_feed.xml").read
        @now = Time.find_zone!("Europe/Sarajevo").parse("2040-04-09 12:00")
        @source = CityServiceSources::REFERENCE_SOURCES.find { |source| source.fetch(:key) == "civil_protection" }.merge(enabled: true)
        @previous_sources = CityServiceSources::SOURCES
        CityServiceSources.send(:remove_const, :SOURCES)
        CityServiceSources.const_set(:SOURCES, [@source].freeze)
      end

      teardown do
        CityServiceSources.send(:remove_const, :SOURCES)
        CityServiceSources.const_set(:SOURCES, @previous_sources)
      end

      test "invented feed keeps current warning and rejects recruitment and expired items" do
        fetcher = ->(**) { { body: @body, http_status: 200, content_type: "application/rss+xml", final_url: @source.fetch(:source_url) } }
        check = CityServiceNoticeCollector.check(keys: ["civil_protection"], fetcher:, now: @now).first
        assert_equal :ok, check.status
        assert_equal 1, check.notices.length
        notice = check.notices.first
        assert_equal "UPOZORENJE — IZMIŠLJENI TEST", notice.title
        assert_equal "https://ruczrs.org/synthetic-warning", notice.url
        assert_equal "2040-04-09T00:00:00+02:00", notice.metadata.fetch("starts_at")
        assert_equal "2040-04-10T00:00:00+02:00", notice.metadata.fetch("ends_at")
        assert_equal "source_fact", notice.metadata.fetch("content_role")
        assert_equal true, notice.metadata.fetch("review_required")
        assert_equal "source_declared_region", notice.metadata.fetch("geographic_status")
      end

      test "synthetic road report filters unrelated places and preserves reported status" do
        body = file_fixture("synthetic/road_conditions.html").read
        rows = DecidimApp::Bijeljina::CityServiceEvidenceParser.call(source: { key: "road_conditions" }, body:, url: "https://v3.satwork.net/synthetic-report", now: @now)
        assert_equal 1, rows.length
        metadata = rows.first.fetch(:metadata)
        assert_equal "as_reported", metadata.fetch("temporal_status")
        assert_equal "2040-04-08T12:00:00+02:00", metadata.fetch("source_published_at")
        assert_equal true, metadata.fetch("review_required")
        refute metadata.key?("starts_at"), "publication must not invent a work start time"
      end

      test "synthetic campaign has exact window and honest expired listing state" do
        body = file_fixture("synthetic/bulky_waste.html").read
        parser = DecidimApp::Bijeljina::CityServiceEvidenceParser
        rows = parser.call(source: { key: "bulky_waste" }, body:, url: "https://www.komunalacbn.com/synthetic-listing", now: @now)
        assert_equal 1, rows.length
        metadata = rows.first.fetch(:metadata)
        assert_equal "active", metadata.fetch("temporal_status")
        assert_equal "2040-04-09T00:00:00+02:00", metadata.fetch("starts_at")
        assert_equal "2040-04-12T00:00:00+02:00", metadata.fetch("ends_at")
        expired = parser.call(source: { key: "bulky_waste" }, body:, url: "https://www.komunalacbn.com/synthetic-listing", now: @now + 15.days)
        assert_equal "no_current_campaign_listed", expired.first.fetch(:metadata).fetch("temporal_status")
        assert_equal "2040-04-12T00:00:00+02:00", expired.first.fetch(:metadata).fetch("last_campaign_ends_at")
      end


      test "content filter rejects synthetic tenders adverts sessions and consent even with topical words" do
        noise = {
          "road_conditions" => ["Javni tender za radove na kolovozu", "Oglas za posao: radovi na kolovozu"],
          "bulky_waste" => ["Saziv sjednice o akciji čišćenja grada", "Licitacija: akcija čišćenja"],
          "civil_protection" => ["Kolačići – upozorenje o privatnosti", "Cookie upozorenje", "ЈАВНИ КОНКУРС – упозорење за приправнике"]
        }
        noise.each do |key, titles|
          titles.each { |title| assert_not CityServiceContentFilter.relevant?(key, title, now: @now), "#{key}: #{title}" }
        end
        assert CityServiceContentFilter.relevant?("civil_protection", "Упозорење на поплаве — измишљени тест", now: @now)
        assert CityServiceContentFilter.relevant?("bulky_waste", "Одвожење кабастог отпада у априлу 2040.", now: @now)
        assert CityServiceContentFilter.relevant?("road_conditions", "Обустава саобраћаја због радова — измишљени тест", now: @now)
      end

      test "expired synthetic civil warning becomes an empty listing without a source error" do
        fetcher = ->(**) { { body: @body, http_status: 200, content_type: "application/rss+xml", final_url: @source.fetch(:source_url) } }
        check = CityServiceNoticeCollector.check(keys: ["civil_protection"], fetcher:, now: @now + 15.days).first
        assert_equal :empty, check.status
        assert_nil check.error_code
        assert_empty check.notices
      end

      test "an unknown fictional region is not inferred to cover this community" do
        body = @body.gsub("CIJELA REPUBLIKA SRPSKA", "IZMIŠLJENI NEPOZNATI REGION")
        facts = CityServiceEvidenceParser.call(source: @source, body:, url: @source.fetch(:source_url), now: @now)
        assert_empty facts
      end
    end
  end
end
