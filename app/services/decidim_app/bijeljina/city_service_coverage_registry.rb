# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Approval attaches to a qualified provider footprint, not publication state.
    class CityServiceCoverageRegistry
      def self.identity(event)
        parts = [event.source_key, event.source_url, event.extraction_metadata["tj"], event.extraction_metadata["feeder"], event.affected_text]
        Digest::SHA256.hexdigest(parts.map { |part| Decidim::Bih::Text.fold(part) }.to_json)
      end

      def self.remember!(event, actor:)
        review = event.extraction_metadata["operator_review"].to_h
        return unless review["reuse_coverage"] == true && event.area_slugs.any? && event.facts_confirmed?

        areas = Decidim::Bih::LocalArea.where(organization: event.organization, slug: event.area_slugs).order(:slug)
        mapping = CityServiceCoverage.find_or_initialize_by(organization: event.organization, identity_key: identity(event))
        mapping.update!(event:, reviewer: actor, source_key: event.source_key, targeting_level: event.targeting_level,
                        area_slugs: event.area_slugs, valid_until: Date.iso8601(review.fetch("coverage_valid_until")), revoked_at: nil,
                        evidence: { "source_content_version" => event.content_version, "affected_text" => event.affected_text,
                                    "operating_unit" => event.extraction_metadata["tj"], "asset" => event.extraction_metadata["feeder"],
                                    "boundary_revision" => geometry_revision(areas), "approved_at" => Time.current.iso8601 })
      end

      def self.resolve(event)
        mapping = CityServiceCoverage.find_by(organization: event.organization, identity_key: identity(event), revoked_at: nil)
        return unless mapping && event.ends_at && mapping.valid_until >= [Date.current, event.ends_at.in_time_zone("Europe/Sarajevo").to_date].max

        areas = Decidim::Bih::LocalArea.where(organization: event.organization, kind: mapping.targeting_level, slug: mapping.area_slugs).order(:slug)
        return unless areas.size == mapping.area_slugs.size && mapping.evidence["boundary_revision"] == geometry_revision(areas)

        mapping
      end

      def self.revoke!(event:, actor:)
        return :not_authorized unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :city_alerts_manage, organization: event.organization)

        mapping = CityServiceCoverage.find_by(organization: event.organization, identity_key: identity(event))
        return :invalid_selection unless mapping

        mapping.with_lock do
          mapping.update!(revoked_at: Time.current)
          Decidim::Bih::OperatorAuditEvent.record!(organization: event.organization, actor:, event_type: "city_service_coverage_revoked",
                                                   permission: "city_alerts_manage", resource: mapping, metadata: { mapping_id: mapping.id })
        end
        :updated
      end

      def self.geometry_revision(areas)
        Digest::SHA256.hexdigest(areas.map { |area| [area.slug, area.boundary] }.to_json)
      end
    end
  end
end
