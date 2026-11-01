# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    # The deploy itself must be invisible to citizens: re-keying rows onto the
    # fact-derived version cannot let the next scrape mistake them for new
    # notices and supersede what is on the board.
    class CityServiceFactVersionBackfillTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "Izmišljeno polje" })
        @source = CityServiceSources.fetch("water_service")
        @ingestor = CityServiceEventIngestor.new(organization: @organization)
        @now = Time.utc(2040, 9, 9, 5)
      end

      test "a re-keyed published row survives the next scrape untouched" do
        event = ingest
        event.update!(state: "published", reviewer: @admin, reviewed_at: @now, reviewed_content_version: event.content_version)
        legacy = legacy_identity!(event)

        result = CityServiceFactVersionBackfill.new(organization: @organization).call(apply: true)

        assert_equal [event.id], result.rekeyed_ids
        assert_not_equal legacy, event.reload.content_version
        assert_equal event.content_version, event.reviewed_content_version

        again = @ingestor.ingest_article(source: @source, article: article, fetched_at: @now + 1.hour)

        assert_equal [event.id], again.events.map(&:id)
        assert event.reload.published?
        assert_nil event.superseded_by_id
        assert_equal 1, CityServiceEvent.for_organization(@organization).count
      end

      test "stored references to the old version travel with it" do
        event = ingest
        legacy = legacy_identity!(event)
        event.update!(extraction_metadata: event.extraction_metadata.merge(
          "operator_review" => { "source_content_version" => legacy, "provenance" => "operator_correction" },
          "article_content_version" => "untouched-document-version"
        ))

        CityServiceFactVersionBackfill.new(organization: @organization).call(apply: true)
        metadata = event.reload.extraction_metadata

        assert_equal event.content_version, metadata.dig("operator_review", "source_content_version")
        assert_equal "untouched-document-version", metadata["article_content_version"]
      end

      test "a dry run writes nothing and a second apply is a no-op" do
        event = ingest
        legacy = legacy_identity!(event)
        backfill = CityServiceFactVersionBackfill.new(organization: @organization)

        assert_equal [event.id], backfill.call.rekeyed_ids
        assert_equal legacy, event.reload.content_version

        backfill.call(apply: true)

        assert_empty backfill.call(apply: true).rekeyed_ids
        assert_equal [event.id], backfill.call.skipped_ids
      end

      test "rows that would collide are reported rather than written" do
        first = ingest
        second = ingest(url_suffix: "second")
        second.update!(source_occurrence_id: first.source_occurrence_id, source_key: first.source_key)
        legacy_identity!(first)
        legacy_identity!(second)

        result = CityServiceFactVersionBackfill.new(organization: @organization).call(apply: true)

        assert_equal [first.id], result.rekeyed_ids
        assert_equal [second.id], result.collisions
      end

      test "a superseded row keeps its historical identity" do
        event = ingest
        legacy = legacy_identity!(event)
        event.update!(state: "superseded", lifecycle: "superseded")

        assert_empty CityServiceFactVersionBackfill.new(organization: @organization).call(apply: true).rekeyed_ids
        assert_equal legacy, event.reload.content_version
      end

      # The backfill and the parser are one formula or they are a bug: a
      # disagreement re-keys rows onto a version the next scrape will not
      # compute, and every notice reopens.
      test "the stored version is reproducible from the row alone" do
        articles = {
          "water_service" => [
            "09.09.2040. od 08:00 do 12:00 prekid vodosnabdijevanja u Izmišljenom polju.",
            "09.09.2040. od 08:00 do zavr\u0161etka radova prekid vodosnabdijevanja u Izmišljenom polju.",
            "Zbog kvara danas je prekid vodosnabdijevanja u Izmišljenom polju."
          ]
        }
        events = articles.flat_map do |key, notices|
          source = CityServiceSources.fetch(key)
          notices.each_with_index.flat_map do |notice, index|
            article = CityServiceArticle.extract(
              html: "<article><p>#{notice}</p></article>",
              source_url: "https://water.example.invalid/v2/notices/reproducible-#{index}/"
            ).sole
            @ingestor.ingest_article(source:, article:, fetched_at: @now).events
          end
        end

        assert_operator events.size, :>=, 2
        events.each do |event|
          assert_equal event.content_version, CityServiceFactVersion.for_record(event),
                       "#{event.source_key} ##{event.id} (#{event.extraction_metadata["temporal_status"]}) is not reproducible"
        end
      end

      private

      def ingest(url_suffix: "backfill")
        @ingestor.ingest_article(source: @source, article: article(url_suffix:), fetched_at: @now).events.sole
      end

      # Puts the row back on the pre-fix identity: a version hashed from the
      # carrying document rather than from the notice's own facts.
      def legacy_identity!(event)
        legacy = Digest::SHA256.hexdigest("legacy-#{event.id}")
        event.update!(
          content_version: legacy,
          source_fingerprint: CityServiceEventIngestor.fingerprint_for(
            source_key: event.source_key, occurrence: event.source_occurrence_id, content_version: legacy
          ),
          reviewed_content_version: (legacy if event.reviewed_content_version.present?)
        )
        legacy
      end

      def article(url_suffix: "backfill")
        CityServiceArticle.extract(
          html: "<article><p>09.09.2040. od 08:00 do 12:00 prekid vodosnabdijevanja u Izmišljenom polju.</p></article>",
          source_url: "https://water.example.invalid/v2/notices/vodosnabdijevanje-#{url_suffix}/"
        ).sole
      end
    end
  end
end
