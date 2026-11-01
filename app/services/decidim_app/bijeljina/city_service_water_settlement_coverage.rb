# frozen_string_literal: true

require "digest"
require "uri"

module DecidimApp
  module Bijeljina
    # Vodovod's affected-location bullets can name a settlement twice, e.g.
    # "Balatun (Balatun)". This is not evidence for a street with that name.
    # Only an entire list in that explicit shape is eligible; a street followed
    # by its municipality, worksite prose or equipment name does not qualify.
    class CityServiceWaterSettlementCoverage
      VERSION = "water-named-settlements-v1"

      def initialize(organization:, settlement_coverage: nil)
        @organization = organization
        @settlement_coverage = settlement_coverage || CityServiceSettlementCoverage.new(organization:)
      end

      def match(event)
        return unless eligible?(event)

        clauses = location_clauses(event.affected_text)
        return if clauses.empty?

        places, unresolved = collected_places(clauses, event)
        return if places.empty?

        { "status" => unresolved.empty? ? "resolved" : "partial", "complete" => unresolved.empty?,
          "source_content_version" => event.content_version, "water_settlement_coverage_revision" => revision,
          "scope" => "source_named_settlement_list", "scope_precision" => "possible_settlement_overlap",
          "affected_places" => places.uniq, "unresolved_places" => unresolved, "ambiguous_places" => [],
          "notification_candidates" => [],
          "komsiluk_status" => places.any? { |place| place["kind"] == "komsiluk" } ? "independent_geometry" : "not_inferred" }
      end

      def revision
        @revision ||= Digest::SHA256.hexdigest([VERSION, @settlement_coverage.revision].join("|"))
      end

      private

      def collected_places(clauses, event)
        places = []
        unresolved = []
        clauses.each do |clause, name|
          mapped = @settlement_coverage.match(clause: name)
          if mapped.empty?
            unresolved << { "kind" => "settlement", "evidence" => clause, "reason" => "settlement_geometry_not_verified" }
          else
            places.concat(mapped.map do |place|
              place.merge("relation" => "possible_overlap", "evidence" => clause,
                          "evidence_role" => "explicit_affected_location", "provider_source_url" => event.source_url)
            end)
          end
        end
        [places, unresolved]
      end

      def eligible?(event)
        return false if @organization && event.decidim_organization_id != @organization.id
        return false unless event.source_key == "water_service" && event.content_version.present?
        return false unless event.extraction_metadata["source_snapshot_complete"] == true
        return false unless event.extraction_metadata["canonical_article_url"] == event.source_url

        supported_source_url?(event.source_url)
      end

      def supported_source_url?(url)
        uri = URI.parse(url.to_s)
        uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? &&
          %w(bnvodovod.com www.bnvodovod.com).include?(uri.host) && uri.path.start_with?("/v2/")
      rescue URI::InvalidURIError, ArgumentError
        false
      end

      def location_clauses(text)
        parts = text.to_s.split(/;|\n/).map(&:strip)
        return [] if parts.empty? || parts.size > 30 || parts.any?(&:blank?)

        parts.map do |part|
          name = repeated_settlement_name(part)
          return [] unless name

          [part, name]
        end
      end

      def repeated_settlement_name(part)
        match = part.match(/\A([^();]+?)\s*\(([^();]+)\)\z/)
        return unless match

        name = Decidim::Bih::Text.fold(match[1])
        parenthetical = Decidim::Bih::Text.fold(match[2])
        name if name == parenthetical && name.match?(/\A[a-z]+(?: [a-z]+){0,5}\z/)
      end
    end
  end
end
