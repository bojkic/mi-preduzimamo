# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceAutomationSafetyTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-automation", name: { "sr" => "Test" })
        @source = CityServiceSources.fetch("electricity_outages")
        @event = CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages", source_label: "Izmišljeni izvor struje",
                                          source_fingerprint: "automation", source_url: @source.fetch(:source_url), event_type: "planned_outage", severity: "service_outage",
                                          targeting_level: "komsiluk", affected_area_slugs: [@area.slug], affected_text: "Test",
                                          title: "Planirani prekid", summary: "Planirani prekid u području Test",
                                          starts_at: 2.hours.from_now, ends_at: 7.hours.from_now, fetched_at: Time.current, state: "pending_review", lifecycle: "scheduled",
                                          parser_version: "fixture", content_version: "v1", extraction_metadata: { "complete" => true, "source_snapshot_complete" => true,
                                                                                                                   "coverage" => { "status" => "resolved",
                                                                                                                                   "source_content_version" => "v1" },
                                                                                                                   "confidence_by_field" => { "place" => "reviewed_alias" } })
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "electricity_outages", status: :unreviewed, notices: [], checked_at: Time.current)
        CityServiceSourceCheckStore.new.record(check:, source: @source)
        @automation = CityServiceAutomation.new(organization: @organization)
        @policy = CityServiceAutomationPolicy.new(organization: @organization)
      end

      test "off and shadow modes record eligibility without posts or delivery effects" do
        %w(off shadow).each do |mode|
          assert_equal :updated, @policy.update!(source_key: "electricity_outages", mode:, actor: @admin)
          assert_no_difference ["Decidim::Bih::KomsilukPost.count", "CityServiceEffect.count"] do
            decision = @automation.evaluate!(@event)
            assert_equal "eligible", decision.outcome, decision.blockers.inspect
            assert_equal mode, decision.mode
          end
        end
      end

      test "automatic publication creates one projection and durable board effect with no Viber authorization" do
        assert_equal :updated, @policy.update!(source_key: "electricity_outages", mode: "automatic", actor: @admin)
        decision = @automation.evaluate!(@event)
        assert_equal "published", decision.outcome, decision.blockers.inspect
        assert_equal "board_published", @event.reload.state
        assert_nil @event.reviewed_by_id
        assert_nil @event.reviewed_at
        assert_equal CityServiceAutomationPolicy::VERSION, @event.extraction_metadata.dig("automation_publication", "policy_version")
        assert_equal 1, @event.incident.projections.count
        assert_equal 0, CityServiceEffect.where(kind: "fallback").count
        assert_no_difference(["CityServiceProjection.count", "CityServiceEffect.count"]) { @automation.evaluate!(@event) }
      end

      test "stale future partial and changed-parser snapshots block automation" do
        snapshot = DecidimApp::CityServiceSourceSnapshot.find_by!(source_key: "electricity_outages")
        original = snapshot.attributes.slice("last_success_at", "source_version", "check_payload")
        [{ last_success_at: 10.days.ago }, { last_success_at: 1.hour.from_now }, { source_version: "old-parser" },
         { check_payload: snapshot.check_payload.merge("error_code" => "partial_source_coverage") }].each do |attributes|
          snapshot.update!(original.merge(attributes.stringify_keys))
          assert_includes @automation.blockers(@event), "source_not_current_and_complete"
        end
      end

      test "routine source families are configurable but need current rule evidence" do
        %w(electricity_outages water_service road_conditions city_official_notices).each do |source_key|
          assert_equal :updated, @policy.update!(source_key:, mode: "shadow", actor: @admin)
          assert_equal :updated, @policy.update!(source_key:, mode: "automatic", actor: @admin)
        end
        assert_equal :invalid_selection, @policy.update!(source_key: "weather_warnings", mode: "automatic", actor: @admin)
        assert_equal :invalid_selection, @policy.update!(source_key: "heating_service", mode: "automatic", actor: @admin)
        assert_equal "off", @policy.mode("heating_service")

        @event.update!(source_key: "road_conditions")
        assert_includes @automation.blockers(@event), "routine_profile_required"
        @event.update!(source_key: "city_official_notices")
        assert_includes @automation.blockers(@event), "ai_review_required"
      end

      test "city model evidence must belong to the exact stored facts" do
        @event.update!(source_key: "city_official_notices", extraction_metadata: @event.extraction_metadata.merge(
          "source_document_complete" => true, "ai_source_text" => "Complete public article",
          "ai_classification" => { "status" => "accepted", "source_content_version" => "old",
                                   "publish" => true, "needs_review" => false,
                                   "event_type" => "planned_outage", "severity" => "service_outage",
                                   "delivery_recommendation" => "board_only" }
        ))
        assert_includes @automation.blockers(@event), "ai_review_required"
        @event.update!(extraction_metadata: @event.extraction_metadata.deep_merge(
          "ai_classification" => { "source_content_version" => "v1",
                                   "version" => CityServiceAiAssessment::VERSION,
                                   "source_article_hash" => Digest::SHA256.hexdigest("Complete public article") }
        ))
        refute_includes @automation.blockers(@event), "ai_review_required"
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("ai_source_text" => "Revised public article"))
        assert_includes @automation.blockers(@event), "ai_review_required"
      end

      test "weather source remains a human decision even if a future parser labels it routine" do
        @event.update!(source_key: "weather_warnings", severity: "service_outage")
        assert_includes @automation.blockers(@event), "human_review_required"
        assert_includes @automation.blockers(@event), "source_not_in_automatic_cohort"
      end

      test "different organization cannot apply its automation policy to this event" do
        other = CityServiceAutomation.new(organization: create_organization)
        assert_raises(ArgumentError) { other.evaluate!(@event) }
      end

      test "unknown extent and human warnings remain reviewed even with complete source" do
        @event.update!(severity: "emergency", extraction_metadata: @event.extraction_metadata.merge("requires_human_review" => true))
        assert_includes @automation.blockers(@event), "human_review_required"
        @event.update!(severity: "service_outage", extraction_metadata: @event.extraction_metadata.merge("coverage" => { "status" => "partial" }))
        assert_includes @automation.blockers(@event), "unresolved_coverage"
      end

      test "water board automation accepts exactly the boards justified by every named clause" do
        second = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-second", name: { "sr" => "Second" })
        clauses = ["Izmišljena ulica (Testni grad)", "Izmišljeni zaselak (Testno selo)"]
        water_coverage!(clauses:, board_slugs: [[@area.slug, second.slug], [second.slug]])
        refute_includes @automation.blockers(@event), "coverage_requires_review"
        refute_includes @automation.blockers(@event), "unresolved_coverage"
        assert_equal [@area.slug, second.slug], CityServiceEventPreview.new(@event).board_target_slugs

        @event.update!(affected_area_slugs: [@area.slug])
        assert_includes @automation.blockers(@event), "coverage_requires_review"
      end

      test "incomplete water clause and unqualified copy keep board automation in review" do
        clauses = ["Izmišljena ulica (Testni grad)", "nejasna lokacija"]
        water_coverage!(clauses:, board_slugs: [[@area.slug], []])
        assert_includes @automation.blockers(@event), "coverage_requires_review"

        water_coverage!(clauses: ["Izmišljena ulica (Testni grad)"], board_slugs: [[@area.slug]])
        refute_includes @automation.blockers(@event), "coverage_requires_review"
        @event.update!(summary: "Whole area loses water")
        assert_includes @automation.blockers(@event), "coverage_requires_review"

        water_coverage!(clauses: ["Izmišljena ulica (Testni grad)"], board_slugs: [[@area.slug]])
        @event.update!(affected_text: "Izmišljena ulica (Testni grad); ")
        assert_includes @automation.blockers(@event), "coverage_requires_review"
      end

      private

      def water_coverage!(clauses:, board_slugs:)
        url = "https://water.example.invalid/v2/notices/synthetic-coverage/"
        revision = CityServiceWaterMixedCoverage.new(organization: @organization).revision
        rows = clauses.zip(board_slugs).map do |evidence, slugs|
          { "evidence" => evidence, "kind" => evidence.end_with?("(Testni grad)") ? "street" : "settlement_part",
            "status" => slugs.any? ? "resolved" : "unresolved", "board_slugs" => slugs }
        end
        mapped = board_slugs.flatten.uniq.sort
        coverage = { "status" => rows.all? { |row| row["status"] == "resolved" } ? "resolved" : "partial",
                     "complete" => rows.all? { |row| row["status"] == "resolved" }, "scope" => "source_named_water_locations",
                     "scope_precision" => "unspecified_street_segment", "board_placement" => rows.all? { |row| row["status"] == "resolved" } ? "verified_full_geometry_intersection" : "review_required",
                     "water_mixed_coverage_revision" => revision, "source_content_version" => "v1",
                     "clause_count" => clauses.size, "resolved_clause_count" => rows.count { |row| row["status"] == "resolved" },
                     "unresolved_clause_count" => rows.count { |row| row["status"] == "unresolved" }, "clauses" => rows,
                     "affected_places" => mapped.map { |slug| { "slug" => slug, "kind" => "komsiluk" } },
                     "unresolved_places" => rows.select { |row| row["status"] == "unresolved" }, "ambiguous_places" => [] }
        @event.update!(source_key: "water_service", source_url: url, affected_text: clauses.join("; "), targeting_level: "komsiluk",
                       affected_area_slugs: mapped, title: "Mogući prekidi vode — dio komšiluka",
                       summary: "Prekid vode može zahvatiti dio komšiluka. #{clauses.join('; ')}",
                       viber_text: "Prekid vode može zahvatiti dio komšiluka. #{clauses.join('; ')}",
                       extraction_metadata: { "source_snapshot_complete" => true, "canonical_article_url" => url,
                                              "water_board_copy" => { "source_content_version" => "v1", "original" => { "title" => "Voda" } },
                                              "coverage" => coverage, "confidence_by_field" => { "place" => "verified_water_location_geometry" } })
      end
    end
  end
end
