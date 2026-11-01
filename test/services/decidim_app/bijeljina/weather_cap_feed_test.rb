# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_weather_region"

module DecidimApp
  module Bijeljina
    class WeatherCapFeedTest < ActiveSupport::TestCase
      include SyntheticWeatherRegion
      setup do
        install_synthetic_weather_region
        @now = Time.iso8601("2040-09-15T12:00:00Z")
      end

      teardown { restore_synthetic_weather_region }

      test "three CAP identities with two languages produce three upcoming warnings" do
        notices = parse(3.times.map { |index| alert(identifier: "warning-#{index}") })
        assert_equal 3, notices.size
        notices.each do |notice|
          metadata = notice.fetch(:metadata)
          assert_equal "bs", metadata["provider_language"]
          assert_equal "upcoming", metadata["temporal_status"]
          assert_equal "2040-09-15T06:00:00Z", metadata["source_published_at"]
          assert_equal "2040-09-15T07:00:00Z", metadata["effective_at"]
          assert_equal "2040-09-16T00:00:00Z", metadata["starts_at"]
          assert_equal "2040-09-16T08:00:00Z", metadata["ends_at"]
          assert_equal "TEST-REGION-A", metadata["provider_area_code"]
          assert_equal "Izmišljeni region", metadata["affected_area_text"]
          assert_equal "2040-09-13", metadata["area_evidence_checked_on"]
          assert_equal true, metadata["review_required"]
          assert_equal WeatherCapFeed::LICENSE_URL, metadata["license_url"]
          assert_match(/MeteoAlarm/, metadata["attribution"])
          assert_includes notice[:body], "Budite pažljivi."
        end
      end

      test "valid quiet CAP is empty while missing wrapper or changed shape fails closed" do
        assert_empty parse([])
        ["{}", '{"warnings":null}', '{"warnings":[{}]}', '{"warnings":{}}', "{"].each do |body|
          assert_raises(CityServiceNoticeCollector::ParserError) { WeatherCapFeed.call(body:, url: SyntheticWeatherRegion::SOURCE_URL, now: @now) }
        end
      end

      test "a nearby region name and unrelated geocode do not replace reviewed TEST-REGION-A geometry" do
        other = alert
        other["info"].each { |info| info["area"].first.merge!("areaDesc" => "Drugi autorski region", "geocode" => [{ "valueName" => "EMMA_ID", "value" => "TEST-REGION-B" }]) }
        assert_empty parse([other])
        other["info"].each { |info| info["area"].first["geocode"].first.merge!("valueName" => "OTHER", "value" => "TEST-REGION-A") }
        assert_empty parse([other])
      end

      test "test private expired and not-yet-effective warnings cannot become current" do
        %w(Test Exercise Draft).each { |status| assert_empty parse([alert.merge("status" => status)]) }
        assert_empty parse([alert.merge("scope" => "Restricted")])
        future_effective = alert
        future_effective["info"].each { |info| info["effective"] = "2040-09-16T01:00:00Z" }
        assert_empty parse([future_effective])
        assert_empty parse([alert], now: Time.iso8601("2040-09-16T08:00:00Z"))
        assert_equal "active", parse([alert], now: Time.iso8601("2040-09-16T01:00:00Z")).first[:metadata]["temporal_status"]
      end

      test "exact CAP cancellation suppresses the old alert even without an info block" do
        original = alert
        cancel = alert(identifier: "cancel").merge("msgType" => "Cancel", "sent" => "2040-09-15T11:00:00Z", "references" => reference(original))
        cancel.delete("info")
        assert_empty parse([original, cancel])
        assert_empty parse([cancel, original])
        foreign = original.merge("sender" => "other-authority.example.invalid")
        assert_equal 1, parse([original, cancel, foreign]).size
      end

      test "an update supersedes only referenced warnings and does not revive a cancelled chain" do
        original = alert
        update = alert(identifier: "update").merge("msgType" => "Update", "sent" => "2040-09-15T10:00:00Z", "references" => reference(original))
        update["info"].each { |info| info["severity"] = "Severe" }
        notices = parse([original, update, original])
        assert_equal(["update"], notices.map { |notice| notice[:metadata]["provider_identifier"] })
        assert_equal "Severe", notices.first[:metadata]["provider_severity"]
        cancel = alert(identifier: "cancel").merge("msgType" => "Cancel", "references" => reference(update))
        assert_empty parse([cancel, update, original])
      end

      test "a future effective update preserves the preceding alert until effective" do
        original = alert
        update = alert(identifier: "update").merge("msgType" => "Update", "references" => reference(original))
        update["info"].each { |info| info["effective"] = "2040-09-15T15:00:00Z" }
        assert_equal(["original"], parse([original, update]).map { |notice| notice[:metadata]["provider_identifier"] })
        assert_equal(["update"], parse([original, update], now: @now + 14_400).map { |notice| notice[:metadata]["provider_identifier"] })
      end

      test "invalid clock, missing offset, future publication and reversed intervals fail closed" do
        ["2040-09-15T11:00:00", "bad-date", "2040-09-17T11:00:00Z"].each do |sent|
          assert_raises(CityServiceNoticeCollector::ParserError) { parse([alert.merge("sent" => sent)]) }
        end
        wrong = alert
        wrong["info"].each { |info| info["expires"] = "2040-09-15T06:00:00Z" }
        assert_raises(CityServiceNoticeCollector::ParserError) { parse([wrong]) }
        malformed = alert.merge("msgType" => "Cancel", "references" => "malformed")
        assert_raises(CityServiceNoticeCollector::ParserError) { parse([malformed]) }
      end

      test "CAP optional effective and onset default from source sent and retain explicit clocks" do
        item = alert
        item["info"].each do |info|
          info.delete("effective")
          info.delete("onset")
        end
        metadata = parse([item]).first.fetch(:metadata)
        assert_equal metadata["source_published_at"], metadata["effective_at"]
        assert_equal metadata["effective_at"], metadata["starts_at"]
      end

      test "parser dispatcher accepts CAP and keeps source-safe citation URL and identity" do
        rows = CityServiceEvidenceParser.call(source: { key: "weather_warnings" }, body: JSON.generate("warnings" => [{ "alert" => alert }]), url: SyntheticWeatherRegion::SOURCE_URL, now: @now)
        assert_equal 1, rows.size
        assert_match(%r{\Ahttps://weather\.example\.invalid/feed#cap-}, rows.first.fetch(:url))
        assert_equal WeatherCapFeed::CITATION_URL, rows.first[:metadata]["provider_url"]
        assert_equal WeatherCapFeed::VERSION, rows.first[:metadata]["cap_parser_version"]
      end

      test "CAP and Atom both stamp the current explicit operator review without inheriting local geometry" do
        [parse([alert]), parse_atom].each do |rows|
          metadata = rows.fetch(0).fetch(:metadata)
          review = WeatherRegionConfiguration.load(day: @now.in_time_zone("Europe/Sarajevo").to_date)
          review.metadata.each { |key, value| assert_equal value, metadata.fetch(key), key }
          assert_equal "Izmišljeni region", metadata.fetch("affected_area_text")
          assert_equal "operator_reviewed_region_coverage", metadata.fetch("coverage_status")
          assert_not_equal "official_region_geometry_matched", metadata.fetch("coverage_status")
          assert_not_equal "Bijeljina", metadata.fetch("relevant_city")
        end
      end

      test "CAP and Atom reject missing region review instead of reporting a valid quiet feed" do
        ENV.delete("MI_WEATHER_REGION_CONFIG_PATH")
        assert_raises(CityServiceNoticeCollector::ParserError) { parse([]) }
        assert_raises(CityServiceNoticeCollector::ParserError) { parse_atom }
      end

      test "CAP and Atom source changes cannot borrow the prior region review" do
        [JSON.generate("warnings" => []), atom_body].each do |body|
          assert_raises(CityServiceNoticeCollector::ParserError) do
            CityServiceEvidenceParser.call(source: { key: "weather_warnings" }, body:,
                                           url: "https://other-weather.example.invalid/feed", now: @now)
          end
        end
      end

      test "CAP and Atom with expired future or unapproved review fail before claiming coverage" do
        [{ review_state: "pending" }, { valid_until: "2040-09-14" }, { reviewed_on: "2040-09-16" }].each do |changes|
          write_synthetic_weather_region(**changes)
          assert_raises(CityServiceNoticeCollector::ParserError) { parse([]) }
          assert_raises(CityServiceNoticeCollector::ParserError) { parse_atom }
        end
      end

      test "region changes select the new provider code and produce a new review identity" do
        original = parse([alert]).fetch(0).fetch(:metadata)
        write_synthetic_weather_region(provider_area_code: "TEST-REGION-B")
        assert_empty parse([alert])
        assert_empty parse_atom
        changed = alert
        changed["info"].each { |info| info["area"].first["geocode"].first["value"] = "TEST-REGION-B" }
        rows = [parse([changed]), parse_atom(body: atom_body.gsub("TEST-REGION-A", "TEST-REGION-B"))]
        rows.each do |notices|
          metadata = notices.fetch(0).fetch(:metadata)
          assert_equal "TEST-REGION-B", metadata.fetch("provider_area_code")
          assert_not_equal original.fetch("weather_region_review_id"), metadata.fetch("weather_region_review_id")
        end
      end

      test "each parser uses one immutable review across all entries in the same acquisition" do
        review = WeatherRegionConfiguration.load(day: @now.in_time_zone("Europe/Sarajevo").to_date)
        [-> { parse(3.times.map { |i| alert(identifier: "authored-#{i}") }) }, -> { parse_atom }].each do |operation|
          calls = 0
          loader = ->(**) { calls += 1; review }
          WeatherRegionConfiguration.stub(:for_source, loader) { assert operation.call.any? }
          assert_equal 1, calls
        end
      end

      private

      def atom_body
        <<~XML
          <feed xmlns="http://www.w3.org/2005/Atom" xmlns:cap="urn:oasis:names:tc:emergency:cap:1.2">
            <id>tag:meteoalarm.org,2021-02-19:BA</id><updated>2040-09-15T08:00:00Z</updated>
            <entry><title>Autorsko izmišljeno upozorenje</title>
              <cap:areaDesc>Izmišljeni region</cap:areaDesc><cap:event>Izmišljeni testni događaj</cap:event>
              <cap:sent>2040-09-15T06:00:00Z</cap:sent><cap:effective>2040-09-15T07:00:00Z</cap:effective>
              <cap:onset>2040-09-16T00:00:00Z</cap:onset><cap:expires>2040-09-16T08:00:00Z</cap:expires>
              <cap:severity>Moderate</cap:severity><cap:status>Actual</cap:status><cap:scope>Public</cap:scope>
              <cap:message_type>Alert</cap:message_type><cap:identifier>authored-atom-a</cap:identifier>
              <cap:geocode><valueName>EMMA_ID</valueName><value>TEST-REGION-A</value></cap:geocode>
            </entry>
          </feed>
        XML
      end

      def parse_atom(body: atom_body)
        CityServiceEvidenceParser.call(source: { key: "weather_warnings" }, body:, url: SyntheticWeatherRegion::SOURCE_URL, now: @now)
      end

      def parse(alerts, now: @now)
        WeatherCapFeed.call(body: JSON.generate("warnings" => alerts.map { |value| { "alert" => value } }), url: SyntheticWeatherRegion::SOURCE_URL, now:)
      end

      def reference(value)
        value.values_at("sender", "identifier", "sent").join(",")
      end

      def alert(identifier: "original")
        { "identifier" => identifier, "sender" => "weather-authority.example.invalid", "sent" => "2040-09-15T08:00:00+02:00",
          "status" => "Actual", "scope" => "Public", "msgType" => "Alert",
          "info" => %w(en bs).map do |language|
            { "language" => language, "event" => language == "bs" ? "Magla žuto upozorenje" : "Fog yellow warning",
              "headline" => language == "bs" ? "Upozorenje za region Izmišljeni region" : "Warning for region Izmišljeni region",
              "description" => "Magla u jutarnjim satima.", "instruction" => "Budite pažljivi.", "severity" => "Moderate",
              "senderName" => "Reviewed meteorological authority", "effective" => "2040-09-15T09:00:00+02:00",
              "onset" => "2040-09-16T02:00:00+02:00", "expires" => "2040-09-16T10:00:00+02:00",
              "area" => [{ "areaDesc" => "Izmišljeni region", "geocode" => [{ "valueName" => "EMMA_ID", "value" => "TEST-REGION-A" }] }] }
          end }
      end
    end
  end
end
