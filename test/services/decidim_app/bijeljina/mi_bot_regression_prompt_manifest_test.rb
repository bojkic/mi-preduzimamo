# frozen_string_literal: true

require "test_helper"
require "yaml"

module DecidimApp
  module Bijeljina
    class MiBotRegressionPromptManifestTest < ActiveSupport::TestCase
      MANIFEST_PATH = Rails.root.join("config/examples/mi_bot_regression_prompts.yml")
      REQUIRED_ACCEPTANCE_IDS = %w(
        transport_from_here_to_primjerpolje
        transport_nearest_stop_to_primjerpolje
        transport_wrong_authored_stop_followup
        parking_pay_current_location
        parking_zone_current_location
        report_problem_current_location
        electricity_outage_my_neighbourhood
        waste_collection_my_area
        feedback_not_helpful_meaning
      ).freeze
      REQUIRED_FIELDS = %w(
        id prompt locale answer_intent topic failure_type source feedback_value context
        expected_contains expected_not_contains
      ).freeze

      test "manifest groups authored hypothetical not-helpful regression scenarios" do
        prompts = manifest_prompts
        metadata = YAML.safe_load_file(MANIFEST_PATH, permitted_classes: [], aliases: false)
        assert_equal "fully_authored_public_examples", metadata.fetch("provenance")
        assert_equal "requirements_not_execution_evidence", metadata.fetch("acceptance_status")

        assert_equal REQUIRED_ACCEPTANCE_IDS.sort, prompts.map { |row| row.fetch("id") }.sort
        prompts.each do |row|
          REQUIRED_FIELDS.each { |field| assert row.has_key?(field), "missing #{field} for #{row.inspect}" }

          assert_includes Decidim::Bih::Concierge::AnswerIntents::VALUES, row.fetch("answer_intent")
          assert_equal "sr", row.fetch("locale")
          assert_equal "not_helpful", row.fetch("feedback_value")
          assert row.fetch("failure_type").present?
          assert Array(row.fetch("expected_contains")).any?
          assert Array(row.fetch("expected_not_contains")).any?
        end
      end

      test "manifest avoids raw private feedback identifiers and coordinates" do
        text = MANIFEST_PATH.read

        forbidden_patterns = [
          /\breply[_-]?id\b/i,
          /\bsession[_-]?digest\b/i,
          /\bfeedback[_-]?token\b/i,
          /\buser[_-]?id\b/i,
          /\b\d{2}\.\d{4,}\s*,\s*\d{2}\.\d{4,}\b/
        ]
        forbidden_patterns.each do |pattern|
          assert_no_match pattern, text
        end
      end

      test "manifest keeps feedback fixes tied to expected answer changes" do
        wrong_stop = manifest_prompts.find { |row| row.fetch("id") == "transport_wrong_authored_stop_followup" }
        report = manifest_prompts.find { |row| row.fetch("id") == "report_problem_current_location" }
        feedback = manifest_prompts.find { |row| row.fetch("id") == "feedback_not_helpful_meaning" }

        assert_includes wrong_stop.fetch("expected_not_contains"), "Primjergrad (Pogrešno stajalište)"
        assert_includes report.fetch("expected_contains"), "lat="
        assert_includes feedback.fetch("expected_not_contains"), "/biceriseno/prijave/new"
      end

      private

      def manifest_prompts
        YAML.safe_load_file(MANIFEST_PATH, permitted_classes: [], aliases: false).fetch("prompts")
      end
    end
  end
end
