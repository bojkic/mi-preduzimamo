# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_read_port_data"

module DecidimApp
  module Bijeljina
    module Milica
      class ReadPortTest < ActiveSupport::TestCase
        include SyntheticReadPortData
        FakeSourceChecker = Struct.new(:checks) do
          def check(**) = checks
        end

        FakeEventFeed = Struct.new(:response, :requests) do
          def query(**attributes)
            requests << attributes
            response
          end
        end

        FakeDuplicateFinder = Struct.new(:reports) do
          def matches(**) = reports
        end

        setup do
          @organization = create_organization
          @now = Time.utc(2040, 9, 16, 12, 0)
          install_synthetic_read_port_data(day: @now.to_date)
        end

        teardown { restore_synthetic_service_directory }

        test "returns a bounded sourced directory fact without claiming live status" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: {},
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          assert_equal %w(id kind text), (%w(id kind text).select { |key| result.facts.first[key].is_a?(String) })
          assert_equal "service_directory", result.facts.first.fetch("kind")
          assert_includes result.warnings, "snapshot_not_live_status"
          assert_equal false, result.validity.fetch("live_status")
          assert_nil result.checked_at
        end

        test "returns the reviewed waste schedule for a Latin area query" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "area_query" => "Izmišljeno selo" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          fact = result.facts.fetch(0)
          assert_equal "waste_schedule", fact.fetch("kind")
          assert_includes fact.fetch("text"), "Izmišljeno selo"
          assert_includes fact.fetch("coverage").fetch("collection_days"), "ponedjeljak"
          assert_equal "2040-09-14", fact.fetch("source_captured_on")
          assert_nil fact["observed_at"], "source capture does not prove a live observation"
          assert_equal "2040-09-14", result.coverage.fetch("source_captured_on")
          assert_equal 2040, result.validity.fetch("schedule_year")
          assert_equal false, result.validity.fetch("live_status")
          assert_equal false, result.validity.fetch("holiday_exceptions")
          assert_includes result.warnings, "snapshot_not_live_status"
          assert_includes result.warnings, "schedule_exceptions_not_in_snapshot"
          assert_includes fact.fetch("text"), I18n.t("decidim.bih.dialogue.waste_schedule_limit", year: 2040, locale: "sr")
          assert_equal "https://community.example.invalid/waste", fact.fetch("source_url")
        end

        # Task 4: WHICH question is being asked decides which source answers it.
        # A retained street used to select the collection-day reader for every
        # waste turn, so a contact question came back as last week's schedule.
        test "a contact or opening-hours question is answered from the directory, not the collection schedule" do
          ["Da li Komunalac radi subotom?", "Koji je broj telefona Komunalca?", "Koja je njihova službena stranica?"].each do |query|
            result = port.call(
              action: "ask_information",
              topic: "waste",
              entities: { "street" => "Ulica Filipa Višnjića", "query" => query },
              context: context(capabilities: ["public_reads"])
            )

            assert_equal "service_directory", result.facts.first&.fetch("kind"), query
          end
        end

        test "a collection-day question over a retained place still reads the schedule" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "area_query" => "Izmišljeno selo", "query" => "Kada se odvozi smeće?" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "waste_schedule", result.facts.fetch(0).fetch("kind")
        end

        test "a negated or live-status request keeps its old path instead of the directory card" do
          ["Ne treba mi njihova stranica", "Koja je službena stranica i ima li trenutno prekida?"].each do |query|
            result = port.call(
              action: "ask_information",
              topic: "water",
              entities: { "area_query" => "Izmišljeno selo", "query" => query },
              context: context(capabilities: ["public_reads"])
            )

            assert_not_equal "service_directory", result.facts.first&.fetch("kind"), query
          end
        end

        test "returns the same waste schedule for a Cyrillic area query" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "area_query" => "Измишљено село" },
            context: context(capabilities: ["public_reads"]),
            locale: "sr-Cyrl"
          )

          assert_equal "ok", result.status
          assert_includes result.facts.fetch(0).fetch("coverage").fetch("collection_days"), "ponedjeljak"
          assert_includes result.facts.fetch(0).fetch("text"), "Измишљено село"
        end

        test "asks which reviewed district contains an ambiguous waste street without merging days" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "query" => "Izmišljena šuma" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ambiguous", result.status
          assert_empty result.facts
          assert_equal [2, 3], result.coverage.fetch("matching_districts").sort
          assert_includes result.warnings, "waste_district_or_street_segment_required"
          assert_includes result.warnings, "schedule_exceptions_not_in_snapshot"
          assert_equal 2040, result.validity.fetch("schedule_year")
        end

        test "new urban waste rows expose their own capture date and exact PDF evidence" do
          result = port.call(action: "ask_information", topic: "waste",
                             entities: { "query" => "Rejon 2 Izmišljena lipa" },
                             context: context(capabilities: ["public_reads"]))

          assert_equal "ok", result.status
          assert_equal ["ponedjeljak"], result.facts.first.dig("coverage", "collection_days")
          assert_equal "2040-09-14", result.facts.first.fetch("source_captured_on")
          assert_nil result.facts.first["observed_at"], "source capture does not prove a live observation"
          assert_equal [7], result.coverage.fetch("source_pdf_pages")
          assert_equal ["synthetic-r2-d1"], result.coverage.fetch("source_route_ids")
          assert_includes result.warnings, "regular_schedule_exceptions_not_verified"
        end

        test "returns a sourced empty result for an unknown waste area" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "street" => "Atlantida" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "empty", result.status
          assert_empty result.facts
          assert_equal "no_reviewed_matching_schedule", result.warnings.last
          assert_equal "2040-09-06", result.coverage.fetch("source_captured_on")
          assert_equal "source:waste_schedule", result.source.fetch("id")
        end

        # Authored typo: an unexplained municipality token must not be
        # silently discarded when the remaining fictional village matches.
        test "a place that explains only part of the query asks instead of answering for a different settlement" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "area_query" => "Bijelna, Izmišljeno selo" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ambiguous", result.status
          assert_empty result.facts
          assert_includes result.warnings, "waste_district_or_street_segment_required"
          assert_not_includes result.warnings, "no_reviewed_matching_schedule", "an unconfirmed place is not an empty source"
        end

        test "a street the schedule holds still answers, labelled as the schedule spells it" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "street" => "Izmišljena lipa" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          fact = result.facts.fetch(0)
          assert_equal ["ponedjeljak"], fact.fetch("coverage").fetch("collection_days")
          assert_includes fact.fetch("text"), "Izmišljena lipa"
          assert_equal ["Измишљена липа"], result.coverage.fetch("matched_places")
        end

        # The label used to echo the query, so the citizen's own misspelling was
        # printed back as the name of the entry we read.
        test "the answer is labelled from the schedule, never from the typing that found it" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "area_query" => "izmišljeno selo" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          assert_includes result.facts.fetch(0).fetch("text"), "Izmišljeno selo"
          assert_equal ["Измишљено село"], result.coverage.fetch("matched_places")
        end

        test "marks a request for another schedule year stale" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "area_query" => "Izmišljeno selo", "date" => "2041-01-04" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "stale", result.status
          assert_empty result.facts
          assert_includes result.warnings, "schedule_year_mismatch"
          assert_nil result.checked_at
          assert_equal 2040, result.validity.fetch("schedule_year")
        end

        test "uses the trusted Sarajevo clock year when no waste date is supplied" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "area_query" => "Izmišljeno selo" },
            context: context(capabilities: ["public_reads"], now: Time.utc(2041, 1, 2, 12, 0))
          )

          assert_equal "stale", result.status
          assert_includes result.warnings, "schedule_year_mismatch"
          assert_equal 2040, result.validity.fetch("schedule_year")
        end

        test "prefers a known area schedule over a broad city coverage gap" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "query" => "Izmišljeno selo, Bijeljina" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          assert_includes result.facts.fetch(0).fetch("coverage").fetch("collection_days"), "ponedjeljak"
          assert_not_includes result.warnings, "partial_coverage"
        end

        test "unconfirmed notice is usable through the real read path with uncertainty and no publication" do
          event = CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages",
                                           source_fingerprint: "unconfirmed-read", source_url: CityServiceSources.fetch("electricity_outages").fetch(:source_url),
                                           event_type: "planned_outage", severity: "service_outage", targeting_level: "unknown",
                                           title: "Prekid struje", summary: "Dio ulice Izmišljena breza", state: "pending_review",
                                           starts_at: @now - 1.hour, ends_at: @now + 2.hours, fetched_at: @now,
                                           parser_version: "test", lifecycle: "scheduled")
          result = port.call(action: "ask_information", topic: "electricity", entities: {},
                             context: context(capabilities: ["public_reads"]), locale: "sr")
          assert_equal "ok", result.status
          fact = result.facts.sole
          assert_equal "service_event:#{event.id}", fact.fetch("id")
          assert_includes fact.fetch("text"), event.summary
          assert_includes fact.fetch("text"), I18n.t("decidim_app.city_service_events.bot.unconfirmed_facts", locale: "sr")
          assert_includes fact.fetch("text"), I18n.t("decidim_app.city_service_events.bot.unconfirmed_area", locale: "sr")
          assert_includes result.warnings, "source_facts_unconfirmed"
          assert_equal "unknown", fact.fetch("coverage").fetch("targeting_level")
          assert_equal "unknown", fact.fetch("coverage").fetch("requested_relation")
          event.update!(starts_at: nil, ends_at: nil)
          uncertain = port.send(:event_fact, event, locale: "sr", now: @now)
          assert_equal "unknown", uncertain.fetch("validity").fetch("precision")
          assert_includes uncertain.fetch("warning_codes"), "event_time_unconfirmed"
          assert_empty event.reload.komsiluk_post_id_values
          assert_nil event.reviewed_by_id
        end

        test "a unique transformer place is partial-area relevance while retaining uncertain source context" do
          area = create_area(slug: "komsiluk-synthetic-forest", name: "Izmišljena šuma")
          event = CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages", content_version: "synthetic-forest-provider-v1",
                                           source_fingerprint: "synthetic-forest-context-read", source_url: CityServiceSources.fetch("electricity_outages").fetch(:source_url),
                                           event_type: "planned_outage", severity: "service_outage", targeting_level: "unknown",
                                           title: "Prekid struje", summary: "1 NN izlaz", affected_text: "1 NN izlaz", state: "pending_review",
                                           starts_at: @now - 1.hour, ends_at: @now + 2.hours, fetched_at: @now,
                                           parser_version: "test", lifecycle: "scheduled", extraction_metadata: { "feeder" => "TS IZMIŠLJENA ŠUMA CENTAR" })
          CityServiceAreaPreparation.new(organization: @organization).call(events: [event])
          result = port.call(action: "ask_information", topic: "electricity", entities: { "area_slug" => area.slug },
                             context: context(capabilities: ["public_reads"]), locale: "sr")
          assert_equal "ok", result.status
          fact = result.facts.sole
          assert_equal "service_event:#{event.id}", fact.fetch("id")
          assert_equal event.source_url, fact.fetch("source_url")
          assert_equal "part", fact.fetch("coverage").fetch("requested_relation")
          place = fact.fetch("coverage").fetch("contextual_places").sole
          assert_equal "Izmišljena šuma", place.fetch("name")
          assert_equal "TS IZMIŠLJENA ŠUMA CENTAR", place.fetch("evidence")
          assert_equal "context_only", place.fetch("relation")
          assert_equal [area.slug], fact.fetch("coverage").fetch("area_slugs")
          assert_equal "part_of_area", fact.fetch("coverage").fetch("affected_relations").sole.fetch("relation")
          assert_includes fact.fetch("text"), I18n.t("decidim_app.city_service_events.bot.place_context", names: "Izmišljena šuma", locale: "sr")
          assert_includes result.warnings, "partial_geographic_coverage"
          assert_not_includes result.warnings, "geographic_scope_unconfirmed"
          assert_nil event.reload.reviewed_by_id
          assert_empty event.komsiluk_post_id_values

          event.update!(content_version: "synthetic-forest-provider-v2")
          CityServiceAreaPreparation.new(organization: @organization).call(events: [event])
          stale = port.send(:event_fact, event.reload, locale: "sr", now: @now, requested_area_slugs: [area.slug])
          assert_empty stale.fetch("coverage").fetch("area_slugs")
          assert_empty stale.fetch("coverage").fetch("affected_relations")
          assert_equal "context_only", stale.fetch("coverage").fetch("requested_relation")
          assert_equal "unknown", event.targeting_level
        end

        test "queries citywide service events when no area is supplied and distinguishes reviewed empty" do
          query = CityServiceEventFeed::ScopedServiceQuery.new(
            status: :empty,
            events: [],
            topic: "water",
            area_identifiers: [],
            starts_at: @now,
            ends_at: @now + 12.hours
          )
          requests = []
          feed = FakeEventFeed.new(query, requests)
          check = CityServiceNoticeCollector::SourceCheckResult.new(
            source_key: "water_service",
            status: :empty,
            notices: [],
            checked_at: @now
          )

          result = port(event_feed: feed, source_checker: FakeSourceChecker.new([check])).call(
            action: "ask_information",
            topic: "water",
            entities: {},
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "empty", result.status
          assert_empty requests.first.fetch(:area_identifiers)
          assert_equal @now, result.checked_at
          assert_equal "source:water_service", result.source.fetch("id")
          assert_includes result.warnings, "no_matching_source_notice"
        end

        test "published city notices retain one or two area OR scope and treat SQL-like slugs as data" do
          reviewer = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          notices = %w(first-area second-area third-area).map do |slug|
            CityServiceEvent.create!(
              organization: @organization, source_key: "water_service", source_fingerprint: "area-scope-#{slug}",
              source_url: CityServiceSources.fetch("water_service").fetch(:source_url),
              event_type: "planned_interruption", severity: "service_outage", targeting_level: "komsiluk",
              affected_area_slugs: [slug], title: "Notice #{slug}", summary: "Reviewed public notice",
              starts_at: @now - 1.hour, ends_at: @now + 2.hours, fetched_at: @now - 1.hour,
              published_at: @now - 30.minutes, reviewed_at: @now - 45.minutes, reviewer: reviewer,
              content_version: "scope-v1", reviewed_content_version: "scope-v1",
              state: "published", parser_version: "test", lifecycle: "ongoing"
            )
          end
          reader_context = context(capabilities: ["public_reads"])
          one = port.published_city_notices(context: reader_context, area_slugs: ["first-area"])
          assert_equal(["service_event:#{notices[0].id}"], one.facts.map { |fact| fact.fetch("id") })
          two = port.published_city_notices(context: reader_context, area_slugs: %w(first-area second-area third-area))
          assert_equal(notices.first(2).map { |event| "service_event:#{event.id}" }, two.facts.map { |fact| fact.fetch("id") })
          assert_equal %w(first-area second-area), two.coverage.fetch("area_slugs")
          injected = port.published_city_notices(context: reader_context, area_slugs: ["first-area' OR TRUE --"])
          assert_equal "empty", injected.status
          assert_empty injected.facts
        end

        test "rejects a location whose purpose is not approved for civic reads" do
          assert_raises(contracts::Invalid) do
            port.call(
              action: "choose_area",
              topic: "neighborhood",
              entities: {},
              context: context(capabilities: ["public_reads"]),
              location: current_location(latitude: 44.756, longitude: 19.216).merge(purpose: "unrelated_turn")
            )
          end
        end

        test "unknown location accuracy is not invented and model provenance is rejected" do
          location = current_location(latitude: 44.756, longitude: 19.216).merge(
            accuracy: nil,
            purpose: "current_location",
            provenance: "legacy_explicit_location"
          )
          assert_nil port.send(:normalize_location, location).fetch("accuracy")
          assert_raises(contracts::Invalid) { port.send(:normalize_location, location.merge(provenance: "model")) }
        end

        test "bounds actor scope validation by the shared wall clock deadline" do
          actor = Struct.new(:id).new(42)
          deadline = Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 0.01)
          subject = port

          result = subject.stub(:actor_for!, ->(_context) { sleep 0.05 }) do
            subject.call(
              action: "ask_information",
              topic: "waste",
              entities: {},
              context: context(actor:, account_state: "registered", capabilities: ["public_reads"], deadline:)
            )
          end

          assert_equal "unavailable", result.status
          assert_includes result.warnings, "deadline_exceeded"
        end

        test "uses the Sarajevo civil clock for an explicit date" do
          local_now = Time.utc(2040, 9, 5, 23, 30)
          query = CityServiceEventFeed::ScopedServiceQuery.new(
            status: :empty,
            events: [],
            topic: "water",
            area_identifiers: [],
            starts_at: Time.zone.local(2040, 9, 6),
            ends_at: Time.zone.local(2040, 9, 7)
          )
          requests = []
          check = CityServiceNoticeCollector::SourceCheckResult.new(
            source_key: "water_service",
            status: :empty,
            notices: [],
            checked_at: local_now
          )

          result = port(
            event_feed: FakeEventFeed.new(query, requests),
            source_checker: FakeSourceChecker.new([check])
          ).call(
            action: "ask_information",
            topic: "water",
            entities: { "date" => "2040-09-06" },
            context: context(capabilities: ["public_reads"], now: local_now)
          )

          assert_equal "empty", result.status
          assert_equal Time.zone.local(2040, 9, 6), requests.first.fetch(:starts_at)
        end

        test "resolves a validated named area without requiring GPS" do
          area = create_area(slug: "komsiluk-centar", name: "Centar")

          result = port.call(
            action: "choose_area",
            topic: "neighborhood",
            entities: { "area_slug" => area.slug },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          assert_equal area.slug, result.facts.first.fetch("area_slug")
          assert_includes result.warnings, "area_selection_grants_no_membership"
        end

        test "keeps conflicting named area and current location ambiguous" do
          named = create_area(
            slug: "komsiluk-named",
            name: "Named",
            boundary: square(19.20, 44.70)
          )
          located = create_area(
            slug: "komsiluk-located",
            name: "Located",
            boundary: square(19.30, 44.80)
          )

          result = port.call(
            action: "choose_area",
            topic: "neighborhood",
            entities: { "area_slug" => named.slug },
            context: context(capabilities: ["public_reads"]),
            location: current_location(latitude: 44.805, longitude: 19.305)
          )

          assert_equal "ambiguous", result.status
          assert_equal [named.slug, located.slug].sort, result.candidates.map { |fact| fact.fetch("area_slug") }.sort
          assert_includes result.warnings, "area_location_conflict"
        end

        test "scopes report status to the trusted actor and omits the status token" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          other_actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          report = Decidim::Bih::Report.create!(
            organization: @organization,
            author: actor,
            description: "Pokvarena rasvjeta"
          )

          own_result = port.call(
            action: "report_status",
            topic: "report",
            entities: { "reference" => report.reference },
            context: context(actor:, account_state: "registered", capabilities: ["own_report_reads"])
          )
          other_result = port.call(
            action: "report_status",
            topic: "report",
            entities: { "reference" => report.reference },
            context: context(actor: other_actor, account_state: "registered", capabilities: ["own_report_reads"])
          )

          assert_equal "ok", own_result.status
          assert_equal report.reference, own_result.facts.first.fetch("reference")
          assert_not_includes own_result.facts.first.fetch("destination"), report.status_token
          assert_equal "empty", other_result.status
        end

        test "reads only the assigned neighborhood board for an authorized member" do
          assigned = create_area(slug: "komsiluk-assigned", name: "Assigned")
          other = create_area(slug: "komsiluk-other", name: "Other")
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(assigned, source: "dropdown")
          visible = create_post(area: assigned, title: "Assigned notice")
          create_post(area: other, title: "Other notice")

          result = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: { "area_slug" => assigned.slug },
            context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"])
          )

          assert_equal "ok", result.status
          assert_equal ["komsiluk_post:#{visible.id}"], (result.facts.map { |fact| fact.fetch("id") })
          assert_equal [assigned.slug], result.coverage.fetch("area_slugs")
        end

        test "uses the trusted assigned neighborhood when no area or location is supplied" do
          assigned = create_area(slug: "komsiluk-assigned", name: "Assigned")
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(assigned, source: "dropdown")
          visible = create_post(area: assigned, title: "Assigned notice")

          result = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: {},
            context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"])
          )

          assert_equal "ok", result.status
          assert_equal ["komsiluk_post:#{visible.id}"], (result.facts.map { |fact| fact.fetch("id") })
          assert_equal [assigned.slug], result.coverage.fetch("area_slugs")
        end

        test "explicit area wins over a trusted assignment and cannot read another board" do
          assigned = create_area(slug: "komsiluk-assigned", name: "Assigned")
          requested = create_area(slug: "komsiluk-requested", name: "Requested")
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(assigned, source: "dropdown")
          create_post(area: assigned, title: "Private assigned notice")
          create_post(area: requested, title: "Other notice")

          result = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: { "area_slug" => requested.slug },
            context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"])
          )

          assert_equal "not_authorized", result.status
          assert_includes result.warnings, "requested_area_not_assigned"
          assert_empty result.facts
        end

        test "does not fall back for an unknown area or outside current location" do
          assigned = create_area(slug: "komsiluk-assigned", name: "Assigned")
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(assigned, source: "dropdown")

          unknown = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: { "area_slug" => "komsiluk-missing" },
            context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"])
          )
          outside = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: {},
            context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"]),
            location: current_location(latitude: 0, longitude: 0)
          )

          assert_equal "empty", unknown.status
          assert_includes unknown.warnings, "area_not_found"
          assert_equal "empty", outside.status
          assert_includes outside.warnings, "location_outside_reviewed_areas"
        end

        test "does not resolve an assignment when neighborhood reads are not allowed" do
          assigned = create_area(slug: "komsiluk-assigned", name: "Assigned")
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(assigned, source: "dropdown")
          create_post(area: assigned, title: "Member-only notice")

          result = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: {},
            context: context(actor:, account_state: "registered", capabilities: ["public_reads"])
          )

          assert_equal "not_authorized", result.status
          assert_includes result.warnings, "neighborhood_membership_required"
          assert_empty result.facts
        end

        test "does not silently use an assignment for populated non-area entities" do
          assigned = create_area(slug: "komsiluk-assigned", name: "Assigned")
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(assigned, source: "dropdown")
          create_post(area: assigned, title: "Member-only notice")

          %w(street address).each do |key|
            result = port.call(
              action: "neighborhood_information",
              topic: "neighborhood",
              entities: { key => "some explicit value" },
              context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"])
            )

            assert_equal "ambiguous", result.status, key
            assert_includes result.warnings, "area_required"
            assert_empty result.facts
          end

          result = port.call(action: "neighborhood_information", topic: "neighborhood",
                             entities: { "query" => "Šta ima u mom komšiluku?" },
                             context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"]))
          assert_equal "ok", result.status
          assert_equal [assigned.slug], result.coverage.fetch("area_slugs")
        end

        test "preserves an explicit name and current-location conflict over an assignment" do
          assigned = create_area(slug: "komsiluk-assigned", name: "Assigned")
          named = create_area(slug: "komsiluk-named", name: "Named")
          located = create_area(slug: "komsiluk-located", name: "Located", boundary: square(19.30, 44.80))
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(assigned, source: "dropdown")
          create_post(area: assigned, title: "Member-only notice")

          result = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: { "area_slug" => named.slug },
            context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"]),
            location: current_location(latitude: 44.805, longitude: 19.305)
          )

          assert_equal "ambiguous", result.status
          assert_includes result.warnings, "area_location_conflict"
          assert_empty result.facts
          assert_equal [named.slug, located.slug].sort, result.candidates.map { |fact| fact.fetch("area_slug") }.sort
        end

        test "preserves an unknown explicit name even when GPS resolves the assignment" do
          assigned = create_area(slug: "komsiluk-assigned", name: "Assigned", boundary: square(19.30, 44.80))
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(assigned, source: "dropdown")
          create_post(area: assigned, title: "Member-only notice")

          result = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: { "area_slug" => "komsiluk-missing" },
            context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"]),
            location: current_location(latitude: 44.805, longitude: 19.305)
          )

          assert_equal "empty", result.status
          assert_includes result.warnings, "area_not_found"
          assert_empty result.facts
        end

        test "anonymous or unassigned readers still receive area clarification" do
          result = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: {},
            context: context(capabilities: ["neighborhood_reads"])
          )

          assert_equal "ambiguous", result.status
          assert_includes result.warnings, "area_required"

          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          unassigned = port.call(
            action: "neighborhood_information",
            topic: "neighborhood",
            entities: {},
            context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"])
          )

          assert_equal "ambiguous", unassigned.status
          assert_includes unassigned.warnings, "area_required"
        end

        test "does not resolve an assigned neighborhood across organizations" do
          actor = FactoryBot.create(:user, :confirmed, organization: create_organization)

          assert_raises(contracts::Invalid) do
            port.call(
              action: "neighborhood_information",
              topic: "neighborhood",
              entities: {},
              context: context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"])
            )
          end
        end

        test "nearby duplicate projection excludes private report fields" do
          report = Struct.new(:reference, :status, :category, :created_at, :description, :reporter_contact)
                         .new("BR-2040-0042", "u_obradi", "putevi", @now, "Private details", "+387...")
          result = port(duplicate_finder: FakeDuplicateFinder.new([report])).call(
            action: "report_problem",
            topic: "report",
            entities: { "category" => "putevi" },
            context: context(capabilities: ["report_guidance"]),
            location: current_location(latitude: 44.756, longitude: 19.216)
          )

          assert_equal "ok", result.status
          fact = result.facts.first
          assert_equal %w(category destination id kind observed_at reference source_id source_label status text warning_codes), fact.keys.sort
          assert_not_includes fact.values.map(&:to_s), "Private details"
          assert_not fact.has_key?("latitude")
          assert_not fact.has_key?("longitude")
        end

        test "rejects an actor from another organization" do
          actor = FactoryBot.create(:user, :confirmed, organization: create_organization)

          assert_raises(contracts::Invalid) do
            port.call(
              action: "report_status",
              topic: "report",
              entities: { "reference" => "BR-2040-0001" },
              context: context(actor:, account_state: "registered", capabilities: ["own_report_reads"])
            )
          end
        end

        test "does not accept a future source check as freshness" do
          check = CityServiceNoticeCollector::SourceCheckResult.new(
            source_key: "public_transport",
            status: :unreviewed,
            notices: [],
            checked_at: @now + 1.hour,
            error_code: :not_reviewed
          )

          result = port(source_checker: FakeSourceChecker.new([check])).call(
            action: "ask_information",
            topic: "transport",
            entities: { "stop" => "Centar", "area_query" => "Izmišljeno selo" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "unreviewed", result.status
          assert_nil result.checked_at
        end

        test "fails closed when a transport notice points outside its reviewed source host" do
          unsafe = CityServiceNoticeCollector::Notice.new(
            source_key: "public_transport",
            source_label: "Public transport",
            provider: "Grad Bijeljina",
            title: "Javni prevoz: P1",
            body: "",
            url: "https://evil.example/route.pdf",
            fingerprint: "unsafe",
            fetched_at: @now
          )
          check = CityServiceNoticeCollector::SourceCheckResult.new(
            source_key: "public_transport",
            status: :ok,
            notices: [unsafe],
            checked_at: @now
          )

          result = port(source_checker: FakeSourceChecker.new([check])).call(
            action: "ask_information",
            topic: "transport",
            entities: { "stop" => "Centar", "area_query" => "Izmišljeno selo" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "unavailable", result.status
          assert_equal "source:public_transport", result.source.fetch("id")
          assert_includes result.warnings, "source_url_not_allowed"
        end

        test "does not approve a downgraded or nonstandard-port source origin" do
          configured = URI.parse(CityServiceSources.fetch("public_transport").fetch(:source_url))
          downgraded = "http://#{configured.host}:#{configured.port}#{configured.request_uri}"
          nonstandard_port = "https://#{configured.host}:444#{configured.request_uri}"

          assert_not port.send(:approved_source_url?, downgraded, "public_transport")
          assert_not port.send(:generic_source_host?, downgraded)
          assert_not port.send(:approved_source_url?, nonstandard_port, "public_transport")
        end

        private

        # --- E1: a weekly schedule never asks for a time -----------------------

        # Izmišljeni jasen is the single reviewed household-r3-d3-2 row (PDF page 24, Wednesday).
        test "a street alone answers the weekly waste day without asking for a time" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "street" => "Izmišljeni jasen" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          fact = result.facts.fetch(0)
          assert_equal "waste_schedule", fact.fetch("kind")
          assert_equal ["srijeda"], fact.dig("coverage", "collection_days")
          assert_equal "weekly", result.coverage.fetch("schedule_kind")
          assert_empty result.warnings.grep(/time|date|day/)
          assert_includes fact.fetch("text"), I18n.t("decidim.bih.dialogue.waste_schedule_limit", year: 2040, locale: "sr")
        end

        test "the same street resolves the same way from area_query and in Cyrillic" do
          variants = [{ "area_query" => "Izmišljeni jasen" }, { "street" => "Измишљени јасен" },
                      { "query" => "kad se odvozi smece u ulici Izmišljeni jasen", "street" => "Izmišljeni jasen" }]
          variants.each do |entities|
            result = port.call(action: "ask_information", topic: "waste", entities:, context: context(capabilities: ["public_reads"]))

            assert_equal "ok", result.status, entities.inspect
            assert_equal ["srijeda"], result.facts.fetch(0).dig("coverage", "collection_days"), entities.inspect
          end
        end

        test "a question word in the time slot never turns a weekly waste question into a time clarification" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "street" => "Izmišljeni jasen", "time_expression" => "kad" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          assert_equal ["srijeda"], result.facts.fetch(0).dig("coverage", "collection_days")
          assert_includes result.warnings, "requested_period_not_applied"
          assert_empty result.warnings.grep(/time|date|day/)
        end

        test "a supplied date still filters the weekly waste schedule to that date" do
          result = port.call(
            action: "ask_information",
            topic: "waste",
            entities: { "street" => "Izmišljeni jasen", "date" => "2040-09-16" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          assert_equal "2040-09-16", result.coverage.fetch("requested_on")
          assert_equal ["srijeda"], result.facts.fetch(0).dig("coverage", "collection_days")
          assert_not_includes result.warnings, "requested_period_not_applied"
        end

        test "an ambiguous waste street asks for the district, never for a time" do
          { "Izmišljena šuma" => [2, 3], "Izmišljena vrba" => [1, 3], "Измишљена врба" => [1, 3] }.each do |street, districts|
            result = port.call(
              action: "ask_information",
              topic: "waste",
              entities: { "street" => street },
              context: context(capabilities: ["public_reads"])
            )

            assert_equal "ambiguous", result.status, street
            assert_empty result.facts
            assert_equal districts, result.coverage.fetch("matching_districts").sort
            assert_includes result.warnings, "waste_district_or_street_segment_required"
            assert_empty result.warnings.grep(/time|date|day/)
          end
        end

        # --- E2: an activity question without a place asks for the place ------

        test "an activity question without a place asks for the place instead of declaring the catalog unavailable" do
          %w(volunteer community participation).each do |topic|
            result = port.call(
              action: "ask_information",
              topic:,
              entities: { "query" => "ima li neka akcija ciscenja ovog vikenda", "time_expression" => "ovog vikenda" },
              context: context(capabilities: ["public_reads"])
            )

            assert_equal "ambiguous", result.status, topic
            assert_equal ["activity_area_required"], result.warnings, topic
            assert_empty result.facts, topic
          end
        end

        test "an activity question with a known place and nothing scheduled is empty, not unavailable" do
          create_area(slug: "komsiluk-izmišljeno selo", name: "Izmišljeno selo")

          result = port.call(
            action: "ask_information",
            topic: "volunteer",
            entities: { "query" => "ima li neka akcija ciscenja u Izmišljeno seloma", "area_query" => "Izmišljeno selo" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "empty", result.status
          assert_equal ["komsiluk-izmišljeno selo"], result.coverage.fetch("requested_area_slugs")
          assert_not_includes result.warnings, "activity_area_required"
        end

        test "a how-to volunteering question without a place still reads the city-wide catalog" do
          result = port.call(
            action: "ask_information",
            topic: "volunteer",
            entities: { "query" => "kako da volontiram" },
            context: context(capabilities: ["public_reads"])
          )

          assert_includes %w(ok empty), result.status
          assert_not_includes result.warnings, "activity_area_required"
        end

        # --- E4: displayed area names never carry the registry marker ----------

        test "area candidates and labels never print the proposal marker" do
          create_area(slug: "komsiluk-janja", name: "Janja (prijedlog)")
          Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-janja", name: { "sr" => "MZ Janja" }, boundary: {})

          result = port.call(
            action: "ask_information",
            topic: "electricity",
            entities: { "area_query" => "Janja" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ambiguous", result.status
          texts = result.candidates.map { |candidate| candidate.fetch("text") }
          assert_equal ["Janja", "MZ Janja"], texts.sort
          assert_equal %w(komsiluk mz), result.candidates.map { |candidate| candidate.fetch("area_kind") }.sort
        end

        # Wave 3 package O: six reviewed contact cards answer without an area.
        CONTACT_CARD_TOPICS = SyntheticReadPortData::CONTACTS.transform_values { |key, phone| [key, phone, key] }.freeze

        test "each contact-card topic answers ok from its reviewed card without an area" do
          CONTACT_CARD_TOPICS.each do |topic, (key, phone, source_slug)|
            result = port.call(action: "ask_information", topic:, entities: {}, context: context(capabilities: ["public_reads"]))

            assert_equal "ok", result.status, topic
            fact = result.facts.fetch(0)
            assert_equal "service_directory", fact.fetch("kind"), topic
            assert_equal "service:#{key}", fact.fetch("id"), topic
            assert_equal "city_services:#{key}", fact.fetch("source_id"), topic
            assert_includes fact.fetch("text"), phone, topic
            assert_includes fact.fetch("text"), "14.9.2040", topic
            assert_includes fact.fetch("source_url"), "https://community.example.invalid/#{source_slug}", topic
            assert_equal "2040-09-14", fact.fetch("observed_at"), topic
            assert_equal "2040-09-14", result.validity.fetch("reviewed_on"), topic
            assert_equal false, result.validity.fetch("live_status"), topic
            assert_includes result.warnings, "snapshot_not_live_status", topic
          end
        end

        test "a pharmacy question with a time word still renders the health card instead of asking for a day" do
          result = port.call(
            action: "ask_information", topic: "health",
            entities: { "query" => "ima li dežurna apoteka noćas", "time_expression" => "noćas" },
            context: context(capabilities: ["public_reads"])
          )

          assert_equal "ok", result.status
          assert_equal "service:zdravstvo_apoteke", result.facts.fetch(0).fetch("id")
          assert_includes result.facts.fetch(0).fetch("text"), "Raspored dežurnih apoteka nemam u provjerenom izvoru"
          assert_includes result.facts.fetch(0).fetch("text"), "000 000 199"
          assert_not_includes result.warnings, "unsupported_time_expression"
        end

        test "the health card is transliterated for a Cyrillic conversation" do
          result = port.call(action: "ask_information", topic: "health", entities: {}, context: context(capabilities: ["public_reads"]), locale: "sr-Cyrl")

          assert_equal "ok", result.status
          assert_includes result.facts.fetch(0).fetch("text"), "Измишљени дом здравља"
          assert_includes result.facts.fetch(0).fetch("text"), "000 000 101"
        end

        test "private notice references resolve only current posts in the assigned organization and board" do
          assigned = create_area(slug: "komsiluk-reference", name: "Reference")
          other = create_area(slug: "komsiluk-other-reference", name: "Other")
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.for_user(actor, organization: @organization)
          profile.assign_komsiluk!(assigned, source: "dropdown")
          post = create_post(area: assigned, title: "Private exact notice")
          private_context = context(actor:, account_state: "registered", capabilities: ["neighborhood_reads"])
          reading = port.notice_reference(post_id: post.id, context: private_context)
          assert_equal "ok", reading.status
          assert_equal Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_path(post, script_name: Decidim::Bih.normalized_public_mount_path),
                       reading.facts.sole.fetch("destination")
          assert_equal "not_authorized", port.notice_reference(post_id: post.id, context: context(capabilities: ["public_reads"])).status
          profile.assign_komsiluk!(other, source: "dropdown")
          assert_empty port.notice_reference(post_id: post.id, context: private_context).facts
          profile.assign_komsiluk!(assigned, source: "dropdown")
          post.update!(status: "hidden")
          assert_empty port.notice_reference(post_id: post.id, context: private_context).facts
        end

        def port(**)
          ReadPort.new(organization: @organization, **)
        end

        def context(actor: nil, account_state: "anonymous", capabilities: [], now: @now, deadline: nil)
          contracts::TrustedContext.new(
            organization_id: @organization.id,
            conversation_key: "a" * 64,
            actor_id: actor&.id,
            account_state:,
            capabilities:,
            now:,
            deadline:
          )
        end

        def contracts
          Decidim::Bih::Concierge::Dialogue::Contracts
        end

        def create_area(slug:, name:, boundary: {})
          Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug:,
            name: { "sr" => name },
            boundary:
          )
        end

        def create_post(area:, title:)
          Decidim::Bih::KomsilukPost.create!(
            organization: @organization,
            komsiluk: area,
            category: "general",
            title:,
            body: "Reviewed member-only body"
          )
        end

        def square(longitude, latitude)
          {
            "type" => "Polygon",
            "coordinates" => [[
              [longitude, latitude],
              [longitude + 0.01, latitude],
              [longitude + 0.01, latitude + 0.01],
              [longitude, latitude + 0.01],
              [longitude, latitude]
            ]]
          }
        end

        def current_location(latitude:, longitude:)
          {
            latitude:,
            longitude:,
            accuracy: 25,
            purpose: "resolve_current_question",
            consent: true,
            provenance: "current_turn_browser"
          }
        end
      end
    end
  end
end
