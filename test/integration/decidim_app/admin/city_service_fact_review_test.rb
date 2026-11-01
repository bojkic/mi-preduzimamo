# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require "capybara/rails"

module DecidimApp
  module Admin
    class CityServiceFactReviewTest < ActionDispatch::IntegrationTest
      include SyntheticEventSourceRegistry
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        travel_to Time.iso8601("2026-09-09T07:00:00+02:00")
        @organization = create_organization
        host! @organization.host
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-synthetic-field", name: { "sr" => "Izmišljeno polje" })
        @event = Bijeljina::CityServiceEvent.create!(
          organization: @organization, source_key: "electricity_outages", source_fingerprint: "review-facts",
          content_version: "provider-v1", parser_version: "test-v1", event_type: "planned_outage", severity: "service_outage",
          title: "Izmišljeno polje", summary: "Izvorni opis", affected_text: "Izmišljeno polje", targeting_level: "unknown", lifecycle: "unknown",
          extraction_metadata: { "source_snapshot_complete" => true, "source_document_url" => "https://provider.example/document" }
        )
        sign_in @admin
      end

      teardown { travel_back }

      test "reusable coverage requires explicit opt-in and a bounded expiry" do
        @event.update!(source_url: "https://provider.example/document")
        correct(reuse_coverage: "1", coverage_valid_until: "2026-10-09")
        assert @event.reload.extraction_metadata.dig("operator_review", "reuse_coverage")
        assert_equal "2026-10-09", @event.extraction_metadata.dig("operator_review", "coverage_valid_until")
        assert @event.pending_review?
        correct(reuse_coverage: "1", coverage_valid_until: "2030-01-01")
        assert_equal "2026-10-09", @event.reload.extraction_metadata.dig("operator_review", "coverage_valid_until")
        correct(reuse_coverage: "1", coverage_valid_until: "")
        assert_equal "2026-10-09", @event.reload.extraction_metadata.dig("operator_review", "coverage_valid_until")
      end

      test "source evidence displays familiar contextual place names without treating them as confirmed areas" do
        @event.update!(affected_text: "1 NN izlaz", extraction_metadata: @event.extraction_metadata.merge("feeder" => "TS IZMIŠLJENO POLJE TEST"))
        Bijeljina::CityServiceAreaPreparation.new(organization: @organization).call(events: [@event])
        get "/admin/bih/city-alerts"
        assert_response :success
        assert_select "[data-city-place-context='true']", text: /Izmišljeno polje.*TS IZMIŠLJENO POLJE TEST/m
        assert_select "#city-service-event-#{@event.id} .city-alerts-col-areas .city-alerts-area-unknown", count: 0
        assert_select "[data-city-place-context='true']", text: /#{Regexp.escape(I18n.t("decidim_app.admin.city_service_events.source_evidence.place_context_note"))}/
        assert_select "[data-city-proposed-area]", count: 0
        assert_equal "unknown", @event.reload.targeting_level
        assert_nil @event.reviewed_at

        @event.update!(content_version: "new-provider-version")
        get "/admin/bih/city-alerts"
        assert_select "[data-city-place-context='true']", count: 0
      end

      test "area proposals exclude stale coverage and context-only places" do
        @event.update!(extraction_metadata: { "coverage" => {
                         "source_content_version" => @event.content_version, "affected_places" => [{ "slug" => @area.slug }]
                       } })
        get "/admin/bih/city-alerts"
        assert_select "[data-city-proposed-area][value='#{@area.id}']", count: 1
        assert_select "select[name='city_service_event[area_ids][]'] option[selected]", count: 0
        @event.update!(content_version: "new-version")
        get "/admin/bih/city-alerts"
        assert_select "[data-city-proposed-area]", count: 0
      end

      test "review token remains stable across persisted record reload" do
        @event.update!(starts_at: Time.utc(2026, 9, 9, 6), ends_at: Time.utc(2026, 9, 9, 12))
        token = @event.answer_review_token
        Time.use_zone("UTC") { assert_equal token, @event.class.find(@event.id).answer_review_token }
        Time.use_zone("Europe/Sarajevo") { assert_equal token, @event.class.find(@event.id).answer_review_token }
      end

      test "operator corrects all facts without fanout and separately approves while retaining provider originals" do
        original = @event.attributes.slice(*Bijeljina::CityServiceEventReview::FACT_FIELDS)
        get "/admin/bih/city-alerts", params: { tab: "review" }
        assert_no_enqueued_jobs { correct }
        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        @event.reload
        assert @event.pending_review?
        assert_equal "provider-v1", @event.content_version
        assert_equal [@area.slug], @event.area_slugs
        assert_equal [@area.id], @event.extraction_metadata.dig("operator_review", "place_ids")
        assert_nil @event.extraction_metadata.dig("operator_review", "note")
        assert_equal original, @event.extraction_metadata.dig("operator_review", "original", "facts")
        assert_equal "operator_correction", @event.extraction_metadata.dig("operator_review", "provenance")
        assert_equal "resolved", @event.extraction_metadata.dig("coverage", "status")
        assert_equal @area.slug, @event.extraction_metadata.dig("coverage", "affected_places", 0, "slug")
        assert_equal Time.utc(2026, 9, 9, 6), @event.starts_at
        assert @event.answer_approvable?
        assert_no_enqueued_jobs { approve }
        assert @event.reload.answer_approved?
        assert_nil @event.published_at
        assert_empty @event.komsiluk_post_id_values
      end

      test "a corrected unresolved clock can use complete raw evidence without altering incomplete extraction flags" do
        @event.update!(extraction_metadata: { "source_snapshot_complete" => false, "complete" => false,
                                              "source_document_complete" => true, "temporal_status" => "unknown_clock", "raw_from" => "?" })
        correct
        assert @event.reload.answer_approvable?
        assert_equal false, @event.extraction_metadata["complete"]
        assert_equal false, @event.extraction_metadata["source_snapshot_complete"]
        assert_equal "?", @event.extraction_metadata.dig("operator_review", "original", "extraction_metadata", "raw_from")
      end

      test "operator correction cannot certify a partial raw document or unrelated extraction failure" do
        @event.update!(extraction_metadata: { "source_snapshot_complete" => false, "complete" => false,
                                              "source_document_complete" => false, "temporal_status" => "unknown_clock" })
        correct
        assert_not @event.reload.answer_approvable?
        approve
        assert @event.reload.pending_review?
        @event.update!(extraction_metadata: { "source_snapshot_complete" => false, "complete" => false,
                                              "source_document_complete" => true, "temporal_status" => "missing_article" })
        correct
        assert_not @event.reload.answer_approvable?
      end

      test "stale provider revision and displayed facts tokens reject atomic correction" do
        correct(content_version: "old-provider")
        assert_nil @event.reload.starts_at
        token = @event.answer_review_token
        @event.update!(summary: "New local facts")
        correct(review_token: token, summary: "Stale overwrite")
        assert_equal "New local facts", @event.reload.summary
        assert_nil @event.starts_at
        assert_nil @event.reviewed_at
        correct(review_token: nil)
        assert_nil @event.reload.starts_at
      end

      test "foreign area IDs mixed kinds and arbitrary type reject all changes" do
        foreign = Decidim::Bih::LocalArea.create!(organization: create_organization, kind: "mz", slug: "foreign", name: { "sr" => "Foreign" })
        correct(area_ids: [foreign.id])
        assert_nil @event.reload.starts_at
        correct(targeting_level: "komsiluk")
        assert_nil @event.reload.starts_at
        correct(event_type: "made_up", title: "Must not change")
        assert_equal "Izmišljeno polje", @event.reload.title
      end

      test "citywide requires an explicit empty selection" do
        correct(targeting_level: "citywide")
        assert_equal "unknown", @event.reload.targeting_level
        correct(targeting_level: "citywide", area_ids: [""])
        assert_equal "citywide", @event.reload.targeting_level
        assert_empty @event.area_slugs
        assert @event.answer_approvable?
      end

      test "DST gap fold missing note and reversed interval are rejected atomically" do
        [
          { starts_at_local: "2026-03-29T02:30", ends_at_local: "2026-03-29T04:00" },
          { starts_at_local: "2026-03-29T02:30+01:00", ends_at_local: "2026-03-29T04:00+02:00" },
          { starts_at_local: "2026-10-25T02:30", ends_at_local: "2026-10-25T04:00" },
          { starts_at_local: "2026-09-09T14:00", ends_at_local: "2026-09-09T08:00" },
          { review_note: "" },
          { starts_at_local: "2026-02-30T08:00" }
        ].each do |invalid|
          correct(**invalid, title: "Do not save")
          assert_nil @event.reload.starts_at, invalid.inspect
          assert_equal "Izmišljeno polje", @event.title
        end
      end

      test "explicit correct fold offsets disambiguate and mismatched local zone offsets are rejected" do
        correct(starts_at_local: "2026-10-25T02:30+02:00", ends_at_local: "2026-10-25T02:30+01:00")
        assert_equal 1.hour, @event.reload.ends_at - @event.starts_at
        starts_at = @event.starts_at
        correct(starts_at_local: "2026-09-09T08:00+01:00")
        assert_equal starts_at, @event.reload.starts_at
      end

      test "approved events require revocation before correction and foreign events remain inaccessible" do
        correct
        approve
        correct(title: "Cannot edit approved")
        assert_equal "Izmišljeno polje", @event.reload.title
        @event.update!(organization: create_organization, state: "pending_review")
        correct
        assert_response :not_found
        citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        result = Bijeljina::CityServiceEventReview.new(event: @event, actor: citizen, attributes: {}).call
        assert_equal :not_authorized, result
      end

      test "correction UI includes type dates kind IDs and displayed facts receipt" do
        get "/admin/bih/city-alerts"
        assert_response :success
        assert_select "details[data-city-review-facts='#{@event.id}']" do
          assert_select "select[name='city_service_event[event_type]']"
          assert_select "select[name='city_service_event[targeting_level]']"
          assert_select "select[name='city_service_event[area_ids][]'] option[value='#{@area.id}']"
          assert_select "input[type=hidden][name='city_service_event[area_ids][]'][value='']"
          assert_select "input[name='city_service_event[starts_at_local]']"
          assert_select "input[name='city_service_event[ends_at_local]']"
        end
        assert_select "input[name='city_service_event[review_token]'][value='#{@event.answer_review_token}']"
      end

      test "document history includes unpaired withdrawals only for same tenant source document and is bounded" do
        versions = 10.times.map do |index|
          @event.dup.tap do |previous|
            previous.assign_attributes(source_fingerprint: "old-#{index}", state: "superseded", lifecycle: "superseded",
                                       extraction_metadata: { "source_withdrawal" => { "document_url" => "https://provider.example/document" } })
            previous.save!
          end
        end
        current = @event.dup
        current.update!(source_fingerprint: "new-current")
        assert_equal versions.last(8).reverse.map(&:id), current.review_document_history.map(&:id)
        versions.last.update!(organization: create_organization)
        assert_not_includes current.review_document_history.map(&:id), versions.last.id
        versions[-2].update!(source_key: "water_outages")
        assert_not_includes current.review_document_history.map(&:id), versions[-2].id
      end

      private

      def correct(**overrides)
        attributes = {
          content_version: @event.content_version, review_token: @event.answer_review_token, facts_reviewed: "1",
          event_type: "planned_outage", severity: "service_outage", lifecycle: "scheduled", targeting_level: "mz", area_ids: [@area.id],
          starts_at_local: "2026-09-09T08:00+02:00", ends_at_local: "2026-09-09T14:00+02:00", review_note: "Provjeren red izvornog dokumenta."
        }.merge(overrides)
        patch "/admin/bih/city-alerts/#{@event.id}", params: { city_service_event: attributes }
      end

      def approve
        post "/admin/bih/city-alerts/#{@event.id}/approve-answers", params: { content_version: @event.content_version, review_token: @event.answer_review_token }
      end
    end
  end
end
