# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require "capybara"

module DecidimApp
  module Admin
    class CityServiceEvidenceTest < ActionDispatch::IntegrationTest
      include SyntheticEventSourceRegistry
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        sign_in @admin
        @event = create_event
      end

      test "operator sees source dates feeder affected text and the exact current content version" do
        get "/admin/bih/city-alerts"

        assert_response :success
        assert_select "[data-city-source-evidence='#{@event.id}']" do
          assert_select "dd", text: /TS IZMIŠLJENI VRT 6/
          assert_select "dd", text: /1 NN izlaz/
          assert_select "code", text: "content-v2"
        end
        assert_select "input[name='city_service_event[content_version]'][value='content-v2']"
        assert_select "[data-city-review-exception='unknown_area']"
        assert_not_includes response.body, "unapproved-arbitrary-metadata"
      end

      test "feeder name suggestions explicitly say coverage is not confirmed" do
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("area_review_suggestions" => {
                                                                               "source_content_version" => @event.content_version,
                                                                               "candidates" => [{ "slug" => "mz-synthetic-garden", "evidence" => "TS IZMIŠLJENI VRT 6",
                                                                                                  "method" => "feeder_context_only" }]
                                                                             }))
        get "/admin/bih/city-alerts"
        assert_response :success
        assert_select "[data-city-area-suggestions] strong", text: I18n.t("decidim_app.admin.city_service_events.source_evidence.feeder_context_only")
        %w(bs hr sr sr-Cyrl en).each do |locale|
          assert I18n.exists?("decidim_app.admin.city_service_events.source_evidence.feeder_context_only", locale, fallback: false)
        end
        assert_equal "unknown", @event.reload.targeting_level
      end

      test "municipal containment evidence exposes citations and remaining unknown locations for current version only" do
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("coverage" => {
                                                                               "crosswalk_revision" => "test", "source_content_version" => @event.content_version,
                                                                               "affected_places" => [{ "slug" => "mz-synthetic-hill", "evidence" => "synthetic-part", "citations" => [
                                                                                 { "url" => "https://www.gradbijeljina.org/synthetic-rules.pdf", "page" => 11, "item" => "6.3" }
                                                                               ] }], "unresolved_places" => [{ "evidence" => "synthetic-unresolved" }]
                                                                             }))
        get "/admin/bih/city-alerts"
        assert_response :success
        assert_select "[data-city-place-containment]" do
          assert_select "li", text: /synthetic-part.*mz-synthetic-hill/m
          assert_select "a[href$='synthetic-rules.pdf']"
          assert_select "p", text: /synthetic-unresolved/
        end
        @event.update!(content_version: "changed-version")
        get "/admin/bih/city-alerts"
        assert_select "[data-city-place-containment]", count: 0
      end

      test "readiness uses only prepared source checks even when all upstream fetches would fail" do
        Bijeljina::CityServiceNoticeCollector.stub(:check, ->(**) { raise "unexpected upstream fetch" }) do
          get "/admin/bih/city-alerts", params: { tab: "readiness" }
        end
        assert_response :success
        assert_select "#admin-city-alert-source-health"
        assert_select "[data-city-source-health='water_service'][data-source-status='unavailable']"
        assert_includes response.body, I18n.t("decidim_app.admin.city_service_events.source_health.description")
      end

      test "prepared reference health applies reader version gate while preserving successful fetch evidence" do
        key = Bijeljina::PublicCallsPreparation.snapshot_key(@organization)
        DecidimApp::CityServiceSourceSnapshot.create!(source_key: key, source_version: "old-parser-version", attempted_at: Time.current,
                                                      last_success_at: Time.current, check_payload: {
                                                        "status" => "ok", "organization_id" => @organization.id, "checked_at" => Time.current.iso8601, "items" => []
                                                      })
        Bijeljina::CityServiceNoticeCollector.stub(:check, ->(**) { raise "unexpected upstream fetch" }) do
          get "/admin/bih/city-alerts", params: { tab: "readiness" }
        end
        assert_response :success
        assert_select "[data-prepared-reference='#{key}'][data-source-status='unavailable'][data-last-attempt-status='ok']" do
          assert_select "small", text: "public_calls_source_version_changed"
        end
      end

      test "older approved facts remain visible in history and link from their unreviewed replacement" do
        previous = create_event(source_fingerprint: "old", content_version: "content-v1", state: "superseded",
                                superseded_by_id: @event.id, lifecycle: "superseded", title: "Ranija verzija")
        get "/admin/bih/city-alerts", params: { exception: "changed_source" }
        assert_response :success
        assert_select "[data-city-review-exception='changed_source']"
        assert_select "#city-service-version-#{previous.id}", text: /Ranija verzija/
        get "/admin/bih/city-alerts", params: { tab: "history" }
        assert_response :success
        assert_select "#city-service-event-#{previous.id}", count: 0
        assert_select "#city-service-event-#{previous.id} form", count: 0
      end

      test "reviewing the current source clears change warnings and filters without erasing history" do
        previous = create_event(source_fingerprint: "prior-reviewed", content_version: "content-v1", state: "superseded",
                                superseded_by_id: @event.id, lifecycle: "superseded")
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("source_document_changed" => true))
        @event.mark_reviewed!(actor: @admin, note: "Reviewed current source")
        get "/admin/bih/city-alerts"
        assert_select "[data-city-review-exception='changed_source']", count: 0
        assert_select "#city-service-version-#{previous.id}"
        get "/admin/bih/city-alerts", params: { exception: "changed_source" }
        assert_select "#city-service-event-#{@event.id}", count: 0
        @event.update!(content_version: "content-v3")
        get "/admin/bih/city-alerts", params: { exception: "changed_source" }
        assert_select "#city-service-event-#{@event.id}"
        assert_select "[data-city-review-exception='changed_source']"
      end

      test "source names and fact controls have translated labels and record-specific ids" do
        get "/admin/bih/city-alerts"
        assert_select "select[name=source_key] option[value=electricity_outages]", text: I18n.t("decidim_app.admin.city_service_events.ui_review.sources.electricity_outages", locale: :sr)
        %w(event_type severity lifecycle targeting_level).each do |field|
          assert_select "label[for='city_service_event_#{@event.id}_#{field}']", count: 1
          assert_select "select#city_service_event_#{@event.id}_#{field}", count: 1
        end
        assert_select "label", text: /Event type|Targeting level/, count: 0
      end

      test "a stale review tab cannot approve a different content version" do
        patch "/admin/bih/city-alerts/#{@event.id}", params: { city_service_event: { content_version: "content-v1", title: "Stale edit" } }
        assert_redirected_to "/admin/bih/city-alerts?tab=review#city-service-event-#{@event.id}"
        assert_equal "New source version", @event.reload.title
        assert_nil @event.reviewed_content_version
        assert_nil @event.reviewed_at
      end

      test "review of matching version records exactly that version" do
        patch "/admin/bih/city-alerts/#{@event.id}",
              params: { city_service_event: { content_version: "content-v2", review_token: @event.answer_review_token, review_note: "Provjerene izvorne činjenice." } }
        assert_redirected_to "/admin/bih/city-alerts?tab=review"
        assert_equal "content-v2", @event.reload.reviewed_content_version
        assert_equal @admin.id, @event.reviewed_by_id
      end

      test "exceptions and revision history stay scoped to the current organization" do
        other = create_organization
        private_event = create_event(organization: other, source_fingerprint: "other-tenant", title: "Other organization draft")
        get "/admin/bih/city-alerts", params: { tab: "all", exception: "unknown_area" }
        assert_response :success
        assert_not_includes response.body, private_event.title
        patch "/admin/bih/city-alerts/#{private_event.id}", params: { city_service_event: { content_version: "content-v2", title: "Wrong tenant" } }
        assert_response :not_found
      end

      private

      def create_event(**attributes)
        Bijeljina::CityServiceEvent.create!({
          organization: @organization, source_key: "electricity_outages", source_label: "Izmišljeni izvor electricity_outages", provider: "Izmišljeni izvor electricity_outages",
          source_url: "https://electricity-outages.example.invalid/source", source_fingerprint: "fixture-v2",
          source_occurrence_id: "occurrence-1", content_version: "content-v2", parser_version: "electricity_outage_parser_v2",
          event_type: "planned_outage", severity: "service_outage", targeting_level: "unknown", affected_area_slugs: [],
          title: "New source version", summary: "Planirano isključenje.", affected_text: "1 NN izlaz",
          starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, source_published_at: 2.hours.ago, fetched_at: 1.hour.ago,
          extraction_metadata: { "tj" => "TESTNA JEDINICA", "feeder" => "TS IZMIŠLJENI VRT 6", "reason" => "Sanacija mreže", "not_an_allowed_field" => "unapproved-arbitrary-metadata" }
        }.merge(attributes))
      end
    end
  end
end
