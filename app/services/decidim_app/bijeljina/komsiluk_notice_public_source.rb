# frozen_string_literal: true

require "request_store"

module DecidimApp
  module Bijeljina
    # Resolve linked staff notices and opted-in city-service placements against
    # their current public source at read time.
    # The staff prefill/dispatch provider requires broadcast_preview; a citizen
    # must never be granted that permission merely to see a source link.
    class KomsilukNoticePublicSource
      class << self
        def call(organization:, post:)
          return city_source_state(organization:, post:) if post&.origin == "city_service"

          reference = post&.details.to_h["source_record"]
          return { updating: false, url: nil } if reference.blank?
          return unavailable unless organization && post.decidim_organization_id == organization.id && post.origin == "staff"
          return unavailable unless reference.is_a?(Hash)

          current = current_source(organization, reference)
          return unavailable unless current

          source = current.dig(:details, "source_record")
          stored_fingerprint = reference["material_fingerprint"]
          updating = if stored_fingerprint.present?
                       stored_fingerprint != source["material_fingerprint"]
                     else
                       # Placements created before the public-fact fingerprint
                       # can only be trusted while their full revision matches.
                       reference["revision"] != source["revision"]
                     end
          url = source["url"].to_s
          safe_url = url.start_with?("/") && !url.start_with?("//") ? url : nil
          { updating:, url: updating ? nil : safe_url }
        end

        private

        def city_source_state(organization:, post:)
          return unavailable unless organization && post.decidim_organization_id == organization.id

          metadata = post.details.to_h["source"]
          return { updating: false, url: nil } unless metadata.is_a?(Hash) &&
            (metadata["revalidation_required"] == true || metadata["event_type"] == "severe_weather")

          revision = metadata["event_revision"]
          review_id = metadata["weather_region_review_id"]
          return unavailable unless [revision, review_id].all? { |value| value.is_a?(String) && /\A[a-f0-9]{64}\z/.match?(value) }

          # JSON event_ids is a display hint, never proof of a relationship.
          # Resolve only the actual tenant-scoped post/incident relationship.
          events = CityServiceBoardVisibility.events_for(post).where(source_key: "weather_warnings", state: %w(board_published published))
                                             .where("extraction_metadata ->> 'publication_revision' = ?", revision)
          current = events.any? do |event|
            event.extraction_metadata["weather_region_review_id"] == review_id &&
              Array(event.target_komsiluk_slugs).include?(post.komsiluk.slug) && event.publication_blocker.nil?
          end
          current ? { updating: false, url: nil } : unavailable
        end

        def current_source(organization, reference)
          kind, id = reference.values_at("kind", "id")
          return KomsilukNoticeSources.new(organization:).snapshot(kind:, id:) unless RequestStore.active?

          # The board list is bounded; repeated placements of one source share
          # this request's public visibility lookup. Each placement still
          # compares against its own reviewed fingerprint.
          cache = RequestStore.store[:komsiluk_notice_public_sources] ||= {}
          cache.fetch([organization.id, kind.to_s, id.to_s]) do
            cache[[organization.id, kind.to_s, id.to_s]] = KomsilukNoticeSources.new(organization:).snapshot(kind:, id:)
          end
        end

        def unavailable
          { updating: true, url: nil }
        end
      end
    end
  end
end
