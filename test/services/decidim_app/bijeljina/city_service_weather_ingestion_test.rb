# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require_relative "../../../support/synthetic_weather_region"

module DecidimApp
  module Bijeljina
    class CityServiceWeatherIngestionTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include SyntheticWeatherRegion
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        install_synthetic_weather_region
        write_synthetic_weather_region(organization_host: @organization.host,
                                       source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url))
        @now = Time.utc(2040, 9, 19, 8)
        travel_to @now
        @ingestor = CityServiceEventIngestor.new(organization: @organization)
      end

      teardown do
        restore_synthetic_weather_region
        travel_back
      end

      test "CAP reingestion is idempotent and preserves authoritative provenance" do
        first = ingest.events.sole
        second = ingest.events.sole
        assert_equal first.id, second.id
        assert_equal Digest::SHA256.hexdigest(feed), first.extraction_metadata.fetch("source_document_raw_sha256")
        assert_equal "body_region_review_and_board_policy", first.extraction_metadata.fetch("source_document_version_basis")
        assert first.extraction_metadata["source_snapshot_complete"]
        assert first.extraction_metadata["source_document_complete"]
        assert_equal CityServiceSources.fetch("weather_warnings")[:source_url], first.extraction_metadata["source_document_url"]
        assert_equal "unknown", first.targeting_level
        assert first.extraction_metadata["requires_human_review"]
      end

      test "new complete CAP membership withdraws old notice but malformed input preserves it" do
        first = ingest.events.sole
        first.update!(state: "board_published")
        assert_raises(CityServiceNoticeCollector::ParserError) { ingest(body: "broken CAP") }
        assert first.reload.board_published?
        second = ingest(body: feed(identifier: "warning-2")).events.sole
        assert first.reload.superseded?
        assert second.pending_review?
        assert_equal "complete_source_snapshot_changed", first.extraction_metadata.dig("source_withdrawal", "reason")
      end

      test "changed region review withdraws an older published candidate and requires a fresh review" do
        first = ingest.events.sole
        first.update!(state: "board_published")
        write_synthetic_weather_region(organization_host: @organization.host,
          source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url), region_label: "Druga autorska pregledana regija")
        second = ingest.events.sole
        assert_not_equal first.id, second.id
        assert first.reload.superseded?
        assert second.pending_review?
        assert_equal "unknown", second.targeting_level
        assert second.extraction_metadata.fetch("requires_human_review")
      end

      test "changed weather review invalidates a previously confirmed model receipt before a source refresh" do
        event = ingest.events.sole
        event.mark_reviewed!(actor: @admin, note: "Autorski pregled")
        assert event.weather_region_review_current?
        assert event.facts_confirmed?
        assert event.current_source_reviewed?
        token = event.answer_review_token
        change_weather_review
        assert_not event.reload.weather_region_review_current?
        assert_not event.source_evidence_complete?
        assert_not event.facts_confirmed?
        assert_not event.current_source_reviewed?
        assert_equal :weather_region_review_changed, event.publication_blocker
        assert_not_equal token, event.answer_review_token
      end

      test "expired malformed missing other organization and other source weather reviews cannot reuse retained events" do
        event = ingest.events.sole
        base = { organization_host: @organization.host, source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url) }
        [{ valid_until: "2040-09-18" }, { review_state: "pending" }, { organization_host: "other.example.invalid" },
         { source_url: "https://other-weather.example.invalid/feed" }].each do |changes|
          write_synthetic_weather_region(**base.merge(changes))
          assert_not event.weather_region_review_current?
          assert_equal :weather_region_review_changed, event.publication_blocker
        end
        File.write(@synthetic_weather_region_path, "{SYNTHETIC_PRIVATE_MARKER")
        assert_not event.weather_region_review_current?
        ENV.delete("MI_WEATHER_REGION_CONFIG_PATH")
        assert_not event.weather_region_review_current?
      end

      test "stale weather answer approval is rejected while a valid approval can still be revoked after review changes" do
        event = ingest.events.sole
        event.update!(targeting_level: "citywide", affected_area_slugs: [])
        token = event.answer_review_token
        change_weather_review
        assert_equal :stale_review, event.approve_answers!(actor: @admin, expected_version: event.content_version, review_token: token)
        assert_equal :incomplete_evidence, event.approve_answers!(actor: @admin, expected_version: event.content_version, review_token: event.answer_review_token)
        restore_weather_review
        assert_equal :approved, event.approve_answers!(actor: @admin, expected_version: event.content_version, review_token: event.answer_review_token)
        change_weather_review
        assert_equal :revoked, event.revoke_answers!(actor: @admin, expected_version: event.content_version, review_token: event.answer_review_token)
        assert event.reload.pending_review?
      end

      test "fresh weather review form and approval preview cannot override an obsolete regional extraction" do
        event = ingest.events.sole
        change_weather_review
        attributes = { "content_version" => event.content_version, "review_token" => event.answer_review_token,
                       "review_note" => "Autorski novi pregled" }
        assert_equal :stale_review, CityServiceEventReview.new(event:, actor: @admin, attributes:).call
        preview_factory = ->(*) { raise "Stale regional review must not query audiences" }
        CityServiceEventPreview.stub(:new, preview_factory) do
          result = CityServiceApprovalPreview.new(event:, actor: @admin, attributes:).call
          assert_equal :stale_review, result.status
        end
        assert_nil event.reload.reviewed_at
      end

      test "bulk review refuses changed weather scope while explicit dismissal remains possible" do
        event = ingest.events.sole
        change_weather_review
        receipt = { event.id.to_s => { "content_version" => event.content_version, "review_token" => event.answer_review_token } }
        result = CityServiceBulkReview.new(organization: @organization, actor: @admin, action: "review", selections: receipt, note: "Autorski pregled").call
        assert_equal :stale_review, result.status
        assert event.reload.pending_review?
        result = CityServiceBulkReview.new(organization: @organization, actor: @admin, action: "dismiss", selections: receipt, note: "Autorsko odbacivanje").call
        assert_equal :updated, result.status
        assert event.reload.dismissed?
      end

      test "weather publisher stops changed review before creating board posts or delivery work" do
        event = ingest.events.sole
        change_weather_review
        factory = ->(**) { raise "Changed weather review must not reach publication" }
        CityServiceNoticePublisher.stub(:new, factory) do
          result = CityServiceEventPublisher.new(event, actor: @admin, review_token: event.answer_review_token).publish_board!
          assert_equal :not_publishable, result.status
          assert_equal :weather_region_review_changed, result.policy_decision.fetch(:reason)
          assert_equal 0, result.posts_count
          assert_equal 0, result.viber_jobs_count
        end
      end

      test "current delivery revision cannot authorize a send after weather review changes" do
        event = ingest.events.sole
        event.update!(state: "published", extraction_metadata: event.extraction_metadata.merge("publication_revision" => "a" * 64))
        assert event.delivery_current?("a" * 64)
        change_weather_review
        assert_not event.delivery_current?("a" * 64)
        receipt = Struct.new(:fallback_context, :decidim_organization_id, :expires_at, :identity, :decidim_user_id).new(
          { "event_id" => event.id, "event_revision" => "a" * 64 }, @organization.id, @now + 1.hour, "authored-delivery", nil
        )
        sent = false
        CityServicePlatformDeliveryGuard.call(receipt:) { sent = true }
        assert_equal false, sent
      end

      test "weather review changes do not alter another source model receipt or review status" do
        event = ingest.events.sole.dup
        event.source_key = "water_service"
        event.reviewed_at = @now
        event.reviewed_by_id = @admin.id
        event.reviewed_content_version = event.content_version
        token = event.answer_review_token
        assert event.facts_confirmed?
        change_weather_review
        assert_equal token, event.answer_review_token
        assert event.weather_region_review_current?
        assert event.source_evidence_complete?
        assert event.facts_confirmed?
      end

      private

      def change_weather_review
        write_synthetic_weather_region(organization_host: @organization.host,
          source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url), region_label: "Nova autorska pregledana regija")
      end

      def restore_weather_review
        write_synthetic_weather_region(organization_host: @organization.host,
          source_url: CityServiceSources.fetch("weather_warnings").fetch(:source_url))
      end

      def ingest(body: feed)
        @ingestor.ingest(source_key: "weather_warnings", html: body, fetched_at: @now)
      end

      def feed(identifier: "warning-1")
        info = { language: "sr", event: "Oluja", headline: "Upozorenje na oluju", severity: "Severe",
                 onset: "2040-09-19T09:00:00Z", expires: "2040-09-19T18:00:00Z",
                 area: [{ areaDesc: "Izmišljeni provider region", geocode: [{ valueName: "EMMA_ID", value: "TEST-REGION-A" }] }] }
        alert = { sender: "test-provider", identifier:, sent: "2040-09-19T07:00:00Z",
                  status: "Actual", scope: "Public", msgType: "Alert", info: [info] }
        { warnings: [{ alert: }] }.to_json
      end
    end
  end
end
