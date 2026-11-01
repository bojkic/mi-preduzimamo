# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require_relative "../../../support/synthetic_weather_region"

module DecidimApp
  module Bijeljina
    class CityServiceCivicAdaptersTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include SyntheticWeatherRegion
      setup do
        @organization = create_organization
        @now = Time.iso8601("2040-09-19T08:00:00Z")
        install_synthetic_weather_region
        write_synthetic_weather_region(organization_host: @organization.host,
          source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url),
          region_label: "Autorski region", community_label: "Autorska zajednica")
      end

      teardown { restore_synthetic_weather_region if @synthetic_weather_region_root }

      test "local road closure has quoted evidence while unrelated regional notices and promotion are excluded" do
        local = parse("road_conditions", "U Bijeljini se obustavlja saobraćaj u ulici 20.09.2040. od 09:00 do 14:00.")
        assert_equal "road_closure", local.sole.event_type
        assert_equal "roads", local.sole.extraction_metadata["service"]
        assert local.sole.extraction_metadata["requires_human_review"]
        assert_includes local.sole.extraction_metadata["source_quotation"], "Bijeljini"
        assert_empty parse("road_conditions", "U Izmišljenomudaljenommjestu se obustavlja saobraćaj 20.09.2040. od 09:00 do 14:00.")
        assert_empty parse("road_conditions", "Bijeljina: tender za radove na ulici 20.09.2040. od 09:00 do 14:00.")
      end

      test "an end-only roadworks date is retained without inventing a future start" do
        ["U Bijeljini je obustava saobraćaja zbog radova (do 31.12.2040.).",
         "У Бијељини је обустава саобраћаја због радова (до 31.12.2040.)."].each do |text|
          event = parse("road_conditions", text).sole
          assert_nil event.starts_at
          assert_equal "2041-01-01T00:00:00+01:00", event.ends_at.iso8601
          assert_equal false, event.extraction_metadata["complete"]
          assert_equal "unknown_start", event.extraction_metadata["temporal_status"]
        end
        # An explicit start/end date span must still retain both boundaries.
        windows = CityServiceTime.schedule("od 20.09.2040. do 22.09.2040.", date: Date.new(2040, 9, 20), reference: @now)
        assert_equal 3, windows.size
        assert(windows.all? { |window| window[:starts_at].present? })
      end

      test "one road paragraph cannot borrow a deadline from another item" do
        source = CityServiceSources.fetch("road_conditions")
        html = <<~HTML
          <article>
            <p>Druga dionica ostaje zatvorena do 25.1.2043.</p>
            <p>U Bijeljini je obustava saobraćaja na putu za Izmišljeni most do 31.12.2040.</p>
          </article>
        HTML
        event = CityServiceOfficialPostParser.new(organization: @organization, source:).call(html:, fetched_at: @now).sole

        assert_nil event.starts_at
        assert_equal "2041-01-01T00:00:00+01:00", event.ends_at.iso8601
        assert_equal "do 31.12.2040.", event.extraction_metadata.fetch("temporal_evidence")
        assert_equal "unknown_start", event.extraction_metadata.fetch("temporal_status")
        assert_equal false, event.extraction_metadata.fetch("complete")
      end

      test "a veterinary funding call does not become a public health alert" do
        text = "JAVNI POZIV za raspodjelu sredstava veterinarskim organizacijama za sprovođenje mjera zdravstvene zaštite pasa u Gradu Bijeljina za 2040. godinu"
        assert_empty parse("city_official_notices", text)
        assert_equal "public_health_notice", parse("city_official_notices", "U Bijeljini 20.09.2040. od 09:00 do 14:00 obavještenje o mjerama zdravstvene zaštite građana.").sole.event_type
      end

      test "an oversized affected-location list fails closed" do
        text = Array.new(31, "Izmišljeni vrt (Izmišljeni vrt)").join("; ")
        result = CityServiceAreaMatcher.new(organization: @organization).match_water_clauses(text)
        assert_equal "unknown", result.targeting_level
        assert_equal false, result.coverage.fetch("complete")
        assert_equal 31, result.coverage.fetch("unresolved_clause_count")
      end

      test "complete city article retains bounded full text for AI assessment" do
        source = CityServiceSources.fetch("city_official_notices")
        url = "https://www.gradbijeljina.org/lat/news/obavjestenja/900001.izmisljeni-test.html"
        article = CityServiceArticle.extract(html: <<~HTML, source_url: url).sole
          <article><h1>Obavještenje o saobraćaju</h1>
            <p>U Bijeljini 20.09.2040. od 09:00 do 14:00 obustava saobraćaja u ulici Izmišljena breza.</p></article>
        HTML
        parser = CityServiceOfficialPostParser.new(organization: @organization, source:)
        event = parser.call(article:, fetched_at: @now).sole
        assert_includes event.extraction_metadata.fetch("ai_source_text"), "obustava saobraćaja"
        assert_equal true, event.extraction_metadata.fetch("source_document_complete")
        listing_event = parser.call(html: article.html, source_url: url, fetched_at: @now).sole
        assert_nil listing_event.extraction_metadata["ai_source_text"]
      end

      test "mixed water locations retain every unresolved city street" do
        source = CityServiceSources.fetch("water_service")
        html = <<~HTML
          <article><p>24.09.2040. od 08:00 do 14:30 moguć je prekid vodosnabdijevanja na sljedećim lokacijama:</p>
            <ul><li>Izmišljena lipa (Bijeljina)</li><li>Izmišljeni javor (Bijeljina)</li>
            <li>Izmišljeni bor (Bijeljina)</li><li>Izmišljeni hrast (Izmišljeni zaseok)</li><li>Izmišljeni vrt (Izmišljeni vrt)</li></ul></article>
        HTML
        event = CityServiceOfficialPostParser.new(organization: @organization, source:).call(html:, fetched_at: @now).sole
        coverage = event.extraction_metadata.fetch("coverage")

        assert_equal 5, coverage.fetch("clause_count")
        assert_operator coverage.fetch("unresolved_clause_count"), :>=, 3
        assert_equal false, coverage.fetch("complete")
        assert_equal "unknown", event.targeting_level
        assert_empty event.affected_area_slugs
        assert_includes coverage.fetch("unresolved_places").map { |row| row.fetch("evidence") }, "Izmišljena lipa (Bijeljina)"
      end

      test "bulky waste creates a board review candidate without adding Viber eligibility" do
        event = parse("bulky_waste", "U Bijeljini akcija prikupljanja kabastog otpada 20.09.2040. od 09:00 do 14:00.").sole
        assert_equal "bulky_waste_collection", event.event_type
        assert_equal "info", event.severity
        assert_not CityServiceSources.fetch("bulky_waste").dig(:viber, :eligible)
      end

      test "civil protection RSS uses item body and publication rather than feed navigation" do
        body = "Upozorenje na poplave u Bijeljini 20.09.2040. od 09:00 do 14:00."
        xml = <<~XML
          <rss><channel><title>Bijeljina</title><item><title>Upozorenje</title>
          <link>https://civil-protection.example.invalid/izmisljeni-test/</link><pubDate>Wed, 19 Sep 2040 08:00:00 +0000</pubDate>
          <description><![CDATA[<p>#{body}</p>]]></description></item></channel></rss>
        XML
        source = CityServiceSources.fetch("civil_protection")
        event = CityServiceOfficialPostParser.new(organization: @organization, source:).call(html: xml, fetched_at: @now).sole
        assert_equal "emergency_notice", event.event_type
        assert_equal "https://civil-protection.example.invalid/izmisljeni-test/", event.source_url
        assert_equal @now, event.source_published_at
        assert event.extraction_metadata["requires_human_review"]
      end

      test "CAP parser preserves regional evidence without inventing neighborhood targets" do
        info = { "language" => "sr", "event" => "Oluja", "headline" => "Upozorenje na oluju", "severity" => "Severe",
                 "onset" => "2040-09-19T09:00:00Z", "expires" => "2040-09-19T18:00:00Z",
                 "area" => [{ "areaDesc" => "Regija Primjerpolje", "geocode" => [{ "valueName" => "EMMA_ID", "value" => "TEST-REGION-A" }] }] }
        alert = { "sender" => "test-provider", "identifier" => "warning-1", "sent" => "2040-09-19T07:00:00Z",
                  "status" => "Actual", "scope" => "Public", "msgType" => "Alert", "info" => [info] }
        event = CityServiceWeatherParser.new(organization: @organization).call(html: { warnings: [{ alert: }] }.to_json, fetched_at: @now).sole
        assert_equal "severe_weather", event.event_type
        assert_equal "unknown", event.targeting_level
        assert_empty event.affected_area_slugs
        assert_equal "Autorski region (Autorska zajednica)", event.affected_text
        assert_equal "Regija Primjerpolje", event.extraction_metadata["affected_area_text"]
        assert event.extraction_metadata["requires_human_review"]
        assert_equal "2040-09-19T09:00:00Z", event.starts_at.iso8601
      end

      # Reference warning policy is retained; provider region labels in this
      # authored fixture are metadata, not citizen-facing target claims.
      test "only orange and red warnings become alerts" do
        assert_empty weather_events("Moderate")
        assert_empty weather_events("Minor")
        assert_equal 1, weather_events("Severe").size
        assert_equal "emergency", weather_events("Extreme").sole.severity
      end

      test "what a resident reads never names the provider's region and uses local clock times" do
        event = weather_events("Severe").sole

        assert_equal "Vjetar narandžasto upozorenje – Autorski region (Autorska zajednica)", event.title
        assert_equal "Vjetar narandžasto upozorenje – Autorski region (Autorska zajednica). IZMIŠLJENI udari vjetra od 41 do 63 km/h. " \
                     "Od 24.09. u 02:00 do 25.09. u 01:59. IZMIŠLJENA TESTNA PREPORUKA za oprez.", event.summary
        assert_equal event.summary, event.viber_text
        [event.title, event.summary, event.viber_text, event.affected_text, event.recommended_action].each do |text|
          assert_no_match(/primjerregija/i, text)
        end
        assert_equal "Primjerregija", event.extraction_metadata["affected_area_text"]
        assert_equal "Vjetar narandžasto Upozorenje za Bosnu i Hercegovinu - region Primjerregija", event.extraction_metadata["provider_headline"]
        assert_includes event.extraction_metadata["source_quotation"], "Primjerregija"
      end

      test "only recognized complete documents can establish healthy empty extraction" do
        source = CityServiceSources.fetch("road_conditions")
        parser = CityServiceOfficialPostParser.new(organization: @organization, source:)
        assert_not parser.complete_snapshot?(html: "<html><body>Service unavailable</body></html>")
        assert_not parser.complete_snapshot?(html: "<article><p>U Bijeljini obustava saobraćaja...</p>")
        assert parser.complete_snapshot?(html: "<article><p>Redovne informacije bez obustava.</p></article>")
        rss_parser = CityServiceOfficialPostParser.new(organization: @organization, source: CityServiceSources.fetch("civil_protection"))
        assert_not rss_parser.complete_snapshot?(html: "<html><body>Upstream error</body></html>")
        assert_not rss_parser.complete_snapshot?(html: "<rss><channel><item>")
        assert rss_parser.complete_snapshot?(html: "<rss><channel></channel></rss>")
      end

      private

      def weather_events(severity)
        info = { "language" => "bs", "event" => "Vjetar narandžasto Upozorenje", "severity" => severity,
                 "headline" => "Vjetar narandžasto Upozorenje za Bosnu i Hercegovinu - region Primjerregija",
                 "description" => "IZMIŠLJENI udari vjetra od 41 do 63 km/h", "instruction" => "IZMIŠLJENA TESTNA PREPORUKA za oprez.",
                 "onset" => "2040-09-24T00:00:00Z", "expires" => "2040-09-24T23:59:59Z",
                 "area" => [{ "areaDesc" => "Primjerregija", "geocode" => [{ "valueName" => "EMMA_ID", "value" => "TEST-REGION-A" }] }] }
        alert = { "sender" => "test-provider", "identifier" => "wind-#{severity}", "sent" => "2040-09-23T07:00:00Z",
                  "status" => "Actual", "scope" => "Public", "msgType" => "Alert", "info" => [info] }
        CityServiceWeatherParser.new(organization: @organization).call(html: { warnings: [{ alert: }] }.to_json, fetched_at: Time.iso8601("2040-09-23T08:00:00Z"))
      end

      def parse(key, text)
        source = CityServiceSources.fetch(key)
        CityServiceOfficialPostParser.new(organization: @organization, source:).call(html: "<article><p>#{text}</p></article>", fetched_at: @now)
      end
    end
  end
end
