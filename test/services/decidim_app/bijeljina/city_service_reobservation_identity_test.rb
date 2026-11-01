# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    # A live aggregate feed re-publishes the same notice inside a body that
    # churns for unrelated reasons. Re-observing it must not open a second
    # review row: the operator reviews an occurrence, not a fetch.
    class CityServiceReobservationIdentityTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @organization = create_organization
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "Izmišljeno polje" })
        @source = CityServiceSources.fetch("water_service")
        @ingestor = CityServiceEventIngestor.new(organization: @organization)
        @now = Time.utc(2040, 9, 9, 5)
      end

      test "an unchanged notice keeps one row when the surrounding document churns" do
        first = @ingestor.ingest_article(source: @source, article: article(visits: 1234), fetched_at: @now)
        original = first.events.sole
        assert_equal "unknown_clock", original.extraction_metadata["temporal_status"]
        assert_not original.source_evidence_complete?

        second = @ingestor.ingest_article(source: @source, article: article(visits: 5678), fetched_at: @now + 1.hour)

        assert_equal [original.id], second.events.map(&:id)
        assert_equal 1, CityServiceEvent.for_organization(@organization).pending_review.count
        assert_equal original.content_version, original.reload.content_version
      end

      test "an unchanged notice keeps one row across many re-observations" do
        ids = 12.times.map do |index|
          @ingestor.ingest_article(source: @source, article: article(visits: index), fetched_at: @now + index.hours).events.sole.id
        end

        assert_equal 1, ids.uniq.size
        assert_equal 1, CityServiceEvent.for_organization(@organization).count
      end

      test "a changed notice body is a new version of the same occurrence" do
        original = @ingestor.ingest_article(source: @source, article: article(visits: 1), fetched_at: @now).events.sole
        changed = @ingestor.ingest_article(
          source: @source,
          article: article(visits: 1, notice: "09.09.2040. od 09:00 do završetka radova prekid vodosnabdijevanja u Izmišljenom polju."),
          fetched_at: @now + 1.hour
        ).events.sole

        assert_not_equal original.content_version, changed.content_version
      end

      private

      def article(visits:, notice: "09.09.2040. od 08:00 do završetka radova prekid vodosnabdijevanja u Izmišljenom polju.")
        CityServiceArticle.extract(
          html: "<article><p>#{notice}</p><p>Broj posjeta stranici: #{visits}</p></article>",
          source_url: "https://water.example.invalid/v2/notices/vodosnabdijevanje-reobservation/"
        ).sole
      end
    end
  end
end
