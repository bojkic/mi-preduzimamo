# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Source occurrence identity is stronger than similar prose. Cross-source
    # resemblance is a review candidate, never automatic proof of equivalence.
    class CityServiceIncidentIdentity
      SERVICES = {
        "electricity_outages" => "electricity", "water_service" => "water", "heating_service" => "heating",
        "road_conditions" => "roads", "weather_warnings" => "weather", "civil_protection" => "safety", "bulky_waste" => "waste"
      }.freeze

      def self.service(event)
        return SERVICES.fetch(event.source_key) if SERVICES.has_key?(event.source_key)
        return "roads" if %w(road_closure road_hazard).include?(event.event_type)
        return "water" if %w(planned_interruption unplanned_interruption).include?(event.event_type)

        event.event_type
      end

      def self.attach!(event)
        return event.incident if event.incident_id

        key = Digest::SHA256.hexdigest([event.source_key, event.source_occurrence_id.presence || event.source_fingerprint].join("|"))
        incident = CityServiceIncident.create_or_find_by!(organization: event.organization, identity_key: key) do |row|
          row.service = service(event)
        end
        event.update!(incident:)
        incident
      end

      def self.revision(event)
        facts = [service(event), event.event_type, event.lifecycle, event.severity, event.starts_at&.utc&.iso8601,
                 event.ends_at&.utc&.iso8601, event.targeting_level, event.area_slugs,
                 Decidim::Bih::Text.fold(event.affected_text), Decidim::Bih::Text.fold(event.recommended_action),
                 Decidim::Bih::Text.fold(event.summary), Decidim::Bih::Text.fold(event.viber_text),
                 Array(event.extraction_metadata["publication_history"]).size]
        Digest::SHA256.hexdigest(facts.to_json)
      end

      # Only an explicit incident merge authorizes shared delivery. Among its
      # corroborating observations use a stable canonical source for wording;
      # time/lifecycle/target changes remain meaningful independent revisions.
      def self.delivery_anchor(event)
        return event unless event.incident_id

        signature = delivery_facts(event)
        CityServiceEvent.where(incident_id: event.incident_id, decidim_organization_id: event.decidim_organization_id)
                        .where.not(state: %w(dismissed superseded)).order(:id).detect { |member| delivery_facts(member) == signature } || event
      end

      def self.delivery_facts(event)
        [service(event), event.event_type, event.lifecycle, event.severity, event.starts_at&.utc&.iso8601,
         event.ends_at&.utc&.iso8601, event.targeting_level, event.area_slugs]
      end

      def self.bind_delivery!(members)
        members.group_by { |member| delivery_facts(member) }.each_value do |group|
          anchor = group.min_by { |member| [receipt_priority(member), member.id] }
          identity = delivery_identity(anchor)
          group.each do |member|
            member.update!(extraction_metadata: member.extraction_metadata.merge(
              "incident_delivery_binding" => { "identity" => identity, "member_revision" => revision(member) }
            ))
          end
        end
      end

      def self.receipt_priority(event)
        receipts = Decidim::Bih::PlatformDelivery.where(organization: event.organization, identity: delivery_identity(event))
        return 0 if receipts.where.not(acknowledged_at: nil).exists?
        return 1 if receipts.where.not(inbox_created_at: nil).exists?

        2
      end

      def self.delivery_identity(event)
        binding = event.extraction_metadata["incident_delivery_binding"].to_h
        if binding.present?
          return binding.fetch("identity") if binding["member_revision"] == revision(event)

          # A real correction invalidates this observation's previous delivery
          # identity; retirement of another observation does not.
          return "city-incident:#{event.incident_id}:#{revision(event)}"
        end
        anchor = delivery_anchor(event)
        "city-incident:#{event.incident_id}:#{revision(anchor)}"
      end
    end
  end
end
