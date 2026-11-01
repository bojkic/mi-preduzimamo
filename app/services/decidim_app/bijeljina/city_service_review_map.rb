# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Destination polygons are never asserted to be the affected footprint.
    class CityServiceReviewMap
      def initialize(event)
        @event = event
      end

      def call
        areas = Decidim::Bih::LocalArea.where(decidim_organization_id: @event.decidim_organization_id, kind: %w(komsiluk mz)).order(:slug).to_a
        area_ids = areas.index_by(&:slug).transform_values(&:id)
        features = areas.filter_map do |area|
          next if area.boundary.blank?

          { type: "Feature", geometry: area.boundary, properties: { id: area.id, slug: area.slug, kind: area.kind, name: area.translated_name,
                                                                    mz_ids: ([area.parent_id] + [area.primary_mz_slug, *Array(area.overlapping_mz_slugs)].filter_map do |slug|
                                                                      area_ids[slug]
                                                                    end).compact.uniq } }
        end
        coverage = @event.extraction_metadata.fetch("coverage", {})
        current = coverage["source_content_version"] == @event.content_version
        places = current ? Array(coverage["affected_places"]) : []
        footprints = supported_footprints(places)
        { type: "FeatureCollection", features:, footprint: { type: "FeatureCollection", features: footprints },
          review_token: @event.answer_review_token, unknown_extent: footprints.empty?,
          affected_text: @event.affected_text, unresolved: current ? Array(coverage["unresolved_places"]) : [],
          boundary_version: Digest::SHA256.hexdigest(features.to_json) }
      end

      private

      def supported_footprints(places)
        [CityServiceStreetCoverage::DATA_PATH, CityServiceSettlementCoverage::DATA_PATH].flat_map do |path|
          next [] unless File.file?(path)

          JSON.parse(File.read(path)).fetch("features", []).select do |feature|
            geometry = feature.fetch("geometry", {})
            digests = [Digest::SHA256.hexdigest(geometry.to_json), Digest::SHA256.hexdigest("#{geometry["type"]}|#{geometry["coordinates"].to_json}")]
            places.any? { |place| %w(full_named_street_geometry municipal_settlement_geometry).include?(place["source"]) && digests.include?(place["geometry_sha256"]) }
          end
        end
      end
    end
  end
end
