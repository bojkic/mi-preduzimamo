# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceUnresolvedTimeTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "Izmišljeno polje" })
        @source = CityServiceSources.fetch("water_service")
        @ingestor = CityServiceEventIngestor.new(organization: @organization)
      end

      test "spring nonexistent and autumn ambiguous source clocks remain pending evidence without invented instants" do
        [["29.03.2026", "nonexistent_local_time"], ["25.10.2026", "ambiguous_local_time"]].each do |day, expected|
          now = Time.find_zone!(CityServiceTime::ZONE).parse("#{day} 00:00")
          article = water_article(day:, from: "02:30", to: "04:00")
          result = @ingestor.ingest_article(source: @source, article:, fetched_at: now)
          event = result.events.sole
          assert result.complete?
          assert event.pending_review?
          assert_nil event.starts_at
          assert_equal 4, event.ends_at.hour
          assert_equal expected, event.extraction_metadata["temporal_status"]
          assert_equal "02:30", event.extraction_metadata["raw_from"]
          assert_equal true, event.extraction_metadata["source_document_complete"]
          assert_equal true, event.extraction_metadata["source_snapshot_complete"]
          assert_not event.source_evidence_complete?
          assert_empty CityServiceEvent.citizen_visible.where(id: event.id)
          assert_equal :not_publishable, CityServiceEventPublisher.new(event, actor: @admin).publish_board!.status
        end
      end

      test "an explicitly unknown end retains the source start and no fabricated end" do
        article = CityServiceArticle.extract(
          html: "<article><p>09.09.2026. od 08:00 do završetka radova prekid vodosnabdijevanja u Izmišljenom polju.</p></article>",
          source_url: @source.fetch(:source_url)
        ).sole
        result = @ingestor.ingest_article(source: @source, article:, fetched_at: Time.utc(2026, 9, 9, 5))
        event = result.events.sole
        assert result.complete?
        assert_equal 8, event.starts_at.hour
        assert_nil event.ends_at
        assert_equal "unknown_clock", event.extraction_metadata["temporal_status"]
        assert_includes event.extraction_metadata["temporal_evidence"], "završetka radova"
        assert event.pending_review?
      end

      test "fetched water article with an unresolved time is a complete source with a reviewable candidate" do
        now = Time.utc(2026, 10, 24, 22)
        article = water_article(day: "25.10.2026", from: "02:30", to: "04:00")
        loader = Object.new
        loader.define_singleton_method(:call) { |**| CityServiceArticleFetcher::Result.new(articles: [article], status: :ok) }
        fetcher = ->(**) { { http_status: 200, content_type: "text/html", body: article.html, final_url: @source.fetch(:source_url) } }
        store = CityServiceSourceCheckStore.new
        result = CityServiceSourceScrape.new(organization: @organization, fetcher:, article_fetcher: loader, source_store: store, now:)
                                        .call(keys: ["water_service"]).sole
        assert_equal "ok", result.status
        assert_nil result.error_code
        assert_equal 1, result.created
        snapshot = store.snapshot(source_key: "water_service")
        assert_equal "ok", snapshot.check_payload["status"]
        assert_nil snapshot.check_payload["error_code"]
        assert_equal 1, snapshot.check_payload.fetch("notices").size
        assert snapshot.last_success_at
      end

      test "an unresolved same article revision cannot withdraw previous usable approved facts" do
        now = Time.utc(2026, 10, 24, 22)
        original = water_article(day: "25.10.2026", from: "01:00", to: "04:00")
        old = @ingestor.ingest_article(source: @source, article: original, fetched_at: now).events.sole
        old.update!(state: "published", reviewer: @admin, reviewed_at: now, reviewed_content_version: old.content_version)
        previous_review = old.reviewed_content_version
        ambiguous = water_article(day: "25.10.2026", from: "02:30", to: "04:00")
        result = @ingestor.ingest_article(source: @source, article: ambiguous, fetched_at: now + 1.minute)
        pending = result.events.sole
        assert result.complete?
        assert pending.pending_review?
        assert old.reload.published?
        assert_nil old.superseded_by_id
        assert_nil old.extraction_metadata["source_withdrawal"]
        assert_equal previous_review, old.reviewed_content_version
        assert_equal [old.id], CityServiceEvent.citizen_visible.where(id: [old.id, pending.id]).pluck(:id)
      end

      test "electricity invalid clocks retain source shaped rows for review and preserve the previous complete snapshot" do
        now = Time.utc(2026, 10, 24, 22)
        original = electricity("01:00")
        old = @ingestor.ingest(source_key: "electricity_outages", html: original, fetched_at: now).events.sole
        old.update!(state: "published", reviewed_content_version: old.content_version)
        result = @ingestor.ingest(source_key: "electricity_outages", html: electricity("02:30"), fetched_at: now + 1.minute)
        pending = result.events.sole
        assert_not result.complete?
        assert pending.pending_review?
        assert_nil pending.starts_at
        assert_equal "ambiguous_local_time", pending.extraction_metadata["temporal_status"]
        assert_equal true, pending.extraction_metadata["source_document_complete"]
        assert_not pending.source_evidence_complete?
        assert old.reload.published?
        assert_nil old.superseded_by_id
        assert_equal :not_publishable, CityServiceEventPublisher.new(pending, actor: @admin).publish_board!.status
      end

      private

      def water_article(day:, from:, to:)
        CityServiceArticle.extract(
          html: "<article><p>#{day}. od #{from} do #{to} prekid vodosnabdijevanja u Izmišljenom polju zbog radova.</p></article>",
          source_url: "https://water.example.invalid/v2/notices/temporal-review/"
        ).sole
      end

      def electricity(from)
        <<~HTML
          <p>25.10.2026.</p><table>
          <tr><th>TJ</th><th>Objekat</th><th>Područje</th><th>Razlog</th><th>Početak</th><th>Završetak</th></tr>
          <tr><td>TESTNA JEDINICA</td><td>TESTNI OBJEKAT A</td><td>Izmišljeno polje</td><td>Radovi</td><td>#{from}</td><td>04:00</td></tr>
          </table>
        HTML
      end
    end
  end
end
