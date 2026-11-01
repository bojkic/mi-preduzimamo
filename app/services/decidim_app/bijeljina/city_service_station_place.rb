# frozen_string_literal: true

require "digest"
require "json"
require "yaml"
require_relative "place_alias_registry"

module DecidimApp
  module Bijeljina
    # An explicit operator-approved placement rule for generic low-voltage
    # outputs. A uniquely named transformer station locates the notice on one
    # Komšiluk board and scopes an operator-requested phone audience there.
    # It does not claim which households are connected to that station.
    class CityServiceStationPlace
      GENERIC_OUTPUT = /\A(?:\d+|svi)\s+nn\s+izlaz(?:i|a)?\z/
      STATION_PREFIX = /\A(?:ts|cts|trafostanica)\s+/
      VOLTAGE_PREFIX = /\A(?:\d+\s*){1,3}kv\s+/
      # Explicit reviewed operator data; no inherited local station names.
      def self.load_reviewed_station_labels(path)
        return {}.freeze if path.to_s.empty?
        raise ArgumentError, "station label file too large" if File.size(path) > 1_048_576

        data = YAML.safe_load_file(path, aliases: false)
        labels = data.is_a?(Hash) && data["labels"]
        raise ArgumentError, "station labels must be a bounded mapping" unless labels.is_a?(Hash) && labels.size <= 1000

        labels.each_with_object({}) do |(key, value), result|
          unless [key, value].all? { |item| item.is_a?(String) && item.bytesize <= 256 && !item.strip.empty? }
            raise ArgumentError, "station labels must contain bounded text"
          end
          normalized_key = PlaceAliasRegistry.normalize(key)
          normalized_value = PlaceAliasRegistry.normalize(value)
          if normalized_key.empty? || normalized_value.empty? || result.has_key?(normalized_key)
            raise ArgumentError, "empty or duplicate normalized station label"
          end
          result[normalized_key] = normalized_value
        end.freeze
      end

      def self.reviewed_labels_version(labels)
        "station-place-configured-v4:#{Digest::SHA256.hexdigest(labels.sort.to_h.to_json)[0, 16]}"
      end

      REVIEWED_STATION_LABELS = load_reviewed_station_labels(ENV.fetch("MI_STATION_LABELS_PATH", ""))
      VERSION = reviewed_labels_version(REVIEWED_STATION_LABELS).freeze
      ABBREVIATIONS = {
        "d" => %w(donje donji donja),
        "g" => %w(gornje gornji gornja),
        "v" => %w(velika veliko veliki)
      }.freeze

      Result = Struct.new(:status, :slug, :name, :station_label, :normalized_label,
                          :alias_revision, :boundary_hash, :area_id, :candidate_slugs,
                          keyword_init: true) do
        def resolved?
          status == "resolved"
        end
      end

      def initialize(organization:)
        @organization = organization
      end

      def resolve(event, recheck: false)
        return result("not_applicable") unless candidate?(event, recheck:)

        raw_label = event.extraction_metadata.to_h["feeder"].to_s.squish
        normalized = PlaceAliasRegistry.normalize(raw_label)
        return result("unknown", station_label: raw_label) unless normalized.match?(STATION_PREFIX)

        label = normalized.sub(STATION_PREFIX, "").sub(VOLTAGE_PREFIX, "").squish
        # Terminal Centar can identify a station inside a named place.
        # Apply this before stripping its number: an unreviewed intermediate
        # suffix must never silently become a whole-place match.
        label = label.sub(/\s+(?:\d+\s+)?centar\z/, "") if label.include?(" ")
        label = label.sub(/(?:\s+\d+)+\z/, "")
        return result("unknown", station_label: raw_label, normalized_label: label) if label.blank? || label == "centar"

        queries = expanded_queries(REVIEWED_STATION_LABELS.fetch(label, label))
        areas = queries.flat_map { |query| matched_areas(query) }.uniq(&:id)
        if areas.empty? && label.match?(/\A[dgv]\s+/)
          # An abbreviated qualifier with no canonical qualified area can
          # fall back to a single unqualified place only when it is unique.
          areas = matched_areas(label.sub(/\A[dgv]\s+/, ""))
        end
        if areas.empty?
          mentioned = registry.mentions(label, kinds: ["komsiluk"]).map { |mention| mention.entry.area }.uniq(&:id)
          return result("ambiguous", station_label: raw_label, normalized_label: label,
                        candidate_slugs: mentioned.map(&:slug).sort) if mentioned.many?

          return result("unknown", station_label: raw_label, normalized_label: label)
        end
        return result("ambiguous", station_label: raw_label, normalized_label: label,
                      candidate_slugs: areas.map(&:slug).sort) unless areas.one?

        area = areas.first
        result("resolved", slug: area.slug, name: PlaceAliasRegistry.display_name(area.translated_name),
               station_label: raw_label, normalized_label: label, alias_revision: registry.revision,
               boundary_hash: Digest::SHA256.hexdigest(area.boundary.to_json), area_id: area.id,
               candidate_slugs: [area.slug])
      end

      private

      def result(status, **attributes)
        Result.new(**{ status:, candidate_slugs: [] }.merge(attributes))
      end

      def candidate?(event, recheck:)
        return false unless event.source_key == "electricity_outages"
        return false unless PlaceAliasRegistry.normalize(event.affected_text).match?(GENERIC_OUTPUT)

        metadata = event.extraction_metadata.to_h
        if recheck
          return metadata.dig("station_place", "source_content_version") == event.content_version
        end
        return false unless event.targeting_level == "unknown" && event.area_slugs.empty?

        extraction = metadata.fetch("coverage", {}).to_h
        Array(extraction["affected_places"]).empty? && Array(extraction["unresolved_places"]).empty? &&
          Array(extraction["ambiguous_places"]).empty?
      end

      def expanded_queries(label)
        abbreviation = label.match(/\A([dgv])\s+(.+)\z/)
        return [label] unless abbreviation

        ABBREVIATIONS.fetch(abbreviation[1]).flat_map do |qualifier|
          ["#{qualifier} #{abbreviation[2]}", "#{abbreviation[2]} #{qualifier}"]
        end.uniq
      end

      def matched_areas(query)
        normalized = PlaceAliasRegistry.normalize(query)
        registry.mentions(normalized, kinds: ["komsiluk"]).select do |mention|
          mention.start.zero? && mention.finish == normalized.length
        end.map { |mention| mention.entry.area }.uniq(&:id)
      end

      def registry
        @registry ||= PlaceAliasRegistry.new(areas: Decidim::Bih::LocalArea.where(organization: @organization, kind: "komsiluk").to_a)
      end
    end
  end
end
