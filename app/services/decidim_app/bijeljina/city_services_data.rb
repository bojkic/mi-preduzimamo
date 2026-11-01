# frozen_string_literal: true

require "date"
require "json"
require_relative "parking_zones"
require_relative "directory_service_facts"

module DecidimApp
  module Bijeljina
    # Referentni ugovor za lokalni imenik; podaci dolaze iz konfiguracije zajednice.
    # Generičko rangiranje i pretraga ostaju u Decidim::Bih::City::ServiceDirectory.
    module CityServicesData
      CONFIG_PATH = ENV["MI_CITY_SERVICES_DATA_PATH"].to_s.freeze
      CONFIG = (CONFIG_PATH.empty? ? {} : JSON.parse(File.read(CONFIG_PATH), symbolize_names: true)).freeze
      SOURCE_VERIFIED_ON = Date.iso8601(CONFIG.fetch(:source_checked_on, "1970-01-01"))
      CONTACT_CARDS_CHECKED_ON = SOURCE_VERIFIED_ON
      CONTACT_CARD_KEYS = [].freeze
      PARKING_ANSWER_SECTIONS = CONFIG.fetch(:parking_answer_sections, {}).freeze
      TRANSPORT_ANSWER_SECTIONS = CONFIG.fetch(:transport_answer_sections, {}).freeze
      TRANSPORT_ANSWER_SOURCES = CONFIG.fetch(:transport_answer_sources, {}).freeze

      class << self
        def entry_facts(entry, checked_on:)
          atomic = DirectoryServiceFacts.all(entry.fetch(:key)) unless entry[:content_origin] == "admin_override"
          return atomic.map(&:freeze).freeze if atomic&.any?

          if entry.fetch(:key) == :parking
            return [] if ParkingZones::TARIFF_AMOUNTS.empty?
            [
              { id: "parking_tariffs", kind: "tariff", source_checked_on: ParkingZones::TARIFF_VERIFIED_ON.iso8601,
                source_url: ParkingZones::SOURCE_URL, currency: "BAM", tariffs: ParkingZones::TARIFF_AMOUNTS,
                monthly_fening: ParkingZones::MONTHLY_FENING },
              { id: "parking_map", kind: "street_segment_map", source_checked_on: ParkingZones::SOURCE_CAPTURED_ON.iso8601,
                source_url: ParkingZones::SOURCE_MAP_URL }
            ].map(&:freeze).freeze
          else
            [{ id: "service:#{entry.fetch(:key)}", kind: "service_guidance", source_checked_on: checked_on.iso8601,
               source_url: entry.fetch(:source_url), validity: "reviewed_source_guidance_not_live_service_status" }.freeze].freeze
          end
        end

        def coverage_detail(entry_count)
          reviewed_sources =
            if defined?(DecidimApp::Bijeljina::CityServiceSources)
              DecidimApp::Bijeljina::CityServiceSources.all.size
            else
              "unknown"
            end

          "entries=#{entry_count} reviewed_service_sources=#{reviewed_sources} " \
            "scope=expanded_static_faq_plus_reviewed_source_topics"
        end
      end

      ENTRIES = CONFIG.fetch(:entries, []).map do |entry|
        entry = entry.merge(key: entry.fetch(:key).to_sym)
        checked_on = Date.iso8601(entry.fetch(:source_checked_on))
        entry.merge(record_kind: "service_guidance", location_scope: "citywide",
                    verification_scope: "source_guidance", effective_from: nil, effective_until: nil,
                    facts: entry_facts(entry, checked_on:)).freeze
      end.freeze
    end
  end
end
