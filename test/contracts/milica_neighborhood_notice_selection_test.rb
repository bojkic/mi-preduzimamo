# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../app/services/decidim_app/bijeljina/milica/neighborhood_notice_selection"

class MilicaNeighborhoodNoticeSelectionTest < Minitest::Test
  Selection = DecidimApp::Bijeljina::Milica::NeighborhoodNoticeSelection

  def test_area_evidence_remains_available_even_when_source_facts_are_unconfirmed
    fact = notice("local", relation: "part", slugs: ["mz-ledinci"])
    fact["warning_codes"] = %w(source_facts_unconfirmed partial_geographic_coverage)
    result = select([fact])
    assert_equal ["local"], result.facts.map { |item| item["id"] }
    assert_equal "area", result.facts.first.dig("coverage", "summary_relevance")
    assert_equal fact["warning_codes"], result.facts.first["warning_codes"]
    assert_equal 1, result.coverage["area_evidence_count_in_sample"]
    assert_empty result.warnings
    assert_nil fact.dig("coverage", "summary_relevance")
  end

  def test_unlocated_transformer_notices_do_not_become_ledinci_area_facts
    facts = %w(batkovic amajlije).map do |slug|
      notice("TS #{slug}", relation: "unknown", slugs: [], targeting: "unknown").tap do |fact|
        fact["coverage"]["contextual_places"] = [{ "slug" => "mz-#{slug}", "relation" => "context_only" }]
      end
    end
    result = select(facts)
    assert_empty result.facts
    assert_equal "unmatched_area", result.coverage["status"]
    assert_equal 2, result.coverage["sampled_notice_count"]
    assert_equal 2, result.coverage["unlocated_notice_count_in_sample"]
    assert_equal 0, result.coverage["area_evidence_count_in_sample"]
    assert_includes result.warnings, "neighborhood_unlocated_notices"
    assert_includes result.warnings, "no_area_matched_collected_notices"
  end

  def test_possible_overlap_and_own_place_context_are_explicit_secondary_groups
    result = select([notice("context", relation: "context_only"), notice("overlap", relation: "possible_overlap")])
    assert_equal %w(overlap context), result.facts.map { |item| item["id"] }
    assert_equal %w(possible_overlap context_only), result.facts.map { |item| item.dig("coverage", "summary_relevance") }
    assert_equal 1, result.coverage["possible_overlap_count_in_sample"]
    assert_equal 1, result.coverage["context_only_count_in_sample"]
    assert_includes result.warnings, "no_area_matched_collected_notices"
  end

  def test_citywide_evidence_is_kept_without_claiming_every_source_fact_was_reviewed
    fact = notice("citywide", relation: "part", targeting: "citywide")
    fact["warning_codes"] = ["source_facts_unconfirmed"]
    result = select([fact])
    assert_equal "area", result.facts.first.dig("coverage", "summary_relevance")
    assert_equal ["source_facts_unconfirmed"], result.facts.first["warning_codes"]
  end

  def test_actual_area_evidence_is_ranked_ahead_of_wider_candidates_within_bounded_sample
    facts = [notice("unknown", relation: "unknown"), notice("context", relation: "context_only"),
             notice("local", relation: "whole", slugs: ["mz-ledinci"])]
    result = select(facts, limit: 1)
    assert_equal ["local"], result.facts.map { |item| item["id"] }
    assert_equal 3, result.coverage["sampled_notice_count"]
    assert_equal 1, result.coverage["unlocated_notice_count_in_sample"]
  end

  def test_whole_relation_for_a_different_area_is_not_promoted_and_empty_sample_is_not_a_citywide_claim
    result = select([notice("elsewhere", relation: "whole", slugs: ["mz-batkovic"])])
    assert_empty result.facts
    assert_equal 1, result.coverage["unlocated_notice_count_in_sample"]
    empty = select([])
    assert_empty empty.facts
    assert_empty empty.warnings
    assert_equal 0, empty.coverage["sampled_notice_count"]
  end

  private

  def select(facts, limit: 5)
    Selection.call(facts:, requested_slugs: ["mz-ledinci"], limit:)
  end

  def notice(id, relation:, slugs: [], targeting: "area")
    { "id" => id, "kind" => "city_service_event", "text" => "Synthetic collected notice", "source_id" => "electricity_outages",
      "coverage" => { "requested_relation" => relation, "targeting_level" => targeting, "area_slugs" => slugs } }
  end
end
