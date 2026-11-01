# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Trusted source fields are kept outside the bounded citizen summary.
    # Callers must resolve the actual event/projection relationship first.
    module CityServiceBoardMetadata
      module_function

      def for_event(event)
        members = event.incident ? event.incident.events.where.not(state: %w(dismissed superseded)).order(:id).to_a : [event]
        source = event.source
        {
          "provider" => source&.dig(:provider).presence || event.provider.presence || event.source_label_text,
          "urls" => members.map(&:source_url).compact_blank.uniq,
          "scope_label" => scope_label(event),
          "event_ids" => members.map(&:id), "event_type" => event.event_type,
          "starts_at" => event.starts_at&.iso8601, "ends_at" => event.ends_at&.iso8601,
          "event_revision" => event.publication_revision, "phone_audience_verified" => !CityServicePhoneDelivery.phone_audience_unverified?(event)
        }.compact.merge(event.source_key == "weather_warnings" ? {
          "revalidation_required" => true, "weather_region_review_id" => event.extraction_metadata["weather_region_review_id"]
        } : {})
      end

      def scope_label(event)
        return I18n.t("decidim_app.komsiluk_boards.scope.citywide") if event.targeting_level == "citywide"

        names = Decidim::Bih::LocalArea.where(organization: event.organization, slug: event.area_slugs)
                                       .order(:slug).map(&:translated_name)
        label = event.affected_text.presence || names.join(", ")
        key = CityServicePhoneDelivery.phone_audience_unverified?(event) ? "part" : "affected"
        I18n.t("decidim_app.komsiluk_boards.scope.#{key}", area: label)
      end
    end
  end
end
