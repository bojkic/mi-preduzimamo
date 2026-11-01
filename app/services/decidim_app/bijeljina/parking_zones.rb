# frozen_string_literal: true

require "date"
require "json"

module DecidimApp
  module Bijeljina
    # Host-owned parking-zone street lookup for Bijeljina.
    #
    # The production path reads from decidim_app_parking_zone_streets, seeded by
    # the migration from the official Parking servis page/map. The bundled rows
    # keep test/schema-load environments and readiness checks useful before the
    # seed data is present.
    module ParkingZones
      CONFIG_PATH = ENV["MI_PARKING_DATA_PATH"].to_s.freeze
      CONFIG = (CONFIG_PATH.empty? ? {} : JSON.parse(File.read(CONFIG_PATH))).freeze
      SOURCE_URL = CONFIG.fetch("source_url", "").freeze
      SOURCE_MAP_URL = CONFIG.fetch("source_map_url", "").freeze
      SOURCE_CAPTURED_ON = Date.iso8601(CONFIG.fetch("source_checked_on", "1970-01-01"))
      TARIFF_VERIFIED_ON = Date.iso8601(CONFIG.fetch("tariff_checked_on", "1970-01-01"))
      TARIFF_AMOUNTS = CONFIG.fetch("tariffs", {}).transform_values { |value| value.transform_keys(&:to_sym).freeze }.freeze
      MONTHLY_FENING = CONFIG.fetch("monthly_fening", {}).transform_keys(&:to_sym).freeze
      TARIFFS = TARIFF_AMOUNTS.transform_values do |value|
        rendered = value.merge(hourly: "#{format("%.2f", value.fetch(:hourly_fening) / 100.0).tr(".", ",")} KM/h")
        rendered[:daily_price] = "#{format("%.2f", value.fetch(:daily_fening) / 100.0).tr(".", ",")} KM" if value[:daily_fening]
        rendered.freeze
      end.freeze

      RAW_STREET_ROWS = CONFIG.fetch("street_rows", []).freeze

      BUNDLED_STREET_ROWS = RAW_STREET_ROWS.map do |street_name, normalized_street_name, aliases, zone, segment_note|
        {
          street_name:,
          normalized_street_name:,
          aliases:,
          zone:,
          segment_note:
        }
      end.freeze

      class << self
        def payment_description
          return "Podaci o parking tarifama nisu podešeni." if TARIFFS.empty?
          parts = TARIFFS.values.map do |tariff|
            "#{tariff.fetch(:label)} #{tariff.fetch(:sms)} (#{tariff.fetch(:hourly)})"
          end
          daily = TARIFFS["blue"]
          return "Plaćanje SMS-om: #{parts.join(", ")}." unless daily && daily[:daily_sms]
          "Plaćanje SMS-om: #{parts.join(", ")}; dnevna karta za plavu zonu #{daily.fetch(:daily_sms)} (#{daily.fetch(:daily_price)})."
        end

        def monthly_description
          return "Mjesečne parking tarife nisu podešene." if MONTHLY_FENING.empty?
          "Univerzalna mjesečna karta za crvenu i plavu zonu je #{MONTHLY_FENING.fetch(:red_and_blue) / 100} KM, " \
            "a mjesečna karta za plavu zonu #{MONTHLY_FENING.fetch(:blue) / 100} KM."
        end

        def default
          @default ||= Lookup.new
        end

        def reset!
          @default = nil
        end

        def source_url
          SOURCE_URL
        end

        def map_url
          SOURCE_MAP_URL
        end

        def street_count
          default.streets.size
        end

        def coverage_detail
          zones = default.streets.group_by { |street| street.fetch(:zone) }
                         .transform_values(&:size)
                         .slice("white", "red", "blue")
                         .map { |zone, count| "#{zone}=#{count}" }
                         .join(" ")
          "streets=#{street_count} zones=#{zones} source=official_parking_service_map"
        end

        def normalize(value)
          Decidim::Bih::Text.fold(value.to_s)
                            .gsub(/[^a-z0-9]+/, " ")
                            .squish
        end

        # Nominative guesses for a declined street name ("sa Karađorđeve" →
        # "karadordeva", "u Nušićevoj" → "nusiceva"); normalized, original first.
        def name_forms(value)
          folded = normalize(value)
          return [] if folded.blank?

          [folded, folded.sub(/e\z/, "a"), folded.sub(/u\z/, "a"), folded.sub(/i\z/, "a"), folded.sub(/(?:om|oj)\z/, "a"),
           folded.sub(/(?:og|eg|em)\z/, "i")].uniq
        end

        def seed_defaults!
          return false if BUNDLED_STREET_ROWS.empty?
          return false unless table_available?

          now = Time.current
          rows = BUNDLED_STREET_ROWS.map do |row|
            row.merge(
              source_url: SOURCE_URL,
              source_map_url: SOURCE_MAP_URL,
              source_checked_on: SOURCE_CAPTURED_ON,
              active: true,
              created_at: now,
              updated_at: now
            )
          end
          # Static public rows; upsert keeps operator reseeds idempotent.
          # rubocop:disable Rails/SkipsModelValidations
          ParkingZoneStreet.upsert_all(rows, unique_by: "idx_app_parking_zone_streets_normalized")
          # rubocop:enable Rails/SkipsModelValidations
          reset!
          true
        end

        def table_available?
          return false unless defined?(ParkingZoneStreet)

          ParkingZoneStreet.connection.data_source_exists?(ParkingZoneStreet.table_name)
        rescue StandardError
          false
        end
      end

      class Lookup
        LOCATION_QUESTION_PHRASES = [
          "ovdje",
          "ovde",
          "ovoj lokacij",
          "ovu lokacij",
          "ova lokacij",
          "kojoj sam",
          "parking zoni",
          "parking zonu",
          "trenutn",
          "tu"
        ].freeze

        def streets
          @streets ||= database_streets.presence || bundled_streets
        end

        def lookup(text)
          return nil if TARIFFS.empty?
          query = ParkingZones.normalize(text)
          return nil if query.blank?

          streets.find { |street| street_matches?(street, query) }
        end

        def answer(text:, locale: I18n.locale, location: nil)
          return nil if TARIFFS.empty?
          response =
            if (street = lookup(text))
              street_answer(street)
            elsif location.present? && location_question?(text)
              location_limited_answer
            elsif tariff_intent?(text)
              tariff_answer
            elsif street_question?(text)
              unknown_street_answer
            else
              overview_answer
            end

          localize(response, locale:)
        end

        # A citizen's declined street name ("u Nušićevoj", "sa Karađorđeve")
        # matched against the reviewed rows; only whole-word forms count.
        def lookup_named(value)
          ParkingZones.name_forms(value).lazy.filter_map { |form| lookup(form) }.first
        end

        # The reviewed zone facts for one street, without the source sentence:
        # the typed read adapter emits provenance separately (and outside
        # prose transliteration, so the URLs survive Cyrillic).
        def street_summary(street)
          zone = street.fetch(:zone)
          tariff = TARIFFS.fetch(zone)
          [
            "Za #{street.fetch(:segment_note)} u ulici #{street.fetch(:street_name)} imam oznaku: #{tariff.fetch(:label)}.",
            "Plaćanje SMS-om: #{tariff.fetch(:sms)} (#{tariff.fetch(:hourly)})#{daily_clause(tariff)}.",
            "Ovaj podatak ne potvrđuje istu zonu za cijelu ulicu.",
            "Uvijek provjeri znak zone na tačnom parking-mjestu."
          ].join(" ")
        end

        private

        def database_streets
          return [] unless ParkingZones.table_available?

          ParkingZoneStreet.active.order(:street_name).map do |row|
            row_to_hash(row)
          end
        rescue ActiveRecord::StatementInvalid
          []
        end

        def bundled_streets
          BUNDLED_STREET_ROWS.map do |row|
            row.merge(
              source_url: SOURCE_URL,
              source_map_url: SOURCE_MAP_URL,
              source_checked_on: SOURCE_CAPTURED_ON,
              active: true
            )
          end
        end

        def row_to_hash(row)
          {
            street_name: row.street_name,
            normalized_street_name: row.normalized_street_name,
            aliases: Array(row.aliases),
            zone: row.zone,
            segment_note: row.segment_note,
            source_url: row.source_url,
            source_map_url: row.source_map_url,
            source_checked_on: row.source_checked_on,
            active: row.active
          }
        end

        def street_matches?(street, query)
          aliases_for(street).any? { |candidate| query.include?(candidate) }
        end

        def aliases_for(street)
          ([street.fetch(:normalized_street_name)] + Array(street[:aliases]))
            .map { |value| ParkingZones.normalize(value) }
            .compact_blank
            .uniq
        end

        def street_answer(street)
          [street_summary(street), source_sentence(street)].join(" ")
        end

        def tariff_answer
          [
            "Cijene parkiranja po zoni: #{tariff_list}.",
            ParkingZones.monthly_description,
            source_sentence
          ].join(" ")
        end

        def unknown_street_answer
          [
            "Tu ulicu još nemam u strukturiranom pregledu parking zona.",
            "Pošalji tačan naziv ulice ili provjeri znak zone na parking-mjestu.",
            source_sentence
          ].join(" ")
        end

        def location_limited_answer
          [
            "Za ovu lokaciju ne mogu pouzdano odrediti parking zonu samo iz koordinata, jer trenutno imam službeni pregled po ulicama i segmentima mape.",
            "Pošalji naziv ulice ili provjeri znak na parking-mjestu; tada mogu izdvojiti tačan SMS broj i cijenu.",
            "Cijene po zonama su: #{tariff_list}.",
            source_sentence
          ].join(" ")
        end

        def overview_answer
          [
            "Imam strukturirani pregled parking zona za #{streets.size} ulica iz službene mape Parking servisa.",
            "Primjeri: #{zone_examples}.",
            "Pošalji naziv ulice da izdvojim zonu, SMS broj i cijenu.",
            source_sentence
          ].join(" ")
        end

        def tariff_list
          TARIFFS.values.map do |tariff|
            "#{tariff.fetch(:label)}: SMS #{tariff.fetch(:sms)}, #{tariff.fetch(:hourly)}#{daily_clause(tariff, prefix: "; dnevna karta ")}"
          end.join("; ")
        end

        def zone_examples
          TARIFFS.keys.map do |zone|
            examples = streets.select { |street| street.fetch(:zone) == zone }
                              .first(3)
                              .map { |street| street.fetch(:street_name) }
                              .join(", ")
            "#{TARIFFS.fetch(zone).fetch(:label)}: #{examples}"
          end.join("; ")
        end

        def daily_clause(tariff, prefix: "; dnevna karta za plavu zonu: ")
          return "" if tariff[:daily_sms].blank?

          "#{prefix}SMS #{tariff.fetch(:daily_sms)} (#{tariff.fetch(:daily_price)})"
        end

        def source_sentence(street = nil)
          checked_on = (street && street[:source_checked_on]) || SOURCE_CAPTURED_ON
          "Izvor: #{SOURCE_URL}; mapa: #{SOURCE_MAP_URL}; provjereno #{checked_on.strftime("%d.%m.%Y")}."
        end

        def tariff_intent?(text)
          folded = ParkingZones.normalize(text)
          %w(cijena cena kosta koliko karta karte placanje placam platim sms).any? do |keyword|
            folded.include?(keyword)
          end
        end

        def street_question?(text)
          folded = ParkingZones.normalize(text)
          folded.include?("ulic") ||
            folded.include?("zona") ||
            folded.include?("zone") ||
            folded.include?("zoni") ||
            folded.include?("zonu")
        end

        def location_question?(text)
          folded = ParkingZones.normalize(text)
          LOCATION_QUESTION_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def localize(text, locale:)
          return text unless locale.to_s == "sr-Cyrl"

          Decidim::Bih::Transliterator.call(text)
        end
      end
    end
  end
end
