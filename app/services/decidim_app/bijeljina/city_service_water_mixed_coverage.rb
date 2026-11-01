# frozen_string_literal: true

require "digest"
require "uri"

module DecidimApp
  module Bijeljina
    # Resolves each source-named water location independently. A named street
    # needs verified street geometry; a named settlement uses its own polygon.
    # A partial list remains review-only even when some areas are known.
    class CityServiceWaterMixedCoverage
      VERSION = "water-mixed-clauses-v3"
      EventView = Struct.new(:source_key, :source_url, :content_version, :extraction_metadata, :affected_text, keyword_init: true)

      def initialize(organization:, street_coverage: nil, settlement_coverage: nil)
        @organization = organization
        @street_coverage = street_coverage || CityServiceStreetCoverage.new(organization:)
        @settlement_coverage = settlement_coverage || CityServiceSettlementCoverage.new(organization:)
      end

      def match(event)
        return unless eligible?(event)

        clauses = event.extraction_metadata.dig("coverage", "clauses")
        return unless clauses.is_a?(Array) && clauses.any? && clauses.size <= 30

        rows = clauses.map { |row| resolve(event, row.fetch("evidence").to_s) }
        summarize(event, rows)
      end

      def revision
        @revision ||= Digest::SHA256.hexdigest([VERSION, @street_coverage.revision, @settlement_coverage.revision].join("|"))
      end

      private

      def summarize(event, rows)
        places = rows.flat_map { |row| row.fetch("places") }.uniq
        unresolved = rows.filter_map { |row| row["unresolved"] }
        # A named part inside a settlement is not evidence that the entire
        # settlement is affected. Board placement is only a possible overlap.
        streets = rows.any? { |row| %w(street settlement_part).include?(row.fetch("kind")) }
        board_eligible = board_eligible?(rows, unresolved)
        { "status" => coverage_status(places, unresolved),
          "complete" => unresolved.empty? && places.any?, "source_content_version" => event.content_version,
          "water_mixed_coverage_revision" => revision,
          "scope" => "source_named_water_locations", "scope_precision" => streets ? "unspecified_street_segment" : "named_settlement_overlap",
          "board_placement" => board_eligible ? "verified_full_geometry_intersection" : "review_required",
          "clause_count" => rows.size, "resolved_clause_count" => rows.size - unresolved.size, "unresolved_clause_count" => unresolved.size,
          "clauses" => rows.map { |row| row.slice("evidence", "kind", "status", "board_slugs") },
          "affected_places" => places, "unresolved_places" => unresolved, "ambiguous_places" => [], "notification_candidates" => [] }
      end

      def board_eligible?(rows, unresolved)
        unresolved.empty? && rows.all? { |row| row.fetch("board_slugs", []).any? }
      end

      def coverage_status(places, unresolved)
        return "unknown" if places.empty?

        unresolved.empty? ? "resolved" : "partial"
      end

      def eligible?(event)
        return false unless event.source_key == "water_service" && event.content_version.present?
        return false unless event.decidim_organization_id == @organization.id
        return false unless event.extraction_metadata["source_snapshot_complete"] == true
        return false unless event.extraction_metadata["canonical_article_url"] == event.source_url

        trusted_source_url?(event.source_url)
      end

      def trusted_source_url?(source_url)
        uri = URI.parse(source_url.to_s)
        uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? &&
          %w(bnvodovod.com www.bnvodovod.com).include?(uri.host) && uri.path.start_with?("/v2/")
      rescue URI::InvalidURIError, ArgumentError
        false
      end

      def resolve(event, clause)
        parsed = clause.match(/\A([^();]+?)\s*\(([^();]+)\)\z/)
        if parsed
          name, settlement = parsed.captures.map { |value| Decidim::Bih::Text.fold(value) }
          # A named street or smaller place never inherits the parent settlement's
          # footprint. Missing precise geometry must remain review-only.
          return street_row(event, clause) unless name == settlement
        else
          return unresolved(clause, "location_clause_shape_unknown") if clause.match?(/[();]/)

          settlement = clause
        end

        places = @settlement_coverage.match(clause: settlement)
        return unresolved(clause, "settlement_geometry_not_verified") if places.empty?

        { "evidence" => clause, "kind" => "settlement", "status" => "resolved",
          "board_slugs" => places.select { |place| place["kind"] == "komsiluk" }.map { |place| place.fetch("slug") }.uniq.sort,
          "places" => places.map { |place| place.merge("evidence" => clause, "evidence_role" => "explicit_affected_location", "provider_source_url" => event.source_url) } }
      end

      def street_row(event, clause)
        view = EventView.new(source_key: event.source_key, source_url: event.source_url, content_version: event.content_version,
                             extraction_metadata: event.extraction_metadata, affected_text: clause)
        coverage = @street_coverage.match(view)
        return unresolved(clause, "full_street_geometry_not_verified", kind: "street") unless coverage && coverage["complete"] && coverage.fetch("affected_places").any?

        places = coverage.fetch("affected_places")
        { "evidence" => clause, "kind" => "street", "status" => "resolved",
          "board_slugs" => places.select { |place| place["kind"] == "komsiluk" }.map { |place| place.fetch("slug") }.uniq.sort,
          "places" => places }
      end

      def unresolved(clause, reason, kind: "location_clause")
        { "evidence" => clause, "kind" => kind, "status" => "unresolved", "places" => [],
          "unresolved" => { "kind" => kind, "evidence" => clause, "reason" => reason } }
      end
    end
  end
end
