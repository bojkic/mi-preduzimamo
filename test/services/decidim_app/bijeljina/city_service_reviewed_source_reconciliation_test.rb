# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceReviewedSourceReconciliationTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        travel_to Time.utc(2026, 10, 24, 12)
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "Izmišljeno polje" })
        @source = CityServiceSources.fetch("water_service")
        @ingestor = CityServiceEventIngestor.new(organization: @organization)
        @old = ingest(old_article).events.sole
        assert_equal :approved, approve(@old)
      end

      teardown { travel_back }

      test "corrected full article approval withdraws the old date without pairing or approving other new groups" do
        revised = revised_article
        pending = ingest(revised).events
        corrected = pending.find { |event| event.extraction_metadata["complete"] == false }
        other = (pending - [corrected]).sole
        assert @old.reload.answer_approved?
        assert_equal :updated, correct(corrected)
        sql = []
        subscriber = ->(_name, _start, _finish, _id, payload) { sql << payload.fetch(:sql) }
        result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { approve(corrected.reload) }

        assert_equal :approved, result
        assert corrected.reload.answer_approved?
        assert @old.reload.superseded?
        assert_nil @old.superseded_by_id
        assert_equal "canonical_article_changed", @old.extraction_metadata.dig("source_withdrawal", "reason")
        assert other.reload.pending_review?
        assert_nil other.reviewed_content_version
        assert_equal [corrected.id], CityServiceEvent.for_organization(@organization).citizen_visible.pluck(:id)
        assert_empty feed(Date.new(2026, 10, 25)).events
        assert_equal [corrected.id, other.id].sort, feed(Date.new(2026, 10, 26)).events.map(&:id).sort
        assert_empty corrected.komsiluk_post_id_values
        assert_empty @old.komsiluk_post_id_values
        document_lock = sql.index { |statement| statement.include?("pg_advisory_xact_lock") }
        event_lock = sql.index { |statement| statement.include?("FOR UPDATE") }
        assert document_lock, "The complete canonical document must be locked"
        assert event_lock, "The approved event must be locked"
        assert_operator document_lock, :<, event_lock

        # Re-reading the still ambiguous raw source cannot erase the reviewed
        # correction, revive old facts, or repeat approval side effects.
        receipt = corrected.attributes.slice("reviewed_at", "reviewed_by_id", "reviewed_content_version")
        replay = ingest(revised)
        assert replay.complete?
        assert_equal corrected.id, replay.events.find { |event| event.id == corrected.id }.id
        assert corrected.reload.answer_approved?
        assert_equal receipt, corrected.attributes.slice(*receipt.keys)
        assert @old.reload.superseded?
      end

      test "operator correction cannot use truncated raw evidence to withdraw an approved article" do
        pending = ingest(revised_article).events.find { |event| event.extraction_metadata["complete"] == false }
        pending.update!(extraction_metadata: pending.extraction_metadata.merge("source_document_complete" => false))
        assert_equal :updated, correct(pending)
        assert_equal :incomplete_evidence, approve(pending.reload)
        assert pending.reload.pending_review?
        assert @old.reload.answer_approved?
        assert_nil @old.extraction_metadata["source_withdrawal"]
      end

      test "complete unchanged provider observation retains pending operator facts and reusable coverage" do
        source = article("<p>26.10.2026. od 08:00 do 12:00 prekid vodosnabdijevanja u Izmišljenom polju.</p>")
        event = ingest(source).events.sole
        assert_equal :updated, correct(event, "reuse_coverage" => "1", "coverage_valid_until" => "2026-11-01", "title" => "Operator clarified scope")
        event.reload
        retained = event.attributes.slice(*CityServiceEventReview::FACT_FIELDS, *CityServiceEventReview::TEXT_FIELDS,
                                          "reviewed_at", "reviewed_by_id", "reviewed_content_version", "extraction_metadata")
        token = event.answer_review_token
        assert event.pending_review?
        assert_equal true, event.extraction_metadata.dig("operator_review", "reuse_coverage")
        travel 1.minute

        repeated = ingest(source)
        assert_equal event.id, repeated.events.sole.id
        assert_equal 1, repeated.unchanged
        assert_equal retained, event.reload.attributes.slice(*retained.keys)
        assert_equal token, event.answer_review_token
        assert_equal Time.current, event.fetched_at
        assert event.pending_review?
        assert_empty CityServiceEvent.for_organization(@organization).citizen_visible

        revised = ingest(article("<p>26.10.2026. od 08:00 do 15:00 prekid vodosnabdijevanja u Izmišljenom polju.</p>")).events.sole
        assert_not_equal event.id, revised.id
        assert revised.pending_review?
        assert_nil revised.reviewed_by_id
        assert_nil revised.reviewed_content_version
        assert_nil revised.extraction_metadata["operator_review"]
        assert event.reload.superseded?
      end

      test "complete unchanged source retains suggestions bound to its version without preserving unreviewed parser facts" do
        source = article("<p>26.10.2026. od 08:00 do 12:00 prekid vodosnabdijevanja u Izmišljenom polju.</p>")
        event = ingest(source).events.sole
        suggestions = { "source_content_version" => event.content_version, "requires_coverage_review" => true,
                        "candidates" => [{ "slug" => @area.slug, "method" => "geocoder_point_in_polygon" }] }
        event.update!(title: "Unreviewed local edit", extraction_metadata: event.extraction_metadata.merge("area_review_suggestions" => suggestions))
        replay = ingest(source).events.sole
        assert_equal suggestions, replay.extraction_metadata["area_review_suggestions"]
        assert_not_equal "Unreviewed local edit", replay.title
        assert_nil replay.reviewed_by_id
        assert replay.pending_review?

        revised = ingest(article("<p>26.10.2026. od 08:00 do 15:00 prekid vodosnabdijevanja u Izmišljenom polju.</p>")).events.sole
        assert_nil revised.extraction_metadata["area_review_suggestions"]
      end

      private

      def approve(event)
        event.approve_answers!(actor: @admin, expected_version: event.content_version, review_token: event.answer_review_token)
      end

      def correct(event, attributes = {})
        CityServiceEventReview.new(event:, actor: @admin, attributes: {
          "content_version" => event.content_version, "review_token" => event.answer_review_token,
          "facts_reviewed" => "1", "review_note" => "Provjereni termin i područje u potpunom izvornom članku.",
          "event_type" => "planned_interruption", "severity" => "service_outage", "lifecycle" => "scheduled",
          "targeting_level" => "mz", "area_ids" => [@area.id.to_s],
          "starts_at_local" => "2026-10-26T08:00:00+01:00", "ends_at_local" => "2026-10-26T14:00:00+01:00"
        }.merge(attributes)).call
      end

      def ingest(article)
        @ingestor.ingest_article(source: @source, article:, fetched_at: Time.current)
      end

      def old_article
        article("<p>25.10.2026. od 01:00 do 04:00 prekid vodosnabdijevanja u Izmišljenom polju zbog radova.</p>")
      end

      def revised_article
        article("<p>26.10.2026. od 08:00 do završetka radova prekid vodosnabdijevanja u Izmišljenom polju.</p>" \
                "<p>26.10.2026. od 15:00 do 16:00 prekid vodosnabdijevanja u Izmišljenom polju zbog drugih radova.</p>")
      end

      def article(body)
        CityServiceArticle.extract(html: "<article>#{body}</article>",
                                   source_url: "https://water.example.invalid/v2/notices/reviewed-revision/").sole
      end

      def feed(date)
        zone = Time.find_zone!(CityServiceTime::ZONE)
        first = zone.local(date.year, date.month, date.day)
        last = first.advance(days: 1)
        CityServiceEventFeed.new(organization: @organization).query(topic: "water", area_identifiers: [@area.slug], starts_at: first, ends_at: last, deadline: nil)
      end
    end
  end
end
