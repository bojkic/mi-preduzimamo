# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceAutomationDecision < ApplicationRecord
      self.table_name = "decidim_app_city_service_automation_decisions"
      CHECK_RESULTS = %w(ok corrected withdrawn).freeze

      belongs_to :event, class_name: "DecidimApp::Bijeljina::CityServiceEvent"
      belongs_to :checked_by, class_name: "Decidim::User", optional: true

      validates :check_result, inclusion: { in: CHECK_RESULTS }, allow_nil: true
      validate :complete_check

      def self.evidence_digest(event)
        boundaries = Decidim::Bih::LocalArea.where(decidim_organization_id: event.decidim_organization_id)
                                          .order(:id).pluck(:id, :slug, :boundary)
        evidence = event.extraction_metadata.slice("coverage", "station_place", "station_label", "confidence_by_field",
                                                    "source_snapshot_complete", "source_document_complete",
                                                    "source_document_changed", "publication_correction_pending",
                                                    "ai_classification")
        Digest::SHA256.hexdigest([event.publication_revision, event.content_version, event.source_updated_at,
                                  event.source_fingerprint, event.source_url,
                                  CityServiceIncidentIdentity.revision(event), evidence, boundaries].to_json)
      end

      def checked_for?(event, policy_version: CityServiceAutomationPolicy::VERSION)
        check_result == "ok" && checked_at.present? && checked_publication_revision == event.publication_revision &&
          checked_policy_version == policy_version && checked_evidence_digest == self.class.evidence_digest(event)
      end

      private

      def complete_check
        values = [checked_at, checked_by_id, check_result, checked_publication_revision, checked_policy_version, checked_evidence_digest]
        return if values.all?(&:nil?) || values.all?(&:present?)

        errors.add(:check_result, :invalid)
      end
    end
  end
end
