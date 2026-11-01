# frozen_string_literal: true

require "json"
require "digest"

module DecidimApp
  module Bijeljina
    # Public reference geometry is prepared at import; citizen queries stay transient.
    class LocalStreetRegistry
      DATA_PATH = Rails.root.join("db/geo/bijeljina_street_index.geojson")
      MUNICIPAL_PATH = Rails.root.join("db/geo/bijeljina_municipal_street_index.geojson")
      GIS_STREETS_PATH = Rails.root.join("db/geo/bijeljina_gis_streets.geojson")
      GIS_ROADS_PATH = Rails.root.join("db/geo/bijeljina_gis_roads.geojson")
      GIS_PLACES_PATH = Rails.root.join("db/geo/bijeljina_gis_places.geojson")
      VERIFIED_PATH = Rails.root.join("db/geo/bijeljina_service_streets.geojson")
      PLACES_PATH = Rails.root.join("db/geo/bijeljina_place_index.geojson")
      VERSION = "local-streets-v1"

      def initialize(organization:, data: nil, areas: nil, cache: Rails.cache)
        @organization = organization
        @data = data || self.class.dataset
        @name_index = data ? self.class.index(data) : self.class.name_index
        @areas = areas&.select { |area| area.boundary.is_a?(Hash) && %w(Polygon MultiPolygon).include?(area.boundary["type"]) }
        @cache = cache
      end

      def self.dataset
        paths = [DATA_PATH, MUNICIPAL_PATH, GIS_STREETS_PATH, GIS_ROADS_PATH, VERIFIED_PATH].select(&:file?)
        stamp = paths.map { |path| [path.to_s, path.mtime.to_f, path.size] }
        if @stamp != stamp
          combined = { "features" => [], "boundary_sets" => {} }
          paths.each do |path|
            data = JSON.parse(path.read)
            features = data.fetch("features", [])
            features.each { |feature| feature.fetch("properties")["verified_override"] = true } if path == VERIFIED_PATH
            features.each { |feature| feature.fetch("properties")["municipal_geometry"] = true } if path == GIS_STREETS_PATH
            bind_source_boundaries(combined, features, data.fetch("boundary_sha256", {}))
            combined["features"].concat(features)
          end
          @dataset = combined
          @name_index = nil
          @stamp = stamp
        end
        @dataset
      end

      def self.bind_source_boundaries(combined, features, boundaries)
        boundary_revision = Digest::SHA256.hexdigest(boundaries.sort.to_json)
        combined["boundary_sets"][boundary_revision] = boundaries
        features.each { |feature| feature.fetch("properties")["prepared_boundary_revision"] = boundary_revision }
      end

      def self.name_index
        @name_index ||= index(dataset)
      end

      def self.index(data)
        data.fetch("features", []).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |feature, index|
          properties = feature.fetch("properties")
          [properties["name"], *Array(properties["aliases"])].uniq.each do |name|
            key = PlaceAliasRegistry.normalize(name).sub(/\A(?:ulica|ulice|ulici|ulicu|ul)\s+/, "")
            index[key] << feature unless index[key].include?(feature)
          end
        end
      end

      def search(query:)
        name, settlement = search_terms(query)
        return [] if name.blank? || name.length > 240

        matching_features(name, settlement).map { |feature| candidate(feature) }
      end

      def place_search(query:)
        normalized = normalize(query)
        [GIS_PLACES_PATH, PLACES_PATH].each do |path|
          next unless path.file?

          data = @cache.fetch([VERSION, "places", path.to_s, path.mtime.to_f, path.size], expires_in: 30.days) { JSON.parse(path.read) }
          matches = data.fetch("features", []).filter_map { |feature| place_candidate(feature, normalized) }
          return matches if matches.any?
        end
        []
      end

      def coverage(name:, settlement:)
        features = matching_features(normalize(name), normalize(settlement))
        return [] if features.empty?

        # Distinct localities and unqualified components remain alternatives.
        return [] if ambiguous_coverage_locality?(features, settlement)

        features.flat_map do |feature|
          properties = feature.fetch("properties")
          intersected_areas(feature).map do |area|
            { "slug" => area.slug, "kind" => area.kind, "relation" => "possible_overlap", "evidence" => [name, settlement].compact.join(", "),
              "source" => "local_street_geometry", "source_url" => properties["source_url"], "source_object_ids" => properties["source_object_ids"],
              "retrieved_at" => properties["retrieved_at"], "source_type" => properties["source_type"],
              "precision" => properties["precision"], "geometry_complete" => properties["geometry_complete"] == true }
              .merge(properties.slice("source_snapshot_sha256", "source_exported_on", "source_layer", "source_file", "source_timestamp", "completeness_scope"))
          end
        end.uniq
      end

      private

      def search_terms(query)
        parts = query.to_s.split(",").map(&:strip)
        country = normalize(parts.last)
        parts.pop if parts.size > 1 && ["bih", "bosna i hercegovina", "bosnia and herzegovina"].include?(country)
        [normalize(parts.shift), normalize(parts.join(","))]
      end

      def normalize(value)
        PlaceAliasRegistry.normalize(value).sub(/\A(?:ulica|ulice|ulici|ulicu|ul)\s+/, "")
      end

      def matching_features(name, settlement)
        matches = @name_index.fetch(name, []).select { |feature| feature_matches?(feature, settlement) }
        exact = matches.select { |feature| normalize(feature.dig("properties", "settlement")) == settlement }
        matches = exact if settlement.present? && exact.any?
        prefer_line_evidence(matches)
      end

      def prefer_line_evidence(matches)
        line_settlements = matches.select { |feature| complete_line?(feature) }
                                  .map { |feature| normalize(feature.dig("properties", "settlement")) }.compact_blank
        matches.reject do |feature|
          %w(Point MultiPoint).include?(feature.dig("geometry", "type")) && line_settlements.include?(normalize(feature.dig("properties", "settlement")))
        end
      end

      def complete_line?(feature)
        feature.dig("properties", "geometry_complete") == true && %w(LineString MultiLineString).include?(feature.dig("geometry", "type"))
      end

      def ambiguous_coverage_locality?(features, settlement)
        localities = features.map { |feature| normalize(feature.dig("properties", "settlement")) }.uniq
        (features.size > 1 && localities.include?("")) || (settlement.blank? && localities.size > 1)
      end

      def feature_matches?(feature, settlement)
        properties = feature.fetch("properties")
        return true if settlement.blank?

        known_settlement = normalize(properties["settlement"])
        known_settlement == settlement || (known_settlement.blank? && settlement == "bijeljina")
      end

      def candidate(feature)
        properties = feature.fetch("properties")
        matched = intersected_areas(feature)
        { name: properties.fetch("name"), settlement: properties["settlement"],
          komsiluk_slugs: matched.select { |area| area.kind == "komsiluk" }.map(&:slug),
          mz_slugs: matched.select { |area| area.kind == "mz" }.map(&:slug), source: properties["source_url"],
          complete: properties["geometry_complete"] == true, precision: properties.fetch("precision", "street"),
          lon: representative_point(feature)[0], lat: representative_point(feature)[1] }
      end

      def representative_point(feature)
        return feature.dig("properties", "representative_point") if feature.dig("properties", "representative_point")

        coordinates = feature.fetch("geometry").fetch("coordinates")
        %w(LineString MultiPoint).include?(feature.dig("geometry", "type")) ? coordinates.first : coordinates.first.first
      end

      def place_candidate(feature, normalized)
        properties = feature.fetch("properties")
        return unless [properties["name"], *Array(properties["aliases"])].any? { |name| normalize(name) == normalized }

        point = properties["representative_point"] || (feature.fetch("geometry")["coordinates"] if feature.dig("geometry", "type") == "Point")
        return unless point.is_a?(Array) && point.size == 2

        { label: properties.fetch("name"), lon: point[0], lat: point[1], precision: "place", source: "local_place", requires_map_confirmation: true }
      end

      def intersected_areas(feature)
        geometry = feature.fetch("geometry")
        properties = feature.fetch("properties")
        versions = boundary_versions
        slugs = if prepared_intersections_valid?(feature)
                  properties.fetch("area_slugs")
                else
                  key = [VERSION, @organization.id, boundary_digest(geometry), Digest::SHA256.hexdigest(versions.sort.to_json)]
                  @cache.fetch(key, expires_in: 30.days) do
                    intersection = CityServiceStreetIntersection.new
                    areas.select { |area| intersects?(geometry, area.boundary, intersection) }.map(&:slug)
                  end
                end
        areas.select { |area| slugs.include?(area.slug) }
      end

      def boundary_versions
        @boundary_versions ||= areas.to_h { |area| [area.slug, boundary_digest(area.boundary)] }
      end

      def prepared_intersections_valid?(feature)
        properties = feature.fetch("properties")
        properties["area_slugs"].is_a?(Array) && properties["geometry_sha256"] == boundary_digest(feature.fetch("geometry")) &&
          boundary_versions.all? { |slug, digest| digest == prepared_boundaries(feature)[slug] }
      end

      def prepared_boundaries(feature)
        revision = feature.dig("properties", "prepared_boundary_revision")
        return @data.fetch("boundary_sets", {}).fetch(revision, {}) if revision

        @data.fetch("boundary_sha256", {})
      end

      def intersects?(geometry, boundary, intersection)
        return intersection.intersects?(geometry, boundary) unless geometry["type"] == "MultiPoint"

        locator = Decidim::Bih::Geo::AreaLocator.new
        geometry.fetch("coordinates").any? { |point| locator.point_in_geom?(*point, boundary) }
      end

      def boundary_digest(geometry)
        Digest::SHA256.hexdigest("#{geometry.fetch("type")}|#{geometry.fetch("coordinates").to_json}")
      end

      def areas
        @areas ||= Decidim::Bih::LocalArea.where(organization: @organization, kind: %w(mz komsiluk)).where.not(boundary: nil).select do |area|
          area.boundary.is_a?(Hash) && %w(Polygon MultiPolygon).include?(area.boundary["type"])
        end
      end
    end
  end
end
