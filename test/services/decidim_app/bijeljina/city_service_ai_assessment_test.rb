# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class CityServiceAiAssessmentTest < ActiveSupport::TestCase
      class FakeClient
        def configured? = true
        def model = "fixture-model"
      end

      class FakeClassifier
        attr_reader :calls

        def initialize(result)
          @result = result
          @calls = []
        end

        def call(**options)
          @calls << options
          @result
        end
      end

      setup do
        @organization = create_organization
        @event = CityServiceEvent.create!(organization: @organization, source_key: "city_official_notices", source_fingerprint: "city-ai-article",
                                          content_version: "article-facts-v1", parser_version: "city-v5", event_type: "road_closure", severity: "safety",
                                          title: "Zatvaranje puta", summary: "Radovi na putu", affected_text: "Brodac", targeting_level: "unknown",
                                          starts_at: 1.hour.from_now, ends_at: 4.hours.from_now,
                                          extraction_metadata: { "source_snapshot_complete" => true, "ai_source_text" => "Radovi na putu u Brodcu od 10 do 13 časova." })
      end

      test "accepted model classification is persisted once against full article facts" do
        classifier = FakeClassifier.new(result)
        service = CityServiceAiAssessment.new(organization: @organization, client: FakeClient.new, classifier:)
        service.call(events: [@event])
        decision = @event.reload.extraction_metadata.fetch("ai_classification")
        assert_equal "accepted", decision.fetch("status")
        assert_equal "article-facts-v1", decision.fetch("source_content_version")
        assert_equal "fixture-model", decision.fetch("model")
        assert_equal "Radovi na putu u Brodcu od 10 do 13 časova.", classifier.calls.first.fetch(:body)
        service.call(events: [@event])
        assert_equal 1, classifier.calls.size
      end

      test "model disagreement and missing article cannot authorize automatic publication" do
        classifier = FakeClassifier.new(result(severity: "routine"))
        service = CityServiceAiAssessment.new(organization: @organization, client: FakeClient.new, classifier:)
        service.call(events: [@event])
        assert_equal "disagreement", @event.reload.extraction_metadata.dig("ai_classification", "status")
        assert_includes CityServiceAutomation.new(organization: @organization).blockers(@event), "ai_review_required"

        @event.update!(extraction_metadata: @event.extraction_metadata.except("ai_source_text", "ai_classification"))
        service.call(events: [@event])
        assert_equal "missing_article", @event.reload.extraction_metadata.dig("ai_classification", "status")
        assert_equal 1, classifier.calls.size
      end

      private

      def result(severity: "safety")
        CityServiceNoticeClassifier::Result.new(source_key: "city_official_notices", publish: true, event_type: "road_closure",
                                                severity:, targeting_level: "unknown", target_area_slugs: [], title: "Radovi na putu",
                                                body: "Radovi na putu u Brodcu.", viber_text: "Radovi na putu u Brodcu.",
                                                delivery_recommendation: "board_only", confidence: 0.86, needs_review: false, reasons: [])
      end
    end
  end
end
