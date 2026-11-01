# frozen_string_literal: true

require "date"
require "json"
require "net/http"
require "time"
require "timeout"
require "uri"

module DecidimApp
  module Bijeljina
    # Internal, read-only comparison pilot. It never writes snapshots, creates
    # notices or advertises a public capability. A fetched measurement is not an
    # official forecast or an authorization to redistribute provider data.
    class SavaHisObservations
      ENDPOINT = "https://savahis.org/geoserver/savagis/ows?service=WFS&version=1.0.0&request=GetFeature&typeName=savagis:savahis_realtime_hydro_stations&outputFormat=application/json&maxFeatures=300"
      MAX_BYTES = 524_288
      MAX_FEATURES = 300
      TIMEOUT = 8
      USER_AGENT = "MilicaSourcePilot/1.0 (+https://mi.fondacijabijeljina.com)"
      UNIT_EVIDENCE_URL = "https://savahis.org/resources/i18n/en.js"
      # WFS european_wgst_code is stable; generated feature ids are not.
      STATIONS = {
        "RS45084" => ["Jamena", "Sava", "RHMZ Belgrad"],
        "RS45882" => ["Radalj", "Drina", "RHMZ Belgrad"],
        "RS45885" => ["Badovinci", "Drina", "RHMZ Belgrad"],
        "BARHMZRS102" => ["Rača", "Sava", "RHMZRS Banja Luka"]
      }.freeze
      PARAMETERS = { "waterlevel" => "cm", "flow" => "m3/s", "temperature" => "°C" }.freeze

      class InvalidResponse < StandardError; end

      def initialize(fetcher: nil, clock: -> { Time.now.utc }, max_age: 21_600)
        @fetcher = fetcher || method(:fetch)
        @clock = clock
        @max_age = max_age
      end

      def call
        parse(@fetcher.call(ENDPOINT), now: @clock.call)
      end

      def parse(body, now: @clock.call)
        raise InvalidResponse, "response_too_large" if body.bytesize > MAX_BYTES

        features = validated_features(JSON.parse(body))

        readings = features.flat_map { |feature| station_readings(feature, now) }
        duplicates = readings.group_by { |reading| [reading["station_id"], reading["parameter"]] }.values.select { |rows| rows.size > 1 }
        duplicates.flatten.each { |reading| reading["quality_flags"] << "duplicate_station_parameter" }
        {
          "source_key" => "sava_his_pilot", "source_url" => ENDPOINT, "checked_at" => now.utc.iso8601,
          "mode" => "internal_comparison", "public_answer_ready" => false,
          "cutover_status" => "requires_dataset_reuse_and_comparison_review",
          "features_received" => features.size, "possibly_truncated" => features.size == MAX_FEATURES,
          "missing_station_ids" => STATIONS.keys - readings.map { |reading| reading["station_id"] }.uniq,
          "readings" => readings
        }
      rescue JSON::ParserError
        raise InvalidResponse, "invalid_json"
      end

      private

      def validated_features(payload)
        raise InvalidResponse, "unexpected_feature_collection" unless payload.is_a?(Hash) && payload["type"] == "FeatureCollection"

        features = payload["features"]
        raise InvalidResponse, "unexpected_features" unless features.is_a?(Array)
        raise InvalidResponse, "feature_limit_exceeded" if features.size > MAX_FEATURES

        features
      end

      def fetch(url)
        uri = URI(url)
        body = +""
        Timeout.timeout(TIMEOUT) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
            http.request(Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT, "Accept" => "application/json")) do |response|
              raise InvalidResponse, "http_#{response.code}" unless response.is_a?(Net::HTTPSuccess)
              raise InvalidResponse, "unexpected_content_type" unless response["content-type"].to_s.downcase.include?("json")

              response.read_body do |chunk|
                raise InvalidResponse, "response_too_large" if body.bytesize + chunk.bytesize > MAX_BYTES

                body << chunk
              end
            end
          end
        end
        body
      end

      def station_readings(feature, now)
        raise InvalidResponse, "invalid_feature" unless feature.is_a?(Hash) && feature["type"] == "Feature" && feature["properties"].is_a?(Hash)

        properties = feature.fetch("properties")
        station_id = properties["european_wgst_code"]
        return [] unless STATIONS.has_key?(station_id)

        PARAMETERS.map do |parameter, unit|
          observation(properties, station_id, parameter, unit, now)
        end
      end

      def observation(properties, station_id, parameter, unit, now)
        raw_time = properties["#{parameter}_time"]
        observed_at = parse_time(raw_time)
        raw_value = properties[parameter]
        value = numeric_value(raw_value)
        flags = quality_flags(properties, station_id, value, unit) + temporal_flags(observed_at, now)
        {
          "station_id" => station_id, "station" => properties["station_name"], "river" => properties["river"],
          "upstream_authority" => properties["authority"], "distributor" => "International Sava River Basin Commission / Sava HIS",
          "parameter" => parameter, "value" => value, "source_value" => raw_value, "unit" => unit,
          "unit_evidence_url" => (UNIT_EVIDENCE_URL if unit),
          "observed_at" => observed_at&.utc&.iso8601, "observation_time_text" => raw_time,
          "source_clock" => ("explicit_iso8601_offset" if observed_at),
          "gauge_zero_source_value" => properties["gauge_zero"], "vertical_datum" => "unknown",
          "datum" => ("station_gauge_zero" if parameter == "waterlevel"),
          "source_flood_defence" => properties["flood_defence"], "quality_flags" => flags,
          "public_answer_ready" => false
        }
      end

      def quality_flags(properties, station_id, value, unit)
        flags = []
        flags << "station_identity_mismatch" unless STATIONS.fetch(station_id) == properties.values_at("station_name", "river", "authority")
        flags << "missing_or_invalid_value" if value.nil?
        flags << "unit_unverified" unless unit
        flags << "gauge_zero_unknown" if properties["gauge_zero"].nil?
        flags << "vertical_datum_unknown"
        flags
      end

      def temporal_flags(observed_at, now)
        return ["unknown_measurement_time"] unless observed_at

        flags = []
        flags << "future_measurement" if observed_at > now + 300
        flags << "stale_measurement" if now - observed_at > @max_age
        flags
      end

      def numeric_value(value)
        value if value.is_a?(Numeric) && value.finite?
      end

      def parse_time(value)
        return unless value.is_a?(String) && value.match?(/T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)

        Date.iso8601(value[0, 10])
        Time.iso8601(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
