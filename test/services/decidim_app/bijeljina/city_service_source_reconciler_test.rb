# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceSourceReconcilerTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include ActiveSupport::Testing::TimeHelpers
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @source = CityServiceSources.fetch("water_service")
        @now = Time.find_zone!("Europe/Sarajevo").parse("2040-09-09 07:00")
        @ingestor = CityServiceEventIngestor.new(organization: @organization)
      end

      test "same-fact city article revision gets fresh AI evidence and retires the published version" do
        source = CityServiceSources.fetch("city_official_notices")
        url = "https://city.example.invalid/notices/1234.saobracaj.html"
        original_article = city_article(url:, context: "Vozači treba da prate signalizaciju.")
        original = @ingestor.ingest_article(source:, article: original_article, fetched_at: @now).events.sole
        original.update!(state: "published", reviewer: @admin, reviewed_at: @now,
                         reviewed_content_version: original.content_version,
                         extraction_metadata: original.extraction_metadata.merge("ai_classification" => { "status" => "accepted" }))

        revised_article = city_article(url:, context: "Vozači treba da koriste obilazni put.")
        current = @ingestor.ingest_article(source:, article: revised_article, fetched_at: @now + 1.minute).events.sole

        assert_equal original.content_version, current.content_version
        assert_not_equal original.id, current.id
        assert_equal revised_article.content_version, current.extraction_metadata.fetch("article_content_version")
        assert_includes current.extraction_metadata.fetch("ai_source_text"), "obilazni put"
        assert_nil current.extraction_metadata["ai_classification"]
        assert current.pending_review?
        assert current.extraction_metadata["source_document_changed"]
        assert original.reload.superseded?
        assert_equal "source_group_version_changed", original.extraction_metadata.dig("source_withdrawal", "reason")
        assert_empty CityServiceEvent.citizen_visible.where(id: original.id)
        assert_equal current.id, @ingestor.ingest_article(source:, article: revised_article, fetched_at: @now + 2.minutes).events.sole.id
      end

      test "identical city article reobservation retains the current AI assessment" do
        source = CityServiceSources.fetch("city_official_notices")
        url = "https://city.example.invalid/notices/1234.saobracaj.html"
        article = city_article(url:, context: "Vozači treba da prate signalizaciju.")
        original = @ingestor.ingest_article(source:, article:, fetched_at: @now).events.sole
        original.update!(extraction_metadata: original.extraction_metadata.merge("ai_classification" => { "status" => "accepted" }))

        current = @ingestor.ingest_article(source:, article:, fetched_at: @now + 1.minute).events.sole

        assert_equal original.id, current.id
        assert_equal "accepted", current.extraction_metadata.dig("ai_classification", "status")
        assert_equal article.content_version, current.extraction_metadata.fetch("article_content_version")
      end

      test "changed city article version cannot reuse AI approval when the bounded text stays the same" do
        source = CityServiceSources.fetch("city_official_notices")
        url = "https://city.example.invalid/notices/1234.saobracaj.html"
        article = city_article(url:, context: "Vozači treba da prate signalizaciju.")
        original = @ingestor.ingest_article(source:, article:, fetched_at: @now).events.sole
        original.update!(extraction_metadata: original.extraction_metadata.merge("ai_classification" => { "status" => "accepted" }))
        article.content_version = "new-document-version-with-identical-ai-text"
        current = @ingestor.ingest_article(source:, article:, fetched_at: @now + 1.minute).events.sole

        assert_not_equal original.id, current.id
        assert_equal article.content_version, current.reload.extraction_metadata.fetch("article_content_version")
        assert_nil current.extraction_metadata["ai_classification"]
        assert current.pending_review?
        assert original.reload.superseded?
      end

      test "successive city article versions with the same AI excerpt cannot reuse a published derived row" do
        source = CityServiceSources.fetch("city_official_notices")
        url = "https://city.example.invalid/notices/1234.saobracaj.html"
        article = city_article(url:, context: "Vozači treba da prate signalizaciju.")
        dismissed = @ingestor.ingest_article(source:, article:, fetched_at: @now).events.sole
        dismissed.update!(state: "dismissed", reviewer: @admin, reviewed_at: @now)

        article.content_version = "second-document-version"
        published = @ingestor.ingest_article(source:, article:, fetched_at: @now + 1.minute).events.sole
        published.update!(state: "published", reviewer: @admin, reviewed_at: @now,
                          reviewed_content_version: published.content_version,
                          extraction_metadata: published.extraction_metadata.merge("ai_classification" => { "status" => "accepted" }))

        article.content_version = "third-document-version"
        current = @ingestor.ingest_article(source:, article:, fetched_at: @now + 2.minutes).events.sole

        assert_not_equal published.id, current.id
        assert_equal "third-document-version", current.extraction_metadata.fetch("article_content_version")
        assert_nil current.extraction_metadata["ai_classification"]
        assert current.pending_review?
        assert published.reload.superseded?
        assert dismissed.reload.dismissed?
        assert_empty CityServiceEvent.citizen_visible.where(id: published.id)
      end

      test "canonical article date correction withdraws old approved facts without inventing an occurrence link" do
        old = ingest_article(day: 9).events.sole
        old.update!(state: "published", reviewer: @admin, reviewed_at: @now, reviewed_content_version: old.content_version)
        original_review = old.reviewed_content_version
        current = ingest_article(day: 10).events.sole

        assert old.reload.superseded?
        assert_nil old.superseded_by_id
        assert_equal "canonical_article_changed", old.extraction_metadata.dig("source_withdrawal", "reason")
        assert_equal original_review, old.reviewed_content_version
        assert_equal @admin.id, old.reviewed_by_id
        assert current.pending_review?
        assert_nil current.reviewed_at
        assert_empty CityServiceEvent.citizen_visible.where(id: old.id)
      end

      test "reordered article groups do not fabricate one to one occurrence replacements" do
        first = "<p>9.09.2040. od 08:00 do 10:00 prekid vodosnabdijevanja u Izmišljenom polju.</p>"
        second = "<p>9.09.2040. od 12:00 do 14:00 prekid vodosnabdijevanja u Izmišljenom području B.</p>"
        url = "https://water.example.invalid/v2/vodosnabdijevanje-reordered/"
        original_article = CityServiceArticle.extract(html: "<article>#{first}#{second}</article>", source_url: url).sole
        previous = @ingestor.ingest_article(source: @source, article: original_article, fetched_at: @now).events
        reordered_article = CityServiceArticle.extract(html: "<article>#{second}#{first}</article>", source_url: url).sole
        current = @ingestor.ingest_article(source: @source, article: reordered_article, fetched_at: @now).events
        assert_equal 2, current.size
        assert(previous.all? { |event| event.reload.superseded? && event.superseded_by_id.nil? })
        assert(current.all? { |event| event.pending_review? && event.extraction_metadata["source_document_changed"] })
      end

      test "only generated posts explicitly owned by the withdrawn event expire" do
        old = ingest_article(day: 9).events.sole
        area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-reconciliation", name: { "sr" => "Komšiluk" })
        generated = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: area, category: "safety", title: "Source notice", body: "Source facts")
        citizen = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: area, author: @admin, category: "general", title: "Citizen post",
                                                     body: "Citizen content")
        unrelated = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: area, category: "general", title: "Other generated post", body: "Other facts")
        old.update!(state: "published", komsiluk_post_ids: [generated.id, citizen.id])

        ingest_article(day: 10)
        assert generated.reload.expired?
        assert citizen.reload.open?
        assert unrelated.reload.open?
      end

      test "dismissed decisions and unrelated canonical articles are preserved" do
        dismissed = ingest_article(day: 9).events.sole
        dismissed.update!(state: "dismissed", reviewer: @admin, reviewed_at: @now, review_note: "Already reviewed")
        unrelated = ingest_article(day: 9, url: "https://water.example.invalid/v2/vodosnabdijevanje-other/").events.sole
        ingest_article(day: 10)
        assert dismissed.reload.dismissed?
        assert_equal "Already reviewed", dismissed.review_note
        assert unrelated.reload.pending_review?
      end

      test "incomplete article cannot withdraw an existing approved notice" do
        old = ingest_article(day: 9).events.sole
        old.update!(state: "published")
        incomplete = article(day: 10)
        incomplete.complete = false
        result = @ingestor.ingest_article(source: @source, article: incomplete, fetched_at: @now)
        assert_empty result.events
        assert old.reload.published?
      end

      test "same content is idempotent and a source reverting to old content gets a fresh review" do
        original = ingest_article(day: 9).events.sole
        original.update!(state: "published", reviewer: @admin, reviewed_at: @now, reviewed_content_version: original.content_version)
        unchanged = ingest_article(day: 9)
        assert_equal 0, unchanged.created
        assert_equal original.id, unchanged.events.sole.id
        ingest_article(day: 9, to: "15:00")
        returned = ingest_article(day: 9).events.sole
        assert_not_equal original.id, returned.id
        assert original.reload.superseded?
        assert returned.pending_review?
        assert_nil returned.reviewed_content_version
        assert_equal returned.id, ingest_article(day: 9).events.sole.id
      end

      test "explicit late restoration and cancellation reconcile the old article after its planned window ended" do
        { "resolved" => "Vodosnabdijevanje je normalizovano", "cancelled" => "Otkazan je najavljeni prekid vodosnabdijevanja" }.each do |lifecycle, statement|
          url = "https://water.example.invalid/v2/vodosnabdijevanje-late-#{lifecycle}/"
          old = ingest_article(day: 9, url:).events.sole
          old.update!(state: "published", reviewer: @admin, reviewed_at: @now, reviewed_content_version: old.content_version)
          html = "<article><p>09.09.2040. od 08:00 do 14:00 #{statement} u Izmišljenom polju.</p></article>"
          revised = CityServiceArticle.extract(html:, source_url: url).sole
          update = @ingestor.ingest_article(source: @source, article: revised, fetched_at: @now + 1.day).events.sole
          assert_equal lifecycle, update.lifecycle
          assert update.pending_review?
          assert_nil update.reviewed_at
          assert old.reload.superseded?
          assert_nil old.superseded_by_id, "The canonical article proves revision, not a guessed occurrence pairing"
          assert_equal old.content_version, old.reviewed_content_version
          assert_equal revised.content_version, old.extraction_metadata.dig("source_withdrawal", "observed_version")
          assert_equal update.id, @ingestor.ingest_article(source: @source, article: revised, fetched_at: @now + 2.days).events.sole.id
        end
      end

      test "complete electricity snapshot invalidates only still-relevant members explicitly linked to that source snapshot" do
        old = @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 9), fetched_at: @now).events.sole
        old.update!(state: "published")
        current = @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 10), fetched_at: @now).events.sole
        assert old.reload.superseded?
        assert_nil old.superseded_by_id
        assert_equal "complete_source_snapshot_changed", old.extraction_metadata.dig("source_withdrawal", "reason")
        assert current.pending_review?
      end

      test "partial electricity page and normal rolling expiry do not manufacture source withdrawals" do
        old = @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 9), fetched_at: @now).events.sole
        old.update!(state: "published")
        @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 10).sub("</table>", ""), fetched_at: @now)
        assert old.reload.published?
        @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 11), fetched_at: @now + 1.day)
        assert old.reload.published?
        assert_nil old.extraction_metadata["source_withdrawal"]
      end

      test "complete electricity snapshot retires invalid unreviewed legacy windows with provenance and without invented facts" do
        reversed = legacy_electricity(state: "failed", starts_at: @now - 2.months, ends_at: @now - 2.months - 1.hour)
        missing = legacy_electricity(starts_at: nil, ends_at: nil)
        equal = legacy_electricity(starts_at: @now, ends_at: @now)
        original_windows = [reversed, missing, equal].to_h { |event| [event.id, [event.starts_at, event.ends_at]] }

        current = @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 10), fetched_at: @now).events.sole
        [reversed, missing, equal].each do |event|
          assert event.reload.superseded?
          assert_equal original_windows.fetch(event.id), [event.starts_at, event.ends_at]
          assert_nil event.superseded_by_id
          assert_nil event.reviewed_by_id
          assert_nil event.reviewed_at
          assert_nil event.content_version
          withdrawal = event.extraction_metadata.fetch("source_withdrawal")
          assert_equal "invalid_legacy_window_replaced_by_complete_snapshot", withdrawal.fetch("reason")
          assert_equal current.source_url, withdrawal.fetch("document_url")
          assert_equal current.extraction_metadata.fetch("source_document_version"), withdrawal.fetch("observed_version")
          assert_equal @now.iso8601, withdrawal.fetch("observed_at")
        end
        assert current.pending_review?
        assert_nil current.reviewed_at
        unchanged_times = [reversed, missing, equal].map(&:updated_at)
        @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 10), fetched_at: @now + 5.minutes)
        assert_equal(unchanged_times, [reversed, missing, equal].map { |event| event.reload.updated_at })
      end

      test "expired invalid legacy failures retire without erasing historical review stamps" do
        event = legacy_electricity(state: "failed", starts_at: @now - 2.months, ends_at: @now - 2.months - 1.hour,
                                   reviewed_by_id: @admin.id, reviewed_at: @now - 3.months, review_note: "Historical publication review")
        preserved = event.attributes.slice("reviewed_by_id", "reviewed_at", "review_note", "starts_at", "ends_at")
        @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 10).sub("</table>", ""), fetched_at: @now)
        assert event.reload.failed?
        @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 10), fetched_at: @now)
        assert event.reload.superseded?
        assert_equal preserved, event.attributes.slice(*preserved.keys)
        assert_equal "invalid_legacy_window_replaced_by_complete_snapshot", event.extraction_metadata.dig("source_withdrawal", "reason")
      end

      test "legacy retirement preserves reviewed valid versioned and unrelated records" do
        preserved = [
          legacy_electricity(starts_at: @now, ends_at: @now + 1.hour),
          legacy_electricity(state: "published"),
          legacy_electricity(state: "dismissed"),
          legacy_electricity(state: "failed", reviewed_by_id: @admin.id),
          legacy_electricity(reviewed_at: @now),
          legacy_electricity(reviewed_content_version: "legacy-review"),
          legacy_electricity(content_version: "versioned-body"),
          legacy_electricity(source_url: "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=42"),
          legacy_electricity(source_key: "water_service"),
          legacy_electricity(organization: create_organization)
        ]
        original_states = preserved.to_h { |event| [event.id, event.state] }

        @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 10), fetched_at: @now)

        preserved.each do |event|
          assert_equal original_states.fetch(event.id), event.reload.state
          assert_nil event.extraction_metadata["source_withdrawal"]
        end
      end

      test "partial electricity snapshots and other source snapshots cannot retire invalid legacy windows" do
        invalid = legacy_electricity
        @ingestor.ingest(source_key: "electricity_outages", html: electricity(day: 10).sub("</table>", ""), fetched_at: @now)
        assert invalid.reload.pending_review?
        assert_nil invalid.extraction_metadata["source_withdrawal"]

        water = legacy_electricity(source_key: "water_service")
        CityServiceSourceReconciler.new(organization: @organization).reconcile_snapshot(
          source: @source, source_url: water.source_url, content_version: "complete-water-version", events: [], complete: true, observed_at: @now
        )
        assert water.reload.pending_review?
        assert_nil water.extraction_metadata["source_withdrawal"]
      end

      test "a changed same-occurrence row in a truncated page cannot replace approved evidence or be published" do
        travel_to @now do
          original = electricity(day: 9)
          old = @ingestor.ingest(source_key: "electricity_outages", html: original, fetched_at: @now).events.sole
          old.update!(state: "published", reviewer: @admin, reviewed_at: @now, reviewed_content_version: old.content_version)
          corrected = original.sub("14:00", "15:00")
          partial = corrected.sub("</table>", "")
          pending = @ingestor.ingest(source_key: "electricity_outages", html: partial, fetched_at: @now + 5.minutes).events.sole
          assert old.reload.published?
          assert_nil old.superseded_by_id
          assert_nil old.extraction_metadata["source_withdrawal"]
          assert pending.pending_review?
          assert_not pending.source_evidence_complete?
          assert_nil pending.reviewed_content_version
          publisher = CityServiceEventPublisher.new(pending, actor: @admin)
          CityServiceNoticePublisher.stub(:new, ->(**) { raise "Incomplete evidence entered publication" }) do
            assert_equal :not_publishable, publisher.publish_board!.status
          end

          # Re-observation of the old body through a partial page also must not
          # downgrade the full approved snapshot or reset its last-good clock.
          @ingestor.ingest(source_key: "electricity_outages", html: original.sub("</table>", ""), fetched_at: @now + 10.minutes)
          assert old.reload.source_evidence_complete?
          assert_equal @now, old.fetched_at
          assert_equal old.content_version, old.reviewed_content_version

          complete = @ingestor.ingest(source_key: "electricity_outages", html: corrected, fetched_at: @now + 15.minutes).events.sole
          assert_equal pending.id, complete.id
          assert complete.source_evidence_complete?
          assert complete.pending_review?
          assert_nil complete.reviewed_content_version
          assert old.reload.superseded?
        end
      end

      private

      def legacy_electricity(**attributes)
        window = { starts_at: @now, ends_at: @now - 1.hour }.merge(attributes.extract!(:starts_at, :ends_at))
        event = CityServiceEvent.create!(
          { organization: @organization, source_key: "electricity_outages", source_url: CityServiceSources.fetch("electricity_outages").fetch(:source_url),
            source_fingerprint: SecureRandom.hex(16), title: "Legacy date heading", summary: "Retained source extraction", parser_version: "legacy",
            event_type: "electricity_outage", severity: "info", targeting_level: "unknown", state: "pending_review" }.merge(attributes)
        )
        # Historical malformed ranges predate the model's occurrence validation.
        event.update_columns(window) # rubocop:disable Rails/SkipsModelValidations -- reproduce pre-validation legacy corruption
        event
      end

      def city_article(url:, context:)
        html = "<article><p>12.09.2040. od 08:00 do 14:00 obustava saobraćaja u ulici Izmišljena breza.</p>" \
               "<p>#{context}</p></article>"
        CityServiceArticle.extract(html:, source_url: url).sole
      end

      def article(day:, to: "14:00", url: "https://water.example.invalid/v2/vodosnabdijevanje-corrected/")
        html = "<article><p>#{day}.09.2040. od 08:00 do #{to} prekid vodosnabdijevanja u Izmišljenom polju zbog radova.</p></article>"
        CityServiceArticle.extract(html:, source_url: url).sole
      end

      def ingest_article(**attributes)
        @ingestor.ingest_article(source: @source, article: article(**attributes), fetched_at: @now)
      end

      def electricity(day:)
        "<p>#{day}-09-2040</p>" \
          "<table><tr><td>TJ</td><td>Objekat</td><td>Područje</td><td>Razlog</td><td>Početak</td><td>Završetak</td></tr>" \
          "<tr><td>Bijeljina</td><td>TS 1</td><td>1 NN izlaz</td><td>Radovi</td><td>09:00</td><td>14:00</td></tr></table>"
      end
    end
  end
end
