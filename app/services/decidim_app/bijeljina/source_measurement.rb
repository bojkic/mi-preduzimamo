# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # One public measurement policy shared by typed and legacy channel readers.
    # No actor context is synthesized and no source lookup/fetch is performed.
    module SourceMeasurement
      MAX_AGES = { "air_quality_realtime" => 8.hours, "water_levels" => 24.hours }.freeze
      IDENTITY_FIELDS = %w(station_id source_clock upstream_authority clock_evidence_url datum vertical_datum gauge_zero_source_value quality_flags).freeze

      class << self
        def conflicting_observations(rows)
          known = rows.select { |row| row["observed_at"].present? && row["station"].present? }
          known.group_by { |row| observation_identity(row) }.each_value do |group|
            different = group.find { |row| row["value"] != group.first["value"] }
            return [group.first, different] if different
          end
          []
        end

        def observations(notice:, now:)
          metadata = notice.respond_to?(:metadata) && notice.metadata.is_a?(Hash) ? notice.metadata.deep_stringify_keys : {}
          rows = notice.source_key == "water_levels" ? Array(metadata["readings"]).map { |row| metadata.merge(row).merge("kind" => "water_level_observation") } : [metadata]
          rows.filter_map { |row| call(metadata: row, source_key: notice.source_key, now:) }
        end

        def call(metadata:, source_key:, now:)
          return unless valid_measurement?(metadata, source_key)

          station = metadata["station"].presence || "Bijeljina (Klimerko javni prikaz)"
          observed_at = parse_observed_at(metadata["observed_at"])
          future = observed_at ? observed_at > now : false
          stale = observed_at ? observed_at < now - MAX_AGES.fetch(source_key) : false
          authority, scope = source_key == "water_levels" ? %w(secondary_aggregator river_station) : %w(community_sensor community_city_marker)
          {
            "kind" => metadata.fetch("kind", "measurement"), "text" => measurement_text(metadata, source_key, station, observed_at),
            "value" => metadata["value"], "unit" => metadata["unit"], "station" => station, "pollutant" => metadata["pollutant"],
            "observed_at" => observed_at&.iso8601,
            "observation_time_text" => observed_at ? metadata["observation_time_text"].to_s[0, 160] : nil,
            "source_time_text" => metadata["observation_time_text"].to_s[0, 160],
            "source_time_role" => observed_at ? "verified_observation_clock" : "unverified_display_clock_not_measurement_time",
            "authority" => authority, "coverage" => { "scope" => scope, "station" => station, "area_ids" => [] },
            "coordinates" => marker_coordinates(metadata), "warning_codes" => measurement_warnings(observed_at, future, stale),
            "_stale" => stale, "_future" => future
          }.merge(metadata.slice(*IDENTITY_FIELDS)).compact
        end

        private

        def observation_identity(row)
          [row["station_id"].presence || row["station"], *row.values_at("kind", "pollutant", "unit", "observed_at", "datum", "vertical_datum", "gauge_zero_source_value")]
        end

        def valid_measurement?(metadata, source_key)
          value = metadata["value"]
          return false unless value.is_a?(Numeric) && value.finite?

          expected_unit = { "water_levels" => "cm", "air_quality_realtime" => "µg/m³" }[source_key]
          return false unless expected_unit && metadata["unit"] == expected_unit
          return metadata["station"].present? if source_key == "water_levels"

          !value.negative? && %w(PM1 PM2.5 PM10).include?(metadata["pollutant"])
        end

        def measurement_warnings(observed_at, future, stale)
          warnings = %w(measurement_time_not_fetch_time source_observation_not_area_status)
          warnings << "measurement_time_unknown" unless observed_at
          warnings << "measurement_time_in_future" if future
          warnings << "measurement_stale" if stale
          warnings
        end

        def measurement_text(metadata, source_key, station, observed_at)
          descriptor = source_key == "water_levels" ? "Vodostaj na stanici #{station}" : "#{station}, #{metadata["pollutant"]}"
          time_text = if observed_at
                        "Vrijeme mjerenja: #{observed_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. %H:%M")}."
                      else
                        "Vrijeme mjerenja nije pouzdano navedeno; svježina ovog očitanja nije potvrđena."
                      end
          authority_text = if source_key == "water_levels"
                             "Podatak prenosi lokalni javni agregator; nije procjena opasnosti od poplave za vaše naselje."
                           else
                             "Podatak je iz zajedničkog Klimerko prikaza, nije službeno mjerenje niti opis stanja u svakom komšiluku."
                           end
          "#{descriptor}: #{metadata["value"]} #{metadata["unit"]}. #{time_text} #{authority_text}"
        end

        def marker_coordinates(metadata)
          lat = metadata["latitude"]
          lon = metadata["longitude"]
          return unless lat.is_a?(Numeric) && lon.is_a?(Numeric) && (-90..90).cover?(lat) && (-180..180).cover?(lon)

          { "latitude" => lat, "longitude" => lon, "role" => "source_map_marker_not_verified_sensor_location" }
        end

        def parse_observed_at(value)
          Time.iso8601(value) if value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
