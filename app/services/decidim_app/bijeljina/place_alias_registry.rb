# frozen_string_literal: true

require "yaml"
require "digest"

module DecidimApp
  module Bijeljina
    # One tenant-scoped name index for ingestion and citizen lookup. A name is
    # evidence of identity, never evidence that a utility serves an entire area.
    class PlaceAliasRegistry
      CONFIG_PATH = ENV.fetch("MI_PLACE_ALIASES_PATH", "").freeze
      Entry = Struct.new(:id, :kind, :slug, :label, :aliases, :area, :source, :properties, keyword_init: true)
      Mention = Struct.new(:entry, :token, :start, :finish, keyword_init: true)
      Resolution = Struct.new(:status, :places, :warning, :revision, keyword_init: true)
      # The registry marker for a not-yet-confirmed komšiluk ("Janja
      # (prijedlog)") is operator vocabulary; a citizen only ever sees "Janja".
      PROPOSAL_MARKER = /\s*(?:\((?:prijedlog|predlog|приједлог|предлог)\)|(?:prijedlog|приједлог|predlog|предлог))\s*\z/i

      def self.display_name(value)
        value.to_s.sub(PROPOSAL_MARKER, "").strip
      end

      def initialize(areas:, config: nil)
        @areas = areas
        @config = config || (CONFIG_PATH.empty? ? { "revision" => "unconfigured", "inflections" => {} } : YAML.safe_load_file(CONFIG_PATH, aliases: false))
      end

      def revision
        @config.fetch("revision")
      end

      def entries(kinds: %w(mz komsiluk))
        requested = Array(kinds).map(&:to_s)
        result = area_entries.select { |entry| requested.include?(entry.kind) }
        result += reference_entries.select { |entry| requested.include?(entry.kind) } if requested.intersect?(%w(street street_segment facility))
        result
      end

      def resolve(query:, kind: nil)
        kinds = kind ? [kind] : %w(mz komsiluk)
        mentions = mentions(query, kinds:)
        places = mentions.map(&:entry).uniq(&:id)
        status = places.empty? ? :unknown : :ambiguous
        status = :ok if places.one?
        Resolution.new(status:, places:, warning: { unknown: "place_not_reviewed", ambiguous: "place_name_ambiguous" }[status], revision:)
      end

      # Keep the longest name *at each span*, not just the longest name anywhere
      # in the sentence. Equal spans keep every candidate for explicit ambiguity.
      # Span precedence and kind compatibility are reviewed together to preserve equal-span ambiguity.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def mentions(text, kinds: %w(mz komsiluk))
        normalized = self.class.normalize(text)
        requested = Array(kinds).map(&:to_s)
        found = entries(kinds: (requested | %w(mz komsiluk))).flat_map do |entry|
          entry.aliases.flat_map do |token|
            normalized.to_enum(:scan, /(?<![a-z0-9])#{Regexp.escape(token)}(?![a-z0-9])/).map do
              match = Regexp.last_match
              prefix_kind = kind_before(normalized[0...match.begin(0)])
              next if prefix_kind && prefix_kind != entry.kind && !(prefix_kind == "street" && entry.kind == "street_segment")

              Mention.new(entry:, token:, start: match.begin(0), finish: match.end(0))
            end
          end
        end
        found.compact!
        longest = found.reject do |mention|
          found.any? do |other|
            other.start <= mention.start && other.finish >= mention.finish && other.finish - other.start > mention.finish - mention.start
          end
        end
        longest.select { |mention| requested.include?(mention.entry.kind) }.uniq { |mention| [mention.entry.id, mention.start, mention.finish] }
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def self.normalize(value)
        Decidim::Bih::Text.fold(value.to_s).gsub(/[^a-z0-9]+/, " ").strip.gsub(/\s+/, " ")
      end

      private

      def kind_before(prefix)
        return "street" if prefix.match?(/\b(?:ulic[aeiu]|ul)\s+(?:mz\s+)?\z/)
        return "feeder" if prefix.match?(/\b(?:dalekovod|dv|trafostanica|ts|izvod|feeder)\s+\z/)
        return "settlement" if prefix.match?(/\b(?:naselje|naselju)\s+\z/)
        return "mz" if prefix.match?(/\b(?:mz|mjesna zajednica|mesna zajednica)\s+\z/)

        "komsiluk" if prefix.match?(/\bkomsiluk\s+\z/)
      end

      # Build each canonical identity and its reviewed name variants together without inventing crosswalks.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def area_entries
        @area_entries ||= @areas.map do |area|
          labels = [area.translated_name, area.name.is_a?(Hash) ? area.name.values : nil].flatten.compact
          direct = [area.slug.to_s.tr("-", " "), *labels].map { |label| self.class.normalize(label) }
          bare = labels.map { |label| bare_name(label) }.reject(&:empty?)
          variants = bare.flat_map { |name| [name, *@config.fetch("inflections", {}).fetch(name, [])] }
          qualifier = area.kind == "mz" ? ["mz", "mjesna zajednica", "mesna zajednica"] : ["komsiluk"]
          aliases = direct + variants + variants.flat_map { |name| qualifier.map { |prefix| "#{prefix} #{name}" } }
          Entry.new(id: area.slug, kind: area.kind, slug: area.slug, label: self.class.display_name(area.translated_name),
                    aliases: aliases.map { |name| self.class.normalize(name) }.reject { |name| name.length < 3 }.uniq,
                    area:, source: "local_area_registry", properties: { "alias_revision" => revision, "reviewed_on" => @config["reviewed_on"] })
        end
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def bare_name(value)
        self.class.normalize(value).sub(/\A(?:mz|mjesna zajednica|mesna zajednica|komsiluk)\s+/, "")
            .sub(/\s+prijedlog\z/, "")
      end

      # Import existing domain references, without claiming a street/stop-to-MZ
      # crosswalk. Parking segments remain segments; assumed stop points remain
      # assumed. These entries are opt-in through a typed reference lookup.
      def reference_entries
        @reference_entries ||= parking_entries + transport_entries
      end

      def parking_entries
        require_relative "parking_zones"
        ParkingZones.default.streets.map do |row|
          names = [row.fetch(:street_name), *row.fetch(:aliases)]
          Entry.new(id: "parking_segment:#{row.fetch(:normalized_street_name).tr(" ", "-")}", kind: "street_segment",
                    label: row.fetch(:street_name), aliases: names.flat_map { |name| [name, "ulica #{name}", "ul #{name}"] }.map { |name| self.class.normalize(name) }.uniq,
                    source: row.fetch(:source_url),
                    properties: { "relation" => "part", "segment_note" => row.fetch(:segment_note), "area_slugs" => [],
                                  "geographic_crosswalk" => "unknown", "reviewed_on" => row.fetch(:source_checked_on)&.iso8601 })
        end
      end

      def transport_entries
        path = ENV.fetch("MI_TRANSPORT_STOPS_PATH", "")
        return [] if path.empty?

        YAML.safe_load_file(path, aliases: false).fetch("stops").map do |row|
          name = row.fetch("label")
          Entry.new(id: "transport_stop:#{Digest::SHA256.hexdigest(name)[0, 16]}", kind: "facility", label: name,
                    aliases: [name, *Array(row["aliases"])].map { |value| self.class.normalize(value) }.uniq,
                    source: row.fetch("source"), properties: row.slice("accuracy", "confidence", "latitude", "longitude", "same_as")
                                                                .merge("subtype" => "transport_stop", "area_slugs" => [], "geographic_crosswalk" => "unknown"))
        end
      end
    end
  end
end
