# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # A second, inspectable opinion on complete city articles. Source facts,
    # dates and board areas continue to come from deterministic extraction.
    # Disagreement or an unavailable model sends the notice to an operator.
    class CityServiceAiAssessment
      VERSION = "city-article-classification-20260925-v1"
      MIN_REMAINING_SECONDS = 25

      def initialize(organization:, client: Decidim::Bih::Ai::GeminiClient.new, classifier: nil)
        @organization = organization
        @client = client
        @classifier = classifier || CityServiceNoticeClassifier.new(client:)
      end

      def call(events:, deadline: nil)
        Array(events).each do |event|
          next unless event.decidim_organization_id == @organization.id && event.source_key == "city_official_notices"
          next unless event.pending_review? && event.extraction_metadata["source_snapshot_complete"] == true

          next if current_decision?(event)

          version = event.content_version
          article_hash = Digest::SHA256.hexdigest(event.extraction_metadata["ai_source_text"].to_s.strip)
          decision = assess(event, deadline:)
          # Keep the network call outside the row lock. A correction, source
          # revision or another model decision wins if it arrived meanwhile.
          event.with_lock do
            next unless event.pending_review? && event.extraction_metadata["source_snapshot_complete"] == true
            next unless event.content_version == version &&
                        Digest::SHA256.hexdigest(event.extraction_metadata["ai_source_text"].to_s.strip) == article_hash
            next if current_decision?(event)

            event.update!(extraction_metadata: event.extraction_metadata.merge("ai_classification" => decision))
          end
        end
      end

      private

      def current_decision?(event)
        decision = event.extraction_metadata["ai_classification"].to_h
        %w(accepted rejected disagreement review).include?(decision["status"]) &&
          decision["source_content_version"] == event.content_version &&
          decision["version"] == VERSION && decision["prompt_hash"] == prompt_hash &&
          decision["model"] == model_name &&
          decision["source_article_hash"] == Digest::SHA256.hexdigest(event.extraction_metadata["ai_source_text"].to_s.strip)
      end

      def assess(event, deadline:)
        body = event.extraction_metadata["ai_source_text"].to_s.strip
        evidence = { "version" => VERSION, "prompt_hash" => prompt_hash, "model" => model_name,
                     "source_content_version" => event.content_version, "source_article_hash" => Digest::SHA256.hexdigest(body),
                     "assessed_at" => Time.current.iso8601 }
        return evidence.merge("status" => "missing_article", "needs_review" => true) if body.blank?
        return evidence.merge("status" => "unavailable", "needs_review" => true) unless @client.configured?
        if deadline && deadline.remaining_seconds < MIN_REMAINING_SECONDS
          return evidence.merge("status" => "budget_exhausted", "needs_review" => true)
        end

        # The model can evaluate relevance in the context of areas already
        # extracted from the source; its proposed slugs never set destinations.
        known_areas = Decidim::Bih::LocalArea.where(organization: @organization, slug: event.area_slugs).map do |area|
          { kind: area.kind, slug: area.slug, name: area.translated_name }
        end
        result = @classifier.call(source_key: event.source_key, title: event.title, body:, url: event.source_url, known_areas:)
        status = classification_status(event, result)
        evidence.merge("status" => status, "publish" => result.publish?, "event_type" => result.event_type,
                       "severity" => result.severity, "needs_review" => result.needs_review,
                       "delivery_recommendation" => result.delivery_recommendation,
                       "confidence" => result.confidence, "reasons" => result.reasons,
                       "suggested_title" => result.title, "suggested_body" => result.body,
                       "suggested_viber_text" => result.viber_text)
      end

      def classification_status(event, result)
        return "unavailable" if Array(result.reasons).intersect?(%w(gemini_unconfigured gemini_failed))
        return "rejected" unless result.publish?
        return "review" if result.needs_review || result.delivery_recommendation == "operator_review"
        return "disagreement" if result.event_type != event.event_type || result.severity != event.severity

        "accepted"
      end

      def prompt_hash
        @prompt_hash ||= Digest::SHA256.hexdigest([
          CityServiceNoticeClassifier::INSTRUCTIONS,
          CityServiceNoticeClassifier::RESPONSE_SCHEMA
        ].to_json)
      end

      def model_name
        @client.respond_to?(:model) ? @client.model.to_s : "unknown"
      end
    end
  end
end
