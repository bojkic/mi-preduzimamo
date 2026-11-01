# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Relevance is independent of operator confirmation. Collected unconfirmed
      # facts with actual area evidence stay available; a transformer name or an
      # unlocated citywide search candidate is not evidence for this neighborhood.
      class NeighborhoodNoticeSelection
        ORDER = %w(area possible_overlap context_only unlocated).freeze
        COUNT_KEYS = {
          "area" => "area_evidence_count_in_sample", "possible_overlap" => "possible_overlap_count_in_sample",
          "context_only" => "context_only_count_in_sample", "unlocated" => "unlocated_notice_count_in_sample"
        }.freeze
        Result = Data.define(:facts, :coverage, :warnings)

        def self.call(facts:, requested_slugs:, limit:)
          groups = facts.group_by { |fact| relevance(fact, requested_slugs) }
          coverage = { "sampled_notice_count" => facts.length }
          COUNT_KEYS.each { |group, key| coverage[key] = groups.fetch(group, []).length }
          warnings = []
          warnings << "neighborhood_unlocated_notices" if coverage["unlocated_notice_count_in_sample"].positive?
          warnings << "no_area_matched_collected_notices" if facts.any? && coverage["area_evidence_count_in_sample"].zero?
          selected = ORDER.first(3).flat_map do |group|
            groups.fetch(group, []).map { |fact| fact.merge("coverage" => fact.fetch("coverage", {}).merge("summary_relevance" => group)) }
          end.first(limit)
          coverage["status"] = "unmatched_area" if facts.any? && selected.empty?
          Result.new(selected, coverage, warnings)
        end

        def self.relevance(fact, requested_slugs)
          coverage = fact.fetch("coverage", {})
          return "area" if coverage["targeting_level"] == "citywide"

          relation = coverage["requested_relation"]
          direct = Array(coverage["area_slugs"]) | Array(coverage["affected_relations"]).filter_map do |place|
            place["slug"] if %w(whole part).include?(place["relation"])
          end
          return "area" if %w(whole part).include?(relation) && requested_slugs.intersect?(direct)
          return relation if %w(possible_overlap context_only).include?(relation)

          "unlocated"
        end
      end
    end
  end
end
