# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceNoticeClassifierTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      test "classifies a planned power outage as publishable Viber alert" do
        payload = {
          "publish" => true,
          "event_type" => "planned_outage",
          "severity" => "service_outage",
          "targeting_level" => "komsiluk",
          "target_area_slugs" => ["komsiluk-izmisljeno-polje"],
          "title" => "Planirano iskljucenje struje",
          "body" => "Izmišljeno polje ce biti bez struje od 09:00 do 12:00.",
          "viber_text" => "Izmišljeno polje: planirano iskljucenje struje od 09:00 do 12:00.",
          "delivery_recommendation" => "viber_alert",
          "confidence" => 0.92,
          "starts_at" => "2026-06-20T09:00:00+02:00",
          "ends_at" => "2026-06-20T12:00:00+02:00",
          "fingerprint" => "elektro-2026-06-20-izmisljeno-polje",
          "needs_review" => false,
          "reasons" => ["planned outage with mapped target"]
        }
        client = FakeGeminiClient.new(payload)

        result = CityServiceNoticeClassifier.new(client:).call(
          source_key: "electricity_outages",
          title: "Planirana iskljucenja",
          body: "Izmišljeno polje 09-12",
          url: "https://example.test/outages",
          known_areas: [{ kind: "komsiluk", slug: "komsiluk-izmisljeno-polje", name: "Izmišljeno polje" }]
        )

        assert result.publish?
        assert result.viber_requested?
        assert_equal "service_outage", result.severity
        assert_equal "planned_outage", result.event_type
        assert_equal "safety", result.board_category
        assert_equal %w(komsiluk-izmisljeno-polje), result.target_area_slugs
        assert_equal false, result.needs_review
        assert_includes client.prompt, "A planned electricity outage is service_outage"
        assert_includes client.prompt, "slug=komsiluk-izmisljeno-polje"
      end

      test "falls back to no publish when Gemini is unconfigured" do
        result = CityServiceNoticeClassifier.new(client: FakeGeminiClient.new({}, configured: false)).call(
          source_key: "water_service",
          title: "Servisna informacija",
          body: "Detalji"
        )

        assert_not result.publish?
        assert_equal "no_publish", result.delivery_recommendation
        assert_equal true, result.needs_review
        assert_includes result.reasons, "gemini_unconfigured"
      end

      test "normalizes invalid model enum values to safe no-publish defaults" do
        payload = {
          "publish" => false,
          "event_type" => "made_up",
          "severity" => "critical",
          "targeting_level" => "street",
          "target_area_slugs" => [" mz-testni-park ", "mz-testni-park"],
          "title" => "<b>Naslov</b>",
          "body" => "<script>x</script> Tekst",
          "viber_text" => "Ne salji",
          "delivery_recommendation" => "blast",
          "confidence" => 9,
          "needs_review" => true,
          "reasons" => ["bad enum"]
        }

        result = CityServiceNoticeClassifier.new(
          client: FakeGeminiClient.new(payload)
        ).call(source_key: "civil_protection", title: "Fallback", body: "Body")

        assert_not result.publish?
        assert_equal "not_relevant", result.event_type
        assert_equal "info", result.severity
        assert_equal "unknown", result.targeting_level
        assert_equal "no_publish", result.delivery_recommendation
        assert_equal ["mz-testni-park"], result.target_area_slugs
        assert_equal 1.0, result.confidence
      end

      class FakeGeminiClient
        attr_reader :prompt

        def initialize(payload, configured: true)
          @payload = payload
          @configured = configured
        end

        def configured?
          @configured
        end

        def generate_content(contents:, response_schema:)
          raise "missing delivery schema" unless response_schema.fetch(:properties).has_key?(:delivery_recommendation)

          @prompt = contents.dig(0, :parts, 0, :text)
          @payload
        end
      end
    end
  end
end
