# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_event_source_registry"
require_relative "../../../../support/synthetic_weather_region"

module DecidimApp
  module Bijeljina
    module Milica
      class SourceReadTest < ActiveSupport::TestCase
        include SyntheticEventSourceRegistry
        include SyntheticWeatherRegion
        Context = Struct.new(:now, :organization_id, :deadline, keyword_init: true) do
          def allows?(capability)
            capability == "public_reads"
          end
        end

        setup do
          @now = Time.utc(2040, 9, 9, 12)
          @organization = create_organization
          @context = Context.new(now: @now, organization_id: @organization.id)
          install_synthetic_weather_region
          write_synthetic_weather_region(organization_host: @organization.host,
            source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url), reviewed_on: "2040-09-07")
          @weather_review = WeatherRegionConfiguration.load(day: @now.in_time_zone("Europe/Sarajevo").to_date)
          @checks_called = 0
        end

        teardown { restore_synthetic_weather_region }

        test "measurement time comes from source and stale reading is not revived by fresh collection" do
          metadata = water_metadata(station: "Izmišljeni senzor A", observed_at: "2040-09-01T08:00:00+02:00")
          result = read(topic: "water_levels", notices: [notice("water_levels", metadata:)])
          assert_equal "stale", result[:status]
          assert_empty result[:facts]
          assert_includes result[:warnings], "measurement_stale"
          assert_equal @now.iso8601, result[:checked_at]
        end

        test "unknown sensor time is visible and does not imply official or neighborhood coverage" do
          metadata = { "kind" => "air_quality_observation", "pollutant" => "PM2.5", "value" => 17, "unit" => "µg/m³",
                       "latitude" => 0.75, "longitude" => 0.21, "observation_time_text" => "Izmišljeni opis bez potvrđenog vremena opažanja" }
          result = read(topic: "air_quality", notices: [notice("air_quality_realtime", metadata:)])
          fact = result[:facts].first
          assert_equal "ok", result[:status]
          assert_includes fact["text"], "Vrijeme mjerenja nije pouzdano navedeno"
          assert_includes fact["text"], "nije službeno mjerenje"
          assert_nil fact["observed_at"]
          assert_equal "community_sensor", fact["authority"]
          assert_equal "community_city_marker", fact["coverage"]["scope"]
          assert_empty fact["coverage"]["area_ids"]
          assert_equal "source_map_marker_not_verified_sensor_location", fact["coordinates"]["role"]
        end

        test "specific neighborhood and date questions cannot be answered by unscoped undated sensor data" do
          metadata = { "kind" => "air_quality_observation", "pollutant" => "PM2.5", "value" => 17, "unit" => "µg/m³" }
          notices = [notice("air_quality_realtime", metadata:)]
          area_result = read(topic: "air_quality", notices:, entities: { "area_query" => "Izmišljeno polje" })
          date_result = read(topic: "air_quality", notices:, entities: { "date" => "2040-09-09" })
          assert_equal "ambiguous", area_result[:status]
          assert_empty area_result[:facts]
          assert_equal "unavailable", date_result[:status]
          assert_empty date_result[:facts]
        end

        test "station filter runs before the eight-fact limit" do
          notices = 12.times.map do |index|
            notice("water_levels", metadata: water_metadata(station: "Stanica #{index}", observed_at: "2040-09-09T12:00:00+02:00"), fingerprint: index.to_s)
          end
          result = read(topic: "water_levels", notices:, entities: { "area_query" => "Stanica 9" })
          assert_equal "ok", result[:status]
          assert_equal(["Stanica 9"], result[:facts].map { |fact| fact["station"] })
          assert_equal 30, @received_limit
        end

        test "official air PDF is a document link and cannot become an extracted measurement" do
          result = read(topic: "air_quality", notices: [notice("air_quality", metadata: {})])
          fact = result[:facts].first
          assert_equal "source_document", fact["kind"]
          assert_nil fact["value"]
          assert_nil fact["observed_at"]
          assert_includes fact["text"], "nisu izdvojeni iz PDF-a"
        end

        test "future timestamp is never a valid observed fact and old matching date is honestly historical" do
          future = notice("water_levels", metadata: water_metadata(station: "Izmišljeni senzor A", observed_at: "2040-09-10T12:00:00+02:00"))
          assert_empty read(topic: "water_levels", notices: [future])[:facts]
          historical = notice("water_levels", metadata: water_metadata(station: "Izmišljeni senzor A", observed_at: "2040-09-01T08:00:00+02:00"))
          result = read(topic: "water_levels", notices: [historical], entities: { "date" => "2040-09-01" })
          assert_equal "ok", result[:status]
          assert_equal "2040-09-01T08:00:00+02:00", result[:facts].first["observed_at"]
          assert_includes result[:warnings], "historical_snapshot_not_complete_series"
        end

        test "prepared warning expires at read time without waiting for another refresh" do
          metadata = warning_metadata.merge("ends_at" => @now.iso8601)
          result = read(topic: "weather", notices: [notice("weather_warnings", metadata:)])
          assert_empty result[:facts]
          assert_includes result[:warnings], "source_notice_expired"
          assert_not_equal "ok", result[:status]
        end

        test "dated warning supports tomorrow and preserves source regional coverage separately from local areas" do
          metadata = warning_metadata.merge("starts_at" => "2040-09-10T00:00:00+02:00", "ends_at" => "2040-09-11T00:00:00+02:00")
          result = read(topic: "weather", notices: [notice("weather_warnings", metadata:)], entities: { "time_expression" => "sutra" })
          assert_equal "ok", result[:status]
          fact = result[:facts].sole
          assert_equal "upcoming", fact["temporal_status"]
          assert_equal @weather_review.display_label, fact["affected_area_text"]
          assert_equal "Izmišljena regija", fact["provider_region_label"]
          assert_empty fact["coverage"]["area_ids"]
          assert_equal true, fact["review_required"]
          assert_equal "Moderate", fact["provider_severity"]
          assert_equal "TEST-REGION-A", fact["provider_area_code"]
          assert_includes fact["warning_codes"], "source_coverage_not_verified_mz_or_komsiluk"
          assert_empty read(topic: "weather", notices: [notice("weather_warnings", metadata:)], entities: { "date" => "2040-09-09" })[:facts]
        end

        test "specific neighborhood request is not answered with unrelated regional warning" do
          result = read(topic: "weather", notices: [notice("weather_warnings", metadata: warning_metadata)], entities: { "area_query" => "Izmišljeno polje" })
          assert_equal "ambiguous", result[:status]
          assert_empty result[:facts]
          assert_includes result[:warnings], "requested_area_not_supported_by_source"
        end

        test "historical warning date uses validity window and exact exclusive end" do
          metadata = warning_metadata.merge("starts_at" => "2040-09-03T00:00:00+02:00", "ends_at" => "2040-09-09T00:00:00+02:00")
          notices = [notice("civil_protection", metadata:)]
          previous = read(topic: "civil_protection", notices:, entities: { "date" => "2040-09-08" })
          assert_equal "ok", previous[:status]
          assert_equal "expired", previous[:facts].sole["temporal_status"]
          assert_empty read(topic: "civil_protection", notices:, entities: { "date" => "2040-09-09" })[:facts]
        end

        test "road today uses provider report date without inventing a roadwork interval" do
          metadata = { "kind" => "road_condition", "temporal_status" => "as_reported", "source_published_at" => @now.iso8601,
                       "affected_area_text" => "Izmišljeni pravac A–B" }
          notices = [notice("road_conditions", metadata:)]
          result = read(topic: "roads", notices:, entities: { "time_expression" => "danas" })
          assert_equal "ok", result[:status]
          assert_nil result[:facts].sole["starts_at"]
          assert_empty read(topic: "roads", notices:, entities: { "time_expression" => "sutra" })[:facts]
          assert_empty read(topic: "roads", notices:, entities: { "date" => "2040-09-08" })[:facts]
        end

        test "completed campaign listing describes checked day and retains original campaign dates" do
          metadata = { "kind" => "campaign_status", "temporal_status" => "no_current_campaign_listed",
                       "last_campaign_starts_at" => "2040-04-15T00:00:00+02:00", "last_campaign_ends_at" => "2040-05-01T00:00:00+02:00" }
          notices = [notice("bulky_waste", metadata:)]
          result = read(topic: "bulky_waste", notices:, entities: { "time_expression" => "danas" })
          assert_equal "ok", result[:status]
          fact = result[:facts].sole
          assert_nil fact["starts_at"]
          assert_equal metadata["last_campaign_ends_at"], fact["last_campaign_ends_at"]
          assert_empty read(topic: "bulky_waste", notices:, entities: { "time_expression" => "sutra" })[:facts]
          assert_empty read(topic: "bulky_waste", notices:, entities: { "date" => "2040-04-15" })[:facts]
        end

        test "unreviewed prepared public notices remain usable with explicit uncertainty" do
          result = read(topic: "weather", notices: [notice("weather_warnings", metadata: warning_metadata)], status: :unreviewed)
          assert_equal "ok", result[:status]
          assert_equal 1, result[:facts].size
          assert_includes result[:warnings], "source_facts_unconfirmed"
          assert_includes result[:facts].sole.fetch("text"), I18n.t("decidim_app.city_service_events.bot.unconfirmed_facts", locale: "sr")
        end

        test "a named city cannot bypass the source declared weather region" do
          %w(Bijeljina NepovezanaZajednica).each do |city|
            result = read(topic: "weather", notices: [notice("weather_warnings", metadata: warning_metadata)], entities: { "area_query" => city })
            assert_equal "ambiguous", result[:status], city
            assert_empty result[:facts]
            assert_includes result[:warnings], "requested_area_not_supported_by_source"
          end
        end

        test "warning local validity names the configured time zone without assigning a city" do
          result = read(topic: "weather", notices: [notice("weather_warnings", metadata: warning_metadata)])
          row = result.fetch(:facts).fetch(0)
          assert_includes row.fetch("local_validity"), "Europe/Sarajevo"
          assert_includes row.fetch("local_validity"), "09.09.2040. 00:00 +02:00"
          assert_not_includes row.fetch("local_validity"), "Bijeljini"
          assert_equal @weather_review.display_label, row.fetch("affected_area_text")
          assert_equal "Izmišljena regija", row.fetch("provider_region_label")
          assert_empty row.fetch("coverage").fetch("area_ids")
        end

        test "weather locality requires every current review field rather than legacy geometry flags" do
          metadata = warning_metadata.merge(@weather_review.metadata)
          [metadata.reject { |key, _| key == "weather_region_review_id" },
           metadata.merge("coverage_status" => "official_region_geometry_matched"),
           metadata.merge("provider_area_code" => "WRONG-REGION"),
           metadata.merge("relevant_city" => "Unrelated invented city")].each do |row|
            result = read(topic: "weather", notices: [notice("weather_warnings", metadata: row, bind_review: false)])
            assert_equal "unavailable", result[:status]
            assert_empty result[:facts]
            assert_includes result[:warnings], "weather_region_review_mismatch"
          end
        end

        test "changed region review withholds retained warning while exposing only current reviewed scope" do
          retained = notice("weather_warnings", metadata: warning_metadata)
          write_synthetic_weather_region(organization_host: @organization.host,
            source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url), reviewed_on: "2040-09-07",
            region_label: "Druga autorska pregledana regija")
          result = read(topic: "weather", notices: [retained])
          assert_equal "unavailable", result[:status]
          assert_empty result[:facts]
          scope = result.fetch(:coverage).fetch("reviewed_region_scope")
          assert_equal "Druga autorska pregledana regija", scope.fetch("region_label")
          assert_not_equal @weather_review.identity, scope.fetch("review_id")
          assert_equal false, scope.fetch("live_warning_status")
        end

        test "wrong organization or source review is refused before reading prepared weather checks" do
          other = Struct.new(:id, :host).new(@organization.id, "other.example.invalid")
          result = read(topic: "weather", notices: [], organization: other)
          assert_equal "unavailable", result[:status]
          assert_empty result[:facts]
          assert_equal 0, @checks_called
          write_synthetic_weather_region(source_url: "https://other-weather.example.invalid/feed", reviewed_on: "2040-09-07")
          result = read(topic: "weather", notices: [])
          assert_equal "unavailable", result[:status]
          assert_empty result[:facts]
          assert_equal 0, @checks_called
        end

        test "weather metadata with invalid interval future effectiveness or future publication cannot establish warning facts" do
          [{ "ends_at" => "2040-09-08T00:00:00+02:00" }, { "starts_at" => nil },
           { "effective_at" => "2040-09-10T00:00:00+02:00" }, { "source_published_at" => "2040-09-10T00:00:00+02:00" },
           { "kind" => "source_information" }].each do |changes|
            result = read(topic: "weather", notices: [notice("weather_warnings", metadata: warning_metadata.merge(changes))])
            assert_equal "unavailable", result[:status]
            assert_empty result[:facts]
            assert_includes result[:warnings], "weather_warning_metadata_invalid"
          end
        end

        test "empty prepared weather check without acquisition review identity is not proof of no warnings" do
          result = read(topic: "weather", notices: [], status: :empty)
          assert_equal "unavailable", result[:status]
          assert_empty result[:facts]
          assert_includes result[:warnings], "weather_empty_snapshot_not_region_bound"
          assert_equal false, result.fetch(:coverage).fetch("reviewed_region_scope").fetch("live_warning_status")
        end

        test "reviewed scope remains separate from unavailable current warning evidence" do
          result = read(topic: "weather", notices: [], status: :unavailable)
          assert_equal "unavailable", result[:status]
          assert_empty result[:facts]
          scope = result.fetch(:coverage).fetch("reviewed_region_scope")
          assert_equal @weather_review.identity, scope.fetch("review_id")
          assert_equal @weather_review.evidence_url, scope.fetch("evidence_url")
          assert_equal false, scope.fetch("live_warning_status")
          assert_equal false, result.fetch(:validity).fetch("live_status")
        end

        test "both typed weather bridges bind organization and preserve structured review metadata in every locale" do
          dialogue = Decidim::Bih::Concierge::Dialogue
          %w(capability information).product(%w(sr sr-Cyrl bs hr)).each do |bridge, locale|
            context = dialogue::Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: Digest::SHA256.hexdigest("authored-weather-scope"),
              capabilities: ["public_reads"], now: @now, deadline: dialogue::TurnBudget.new(timeout: 9))
            result = read(topic: "weather", notices: [notice("weather_warnings", metadata: warning_metadata)], context:, locale:, typed: bridge)
            assert_equal "ok", result.status
            row = result.facts.fetch(0)
            assert_equal @weather_review.identity, row.fetch("weather_region_review_id")
            assert_equal "TEST-REGION-A", row.fetch("provider_area_code")
            assert_equal @organization.id, result.coverage.fetch("organization_id")
            assert_equal false, result.coverage.fetch("reviewed_region_scope").fetch("live_warning_status")
            assert_empty row.fetch("coverage").fetch("area_ids")
            assert_match(/\p{Cyrillic}/, row.fetch("text")) if locale == "sr-Cyrl"
          end
        end

        test "typed weather reads retain tenant actor capability and deadline guards before source access" do
          dialogue = Decidim::Bih::Concierge::Dialogue
          context = dialogue::Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: Digest::SHA256.hexdigest("authored-weather-scope"),
            capabilities: ["public_reads"], now: @now, deadline: dialogue::TurnBudget.new(timeout: 9))
          [context.with(organization_id: @organization.id + 1), context.with(actor_id: Decidim::User.maximum(:id).to_i + 1)].each do |invalid|
            assert_raises(dialogue::Contracts::Invalid) { read(topic: "weather", notices: [], context: invalid, typed: "capability") }
          end
          result = read(topic: "weather", notices: [], context: context.with(capabilities: []), typed: "capability")
          assert_equal "not_authorized", result.status
          assert_empty result.facts
          result = read(topic: "weather", notices: [], context: context.with(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1), typed: "information")
          assert_equal "unavailable", result.status
          assert_empty result.facts
          assert_equal 0, @checks_called
        end

        test "explicit yellow selection happens before the fact limit so unrelated severities cannot hide the requested warning" do
          rows = 20.times.map do |index|
            notice("weather_warnings", metadata: warning_metadata.merge("provider_severity" => "Severe"), fingerprint: "other-#{index}")
          end
          rows << notice("weather_warnings", metadata: warning_metadata, fingerprint: "yellow-last")
          result = read(topic: "weather", notices: rows, entities: { "category" => "weather_yellow" })
          assert_equal "ok", result[:status]
          assert_equal 1, result[:facts].size
          assert_equal "Moderate", result[:facts].sole.fetch("provider_severity")
          assert_equal 21, result.fetch(:coverage).fetch("prepared_candidate_count")
        end

        private

        def read(topic:, notices:, entities: {}, status: :ok, organization: @organization, context: @context, locale: "sr", typed: nil)
          groups = notices.group_by(&:source_key)
          groups[CityServiceSources::TOPIC_SOURCE_KEYS.fetch(topic).first] = [] if groups.empty?
          checks = groups.map do |key, rows|
            check_status = status == :ok && rows.empty? ? :empty : status
            checked_at = %i(ok empty unreviewed).include?(check_status) ? @now : nil
            CityServiceNoticeCollector::SourceCheckResult.new(source_key: key, status: check_status, notices: rows, checked_at:)
          end
          receiver = self
          collector = Object.new
          collector.define_singleton_method(:check) do |**options|
            receiver.instance_variable_set(:@received_limit, options[:max_items])
            receiver.instance_variable_set(:@checks_called, receiver.instance_variable_get(:@checks_called) + 1)
            checks
          end
          if typed
            port = ReadPort.new(organization:, source_checker: collector)
            return port.call(action: "ask_information", topic:, entities:, context:, locale:) if typed == "information"

            return port.public_capability(capability: "environment", topic:, entities:, context:, locale:)
          end
          SourceRead.new(source_checker: collector, organization:).call(topic:, context:, locale:, entities:)
        end

        def warning_metadata
          { "kind" => "official_warning", "starts_at" => "2040-09-09T00:00:00+02:00", "ends_at" => "2040-09-10T00:00:00+02:00",
            "source_published_at" => "2040-09-08T12:00:00+02:00", "affected_area_text" => "Izmišljena regija",
            "geographic_status" => "source_declared_region", "review_required" => true, "provider_severity" => "Moderate", "provider_area_code" => "TEST-REGION" }
        end

        def water_metadata(station:, observed_at:)
          { "kind" => "water_level_observation", "authority" => "secondary_aggregator",
            "readings" => [{ "station" => station, "value" => 23, "unit" => "cm", "observed_at" => observed_at }] }
        end

        def notice(key, metadata:, fingerprint: "1", bind_review: true)
          source = CityServiceSources.fetch(key)
          metadata = metadata.merge(@weather_review.metadata) if key == "weather_warnings" && bind_review
          CityServiceNoticeCollector::Notice.new(source_key: key, title: "Public source", body: "Public data", provider: source[:provider],
                                                 url: source[:source_url], fingerprint:, fetched_at: @now, metadata:)
        end
      end
    end
  end
end
