# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Context supports finding and explaining a notice, never publication targets.
    class CityServicePlaceContext
      def self.places(event)
        context = event.extraction_metadata["place_context"].to_h
        return [] if event.content_version.blank? || context["source_content_version"] != event.content_version

        Array(context["places"]).select do |place|
          place.is_a?(Hash) && place["relation"] == "context_only" && place["slug"].present?
        end
      end

      def self.slugs(event)
        places(event).map { |place| place.fetch("slug") }.uniq
      end

      def self.partial_coverage?(coverage, relations: Array(coverage["affected_places"]))
        coverage["status"] != "resolved" || relations.any? { |place| place["relation"] != "whole" }
      end

      def self.overlap_only?(coverage, requested_slugs, relations: Array(coverage["affected_places"]))
        possible = Array(coverage["notification_candidates"]).map { |place| place["slug"] }
        possible |= relations.select { |place| place["relation"] == "possible_overlap" }.map { |place| place["slug"] }
        confirmed = relations.select { |place| %w(whole part).include?(place["relation"]) }.map { |place| place["slug"] }
        !requested_slugs.intersect?(confirmed) && requested_slugs.intersect?(possible)
      end

      def self.notice(event, locale:)
        names = places(event).filter_map { |place| place["name"].presence }.uniq
        return "" if names.empty?

        I18n.t("decidim_app.city_service_events.bot.place_context", names: names.join(", "), locale:)
      end
    end
  end
end
