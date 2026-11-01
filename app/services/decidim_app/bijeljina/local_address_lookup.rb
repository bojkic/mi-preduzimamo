# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Exact local names come before network geocoding. An MZ or a street offers
    # named neighbourhood choices, never a guessed household at its centre.
    class LocalAddressLookup
      def initialize(organization:)
        @organization = organization
        @areas = Decidim::Bih::LocalArea.where(organization:, kind: %w(mz komsiluk)).to_a
      end

      def call(query:)
        normalized = PlaceAliasRegistry.normalize(query)
        registry = PlaceAliasRegistry.new(areas: @areas)
        named = registry.entries.select { |entry| entry.aliases.include?(normalized) }
        return area_candidates(named) if named.any?

        streets = LocalStreetRegistry.new(organization: @organization, areas: @areas)
        candidates = street_candidates(streets.search(query:))
        return candidates if candidates.any?

        streets.place_search(query:).filter_map { |place| point_candidate(place) }
      end

      private

      def area_candidates(entries)
        candidates = entries.flat_map do |entry|
          matches = if entry.kind == "komsiluk"
                      [entry.area]
                    else
                      @areas.select { |area| area.kind == "komsiluk" && Array(area.overlapping_mz_slugs).include?(entry.slug) }
                    end
          matches.map { |area| candidate(area, entry.label, "local_area") }
        end
        candidates.uniq { |row| row.fetch(:komsiluk_id) }
      end

      def street_candidates(streets)
        candidates = streets.flat_map do |street|
          unless street.fetch(:complete)
            point = point_candidate(street.merge(label: [street.fetch(:name), street[:settlement]].compact.join(", "),
                                                 precision: "street_segment", source: "local_street"))
            next [point].compact
          end

          @areas.select { |area| area.kind == "komsiluk" && street.fetch(:komsiluk_slugs).include?(area.slug) }.map do |area|
            candidate(area, [street.fetch(:name), street[:settlement]].compact.join(", "), "local_street")
          end
        end
        candidates.uniq do |row|
          row.fetch(:requires_map_confirmation) ? [row.fetch(:label), row.fetch(:komsiluk_id), row[:lat], row[:lon]] : row.fetch(:komsiluk_id)
        end
      end

      def point_candidate(place)
        lat = Float(place.fetch(:lat))
        lon = Float(place.fetch(:lon))
        return unless lat.finite? && lon.finite? && lat.between?(-90, 90) && lon.between?(-180, 180)

        @locator ||= Decidim::Bih::Geo::AreaLocator.new
        located = @locator.resolve(lat:, lon:, organization: @organization)
        return unless located[:komsiluk]

        { label: place.fetch(:label), lat:, lon:, precision: place.fetch(:precision), source: place.fetch(:source),
          komsiluk_id: located[:komsiluk].id, komsiluk_name: located[:komsiluk].translated_name, requires_map_confirmation: true }
      rescue KeyError, ArgumentError, TypeError
        nil
      end

      def candidate(area, context, source)
        { label: "#{context} → #{area.translated_name}", komsiluk_id: area.id, komsiluk_name: area.translated_name,
          precision: "neighbourhood", source:, requires_map_confirmation: false }
      end
    end
  end
end
