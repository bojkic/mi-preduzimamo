# frozen_string_literal: true

require "json"
require "digest"
require "yaml"

module DecidimApp
  module Bijeljina
    # Exact source-named settlements can intersect several independent MZ and
    # komsiluk polygons. A settlement overlap is not an outage in each full area.
    # The caller owns provider/version/source-span guards; no feeder text enters.
    class CityServiceSettlementCoverage
      DATA_PATH = ENV.fetch("MI_SETTLEMENTS_DATA_PATH", "").freeze
      VERSION = "municipal-settlements-v1"
      ALIASES_PATH = ENV.fetch("MI_PLACE_ALIASES_PATH", "").freeze

      def initialize(organization:, data: nil, areas: nil)
        @organization = organization
        @data = data || (DATA_PATH.empty? ? { "features" => [] } : JSON.parse(File.read(DATA_PATH)))
        @areas = areas
        @inflections = ALIASES_PATH.empty? ? {} : YAML.safe_load_file(ALIASES_PATH, aliases: false).fetch("inflections", {})
      end

      def match(clause:)
        normalized = normalize(clause)
        matches = @data.fetch("features", []).select { |feature| matches_settlement?(feature, normalized) }
        return [] unless matches.one? && prepared_intersections_valid?(matches.first)

        feature = matches.first
        properties = feature.fetch("properties")
        areas.select { |area| properties.fetch("area_slugs").include?(area.slug) }.map do |area|
          { "slug" => area.slug, "kind" => area.kind, "relation" => "possible_overlap", "evidence" => clause,
            "source" => "municipal_settlement_geometry", "place_kind" => "settlement", "scope" => "source_settlement_polygon",
            "source_url" => properties["source_url"], "source_settlement_id" => properties["source_settlement_id"],
            "source_snapshot_sha256" => properties["source_snapshot_sha256"], "retrieved_at" => properties["retrieved_at"],
            "geometry_sha256" => properties.fetch("geometry_sha256"), "boundary_sha256" => boundary_versions.fetch(area.slug),
            "settlement_coverage_revision" => VERSION }
        end
      end

      def revision
        @revision ||= Digest::SHA256.hexdigest([VERSION, @data.to_json, @inflections.to_json, boundary_versions.sort.to_json].join("|"))
      end

      private

      def matches_settlement?(feature, normalized)
        properties = feature.fetch("properties", {})
        return false unless properties["place_type"] == "settlement" && properties["geometry_complete"] == true
        return false unless %w(Polygon MultiPolygon).include?(feature.dig("geometry", "type"))

        [properties["name"], *Array(properties["aliases"])].any? do |name|
          canonical = normalize(name)
          [canonical, *@inflections.fetch(canonical, [])].include?(normalized)
        end
      end

      def normalize(value)
        Decidim::Bih::Text.fold(value.to_s).gsub(/[^a-z0-9]+/, " ").strip.gsub(/\s+/, " ")
      end

      def prepared_intersections_valid?(feature)
        properties = feature.fetch("properties")
        properties["area_slugs"].is_a?(Array) && properties["geometry_sha256"] == boundary_digest(feature.fetch("geometry")) &&
          boundary_versions.all? { |slug, digest| @data.fetch("boundary_sha256", {})[slug] == digest }
      end

      def boundary_versions
        @boundary_versions ||= areas.to_h { |area| [area.slug, boundary_digest(area.boundary)] }
      end

      def boundary_digest(geometry)
        Digest::SHA256.hexdigest("#{geometry.fetch("type")}|#{geometry.fetch("coordinates").to_json}")
      end

      def areas
        @areas ||= Decidim::Bih::LocalArea.where(organization: @organization, kind: %w(mz komsiluk)).where.not(boundary: nil).to_a
      end
    end
  end
end
