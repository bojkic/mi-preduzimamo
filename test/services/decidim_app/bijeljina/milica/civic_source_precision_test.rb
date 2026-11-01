# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      # The seven source/geography states the plan requires to stay distinct,
      # plus the two claims that must never be made from silence: that a
      # household is unaffected, and that an internal slug is a place name.
      class CivicSourcePrecisionTest < ActiveSupport::TestCase
        FakeCheck = Struct.new(:source_key, :status, :notices, :checked_at, :error_code, keyword_init: true)
        FakeChecker = Struct.new(:result) do
          def check(**) = [result]
        end
        # ScopedServiceQuery freezes itself, so the double builds a fresh one
        # from the arguments the port actually passed.
        FakeFeed = Struct.new(:calls) do
          def query(**attributes)
            calls << attributes
            CityServiceEventFeed::ScopedServiceQuery.new(
              status: :empty, events: [], topic: attributes[:topic],
              area_identifiers: attributes[:area_identifiers],
              starts_at: attributes[:starts_at], ends_at: attributes[:ends_at]
            )
          end
        end

        setup do
          @organization = create_organization
          @now = Time.utc(2040, 4, 9, 12, 0)
          @prior_sources = CityServiceSources::SOURCES
          sources = %w(water_service electricity_outages heating_service waste_schedule).map do |key|
            { key:, label: "Izmišljeni izvor #{key}", source_url: "https://water.community.example.invalid/#{key}", enabled: true, delivery_modes: [CityServiceSources::ON_DEMAND] }
          end
          CityServiceSources.send(:remove_const, :SOURCES)
          CityServiceSources.const_set(:SOURCES, sources.freeze)
          @mz = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-izmisljeni-vrt",
                                                name: { "sr" => "Izmišljeni vrt" })
        end

        teardown do
          CityServiceSources.send(:remove_const, :SOURCES)
          CityServiceSources.const_set(:SOURCES, @prior_sources)
        end

        test "disabled adapters do not remove the reference event vocabulary" do
          CityServiceSources.send(:remove_const, :SOURCES)
          CityServiceSources.const_set(:SOURCES, [].freeze)
          assert_empty CityServiceSources.alert_candidates
          expected = CityServiceSources::REFERENCE_SOURCES.filter_map { |source| source[:viber] }
                         .flat_map { |viber| viber.fetch(:event_types) }.uniq
          assert_not_empty expected
          expected.each { |type| assert_includes CityServiceNoticeClassifier::EVENT_TYPES, type }
        end

        test "a reviewed-empty publication is not the same state as an unread source" do
          result = read(check: check(:empty))

          assert_equal "empty", result.status
          assert_includes result.warnings, "no_matching_source_notice"
          assert_equal "reviewed_empty", result.coverage.fetch("status")
        end

        # Synthetic records exercise this scope/window distinction.
        test "a source we read whose notices miss the window is a scoped empty result, not a pending review" do
          result = read(check: check(:ok))

          assert_equal "empty", result.status
          assert_includes result.warnings, "source_scope_or_time_not_matched"
          assert_not_includes result.warnings, "no_matching_source_notice"
          assert_equal "unmatched", result.coverage.fetch("status")
        end

        test "an unreviewed source that matched nothing says both things and neither of them is a source outage" do
          result = read(check: check(:unreviewed))

          assert_equal "empty", result.status
          assert_includes result.warnings, "source_scope_or_time_not_matched"
          assert_includes result.warnings, "source_content_not_operator_reviewed"
          assert_includes result.warnings, ReadPort::NO_ABSENCE_CLAIM
          assert_equal "unmatched", result.coverage.fetch("status")
        end

        test "a reviewed-empty publication and an unmatched window never share a warning code" do
          reviewed_empty = read(check: check(:empty))
          unmatched = read(check: check(:unreviewed))

          assert_equal %w(empty empty), [reviewed_empty.status, unmatched.status]
          assert_equal %w(reviewed_empty unmatched), [reviewed_empty.coverage.fetch("status"), unmatched.coverage.fetch("status")]
          assert_empty((reviewed_empty.warnings & unmatched.warnings) - [ReadPort::NO_ABSENCE_CLAIM])
        end

        test "an extraction failure is reported as extraction, not as an unreachable provider" do
          result = read(check: check(:unreviewed, error_code: :article_fetch_incomplete))

          assert_equal "unreviewed", result.status
          assert_includes result.warnings, "source_extraction_incomplete"
          assert_includes result.warnings, "article_fetch_incomplete"
          assert_not_includes result.warnings, "source_unavailable"
        end

        test "a malformed source is an extraction failure with its own code" do
          result = read(check: check(:malformed, error_code: :empty_body))

          assert_equal "unavailable", result.status
          assert_includes result.warnings, "source_extraction_failed"
          assert_includes result.warnings, "empty_body"
        end

        test "a stale publication is stale, not empty and not broken" do
          result = read(check: check(:stale, error_code: :prepared_source_stale))

          assert_equal "stale", result.status
          assert_includes result.warnings, "source_publication_stale"
          assert_includes result.warnings, "prepared_source_stale"
        end

        test "an unreachable source is unavailable and says so" do
          result = read(check: check(:unavailable, error_code: :prepared_source_missing))

          assert_equal "unavailable", result.status
          assert_includes result.warnings, "source_unavailable"
          assert_includes result.warnings, "prepared_source_missing"
        end

        test "no unmatched service read may be read as evidence of normal service" do
          [:empty, :ok, :stale, :malformed, :unavailable].each do |status|
            result = read(check: check(status, error_code: :prepared_source_missing))

            assert_includes result.warnings, ReadPort::NO_ABSENCE_CLAIM, status.to_s
          end
        end

        test "an unmatched heating read is unmapped coverage, never an unaffected household" do
          result = read(topic: "heating", check: check(:empty))

          assert_equal "not_published", result.coverage.fetch("network_footprint")
          assert_includes result.warnings, ReadPort::NO_ABSENCE_CLAIM
        end

        test "an unmatched water read does not claim a heating-style footprint" do
          result = read(check: check(:empty))

          assert_nil result.coverage["network_footprint"]
        end

        test "coverage carries the public place name beside the internal slug" do
          result = read(check: check(:empty))

          assert_equal ["mz-izmisljeni-vrt"], result.coverage.fetch("area_slugs")
          assert_equal ["Izmišljeni vrt"], result.coverage.fetch("area_labels")
          assert_equal [{ "slug" => "mz-izmisljeni-vrt", "name" => "Izmišljeni vrt" }], result.coverage.fetch("requested_areas")
        end

        test "an area we cannot resolve never reaches the source as if it had" do
          feed = FakeFeed.new([])
          port = ReadPort.new(organization: @organization, event_feed: feed, source_checker: FakeChecker.new(check(:empty)))

          result = port.call(action: "ask_information", topic: "water", entities: { "area_slug" => "mz-nepoznata" },
                             context:, locale: "sr")

          assert_includes %w(ambiguous empty unavailable), result.status
          assert_empty feed.calls, "an unresolved area must not be queried as a resolved one"
        end

        test "the weekly schedule answers a which-day question as a plan, not a sighting" do
          schedule = Decidim::Bih::City::WasteSchedule.from_text(file_fixture("komunalac_waste_schedule_synthetic.txt").read)
          port = ReadPort.new(organization: @organization, waste_schedule: schedule)
          plain = port.call(action: "ask_information", topic: "waste", entities: { "area_query" => "Vinogradska" },
                            context:, locale: "sr")
          observed = port.call(action: "ask_information", topic: "waste",
                               entities: { "area_query" => "Vinogradska", "query" => "Nisu pokupili smeće u Vinogradskoj" },
                               context:, locale: "sr")

          assert_equal "ok", plain.status
          assert_not_includes plain.warnings, "schedule_is_plan_not_observed_collection"
          assert_equal "ok", observed.status
          assert_includes observed.warnings, "schedule_is_plan_not_observed_collection"
          assert_includes observed.warnings, "snapshot_not_live_status"
          assert_equal "observed_collection", observed.coverage.fetch("question")
          assert_equal false, observed.validity.fetch("observed_collection_known")
        end

        test "a place the notice named but we could not map travels with the answer" do
          event = create_event(
            "status" => "partial",
            "affected_places" => [{ "slug" => "mz-izmisljeni-vrt", "kind" => "mz", "relation" => "part" }],
            "unresolved_places" => [{ "kind" => "feeder", "evidence" => "ts izmisljeni vrt 4", "reason" => "geographic_crosswalk_not_reviewed" }],
            "ambiguous_places" => [{ "evidence" => "centar", "candidate_slugs" => %w(mz-centar komsiluk-centar) }]
          )
          result = read_events([event])

          coverage = result.facts.fetch(0).fetch("coverage")
          assert_equal "partial", coverage.fetch("status")
          assert_equal "ts izmisljeni vrt 4", coverage.fetch("unresolved_places").fetch(0).fetch("evidence")
          assert_equal %w(mz-centar komsiluk-centar), coverage.fetch("ambiguous_places").fetch(0).fetch("candidate_slugs")
          # The mapped place is named, not slugged.
          assert_equal [{ "slug" => "mz-izmisljeni-vrt", "name" => "Izmišljeni vrt" }], coverage.fetch("affected_areas")
          assert_equal "Izmišljeni vrt", coverage.fetch("affected_relations").fetch(0).fetch("name")
        end

        test "an event with nothing unresolved does not carry empty evidence keys" do
          result = read_events([create_event("status" => "resolved", "affected_places" => [])])

          coverage = result.facts.fetch(0).fetch("coverage")
          assert_not coverage.has_key?("unresolved_places")
          assert_not coverage.has_key?("ambiguous_places")
        end

        test "the area matcher resolves public names and refuses to invent one" do
          matcher = CityServiceAreaMatcher.new(organization: @organization)

          assert_equal({ "mz-izmisljeni-vrt" => "Izmišljeni vrt" }, matcher.display_names(%w(mz-izmisljeni-vrt mz-nepoznata)))
          assert_equal [{ "slug" => "mz-izmisljeni-vrt", "name" => "Izmišljeni vrt" }, { "slug" => "mz-nepoznata" }],
                       matcher.public_places(%w(mz-izmisljeni-vrt mz-nepoznata))
          assert_empty matcher.display_names([])
        end

        # Synthetic records exercise this scope/window distinction.
        test "the city name is a citywide query scope, not a place we failed to find" do
          ["Bijeljina", "u Bijeljini", "Бијељина"].each do |query|
            feed = FakeFeed.new([])
            port = ReadPort.new(organization: @organization, event_feed: feed, source_checker: FakeChecker.new(check(:unreviewed)))
            result = port.call(action: "ask_information", topic: "electricity", entities: { "area_query" => query }, context:, locale: "sr")

            assert_equal 1, feed.calls.length, query
            assert_empty feed.calls.first.fetch(:area_identifiers), query
            assert_equal "empty", result.status, query
            assert_includes result.warnings, "citywide_query_scope", query
            assert_includes result.warnings, "source_scope_or_time_not_matched", query
            assert_equal "citywide", result.coverage.fetch("scope"), query
          end
        end

        test "a place we cannot resolve asks which neighbourhood instead of claiming there is no data" do
          feed = FakeFeed.new([])
          port = ReadPort.new(organization: @organization, event_feed: feed, source_checker: FakeChecker.new(check(:unreviewed)))

          result = port.call(action: "ask_information", topic: "electricity", entities: { "area_query" => "Izmišljena ulica" }, context:, locale: "sr")

          assert_equal "ambiguous", result.status
          assert_equal ["area_not_found"], result.warnings
          assert_empty feed.calls, "an unresolved name must not be read as a citywide question"
        end

        test "a street widens the read to the whole city and says so instead of widening silently" do
          feed = FakeFeed.new([])
          port = ReadPort.new(organization: @organization, event_feed: feed, source_checker: FakeChecker.new(check(:unreviewed)))

          result = port.call(action: "ask_information", topic: "electricity", entities: { "street" => "Izmišljena ulica" }, context:, locale: "sr")

          assert_empty feed.calls.first.fetch(:area_identifiers)
          assert_includes result.warnings, "street_coverage_not_published_by_source"
          assert_equal "not_reviewed", result.coverage.fetch("street_to_area_crosswalk")
        end

        # Synthetic records exercise this scope/window distinction.
        test "a settlement in the street slot is read as the place it is, not announced as a street we know" do
          Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-vinogradska",
                                          name: { "sr" => "Vinogradska" })
          Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-vinogradska",
                                          name: { "sr" => "Vinogradska" })
          feed = FakeFeed.new([])
          port = ReadPort.new(organization: @organization, event_feed: feed, source_checker: FakeChecker.new(check(:unreviewed)))

          result = port.call(action: "ask_information", topic: "electricity", entities: { "street" => "Vinogradska" }, context:, locale: "sr")

          assert_equal "ambiguous", result.status
          assert_includes result.warnings, "area_name_ambiguous"
          assert_not_includes result.warnings, "street_coverage_not_published_by_source"
          assert_empty feed.calls, "a recognised place must not be read as a citywide question"
        end

        test "a settlement in the street slot that names one area scopes the read to it" do
          area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-zorice",
                                                 name: { "sr" => "Zorice" })
          feed = FakeFeed.new([])
          port = ReadPort.new(organization: @organization, event_feed: feed, source_checker: FakeChecker.new(check(:unreviewed)))

          result = port.call(action: "ask_information", topic: "electricity", entities: { "street" => "Zorice" }, context:, locale: "sr")

          assert_equal [area.slug], feed.calls.first.fetch(:area_identifiers)
          assert_not_includes result.warnings, "street_coverage_not_published_by_source"
          assert_nil result.coverage["street_to_area_crosswalk"]
        end

        # --- the requested time ------------------------------------------

        test "the present tense is understood and never becomes a question about which day" do
          %w(sada sad trenutno odmah).each do |word|
            feed = read_window("time_expression" => word)

            assert_not_includes feed.fetch(:warnings), "unsupported_time_expression", word
            assert_equal [@now, @now + CityServiceEventFeed::CURRENT_WINDOW], feed.values_at(:starts_at, :ends_at), word
          end
        end

        test "a named part of the day reads that part, not the whole day" do
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          today = @now.in_time_zone(zone).to_date
          midnight = zone.local(today.year, today.month, today.day)

          evening = read_window("time_expression" => "večeras")
          morning = read_window("time_expression" => "jutros")
          night = read_window("time_expression" => "noćas")

          assert_equal [midnight + 17.hours, midnight + 24.hours], evening.values_at(:starts_at, :ends_at)
          assert_equal [midnight + 5.hours, midnight + 12.hours], morning.values_at(:starts_at, :ends_at)
          assert_equal [midnight + 20.hours, midnight + 30.hours], night.values_at(:starts_at, :ends_at)
        end

        # Synthetic records exercise this scope/window distinction.
        test "a question about announcements looks forward far enough to find one" do
          feed = read_window("query" => "Ima li najava isključenja struje?")

          assert_equal @now + ReadPort::ANNOUNCEMENT_WINDOW, feed.fetch(:ends_at)
          assert_equal @now, feed.fetch(:starts_at)
          assert_includes feed.fetch(:warnings), "announcement_window_not_current_status"
        end

        test "an announcement question that names a day keeps that day" do
          feed = read_window("query" => "Ima li najava isključenja struje?", "date" => "2026-09-16")
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]

          assert_equal [zone.local(2026, 9, 16), zone.local(2026, 9, 17)], feed.values_at(:starts_at, :ends_at)
        end

        test "a question about right now is not widened into an announcement window" do
          feed = read_window("query" => "Ima li trenutno prekida struje?")

          assert_equal @now + CityServiceEventFeed::CURRENT_WINDOW, feed.fetch(:ends_at)
          assert_not_includes feed.fetch(:warnings), "announcement_window_not_current_status"
        end

        # --- the sentence the citizen actually hears ----------------------
        #
        # The port computed the precise code and the renderer dropped it: any
        # warning missing from READ_WARNING_KEYS collapses into one generic
        # sentence, which is how five different outcomes became the same
        # paragraph.
        test "every service-read outcome the port can report has its own rendered sentence" do
          renderer = Decidim::Bih::Concierge::Dialogue::FactRenderer
          codes = %w(
            area_not_found citywide_query_scope street_coverage_not_published_by_source
            source_scope_or_time_not_matched announcement_window_not_current_status
            no_matching_source_notice source_content_not_operator_reviewed
            source_extraction_incomplete source_extraction_failed source_publication_stale
            source_unavailable
          ) + [ReadPort::NO_ABSENCE_CLAIM]

          codes.each do |code|
            key = renderer::READ_WARNING_KEYS[code]
            assert key, "#{code} renders as the generic coverage sentence"
            %w(sr sr-Cyrl bs hr en).each do |locale|
              assert I18n.exists?("decidim.bih.dialogue.read_warning_#{key}", locale), "#{locale}:#{key}"
            end
          end
          assert_equal codes.uniq.length, codes.map { |code| renderer::READ_WARNING_KEYS.fetch(code) }.uniq.length,
                       "two outcomes share one sentence"
        end

        private

        # The window and the warnings the port sent to the feed for one read.
        def read_window(entities)
          feed = FakeFeed.new([])
          port = ReadPort.new(organization: @organization, event_feed: feed, source_checker: FakeChecker.new(check(:unreviewed)))
          result = port.call(action: "ask_information", topic: "electricity",
                             entities: entities.merge("area_slug" => "mz-izmisljeni-vrt"), context:, locale: "sr")
          feed.calls.first.merge(warnings: result.warnings)
        end

        def create_event(coverage)
          CityServiceEvent.create!(
            organization: @organization, source_key: "water_service", source_label: "Izmišljeni vodovod",
            source_fingerprint: "fp-#{SecureRandom.hex(4)}", source_url: "https://water.community.example.invalid/water_service",
            event_type: "planned_interruption", severity: "service_outage", targeting_level: "mz",
            affected_area_slugs: ["mz-izmisljeni-vrt"], title: "Prekid vodosnabdijevanja", summary: "Servisno obavještenje",
            starts_at: @now, ends_at: @now + 3600, fetched_at: @now - 600, state: "published", parser_version: "test",
            extraction_metadata: { "coverage" => coverage, "temporal_precision" => "minute" }
          )
        end

        def read_events(events)
          feed = Object.new
          response = CityServiceEventFeed::ScopedServiceQuery.new(status: :ok, events:, topic: "water",
                                                                  area_identifiers: ["mz-izmisljeni-vrt"], starts_at: @now, ends_at: @now + 3600)
          feed.define_singleton_method(:query) { |**| response }
          port = ReadPort.new(organization: @organization, event_feed: feed, source_checker: FakeChecker.new(check(:ok)))
          port.call(action: "ask_information", topic: "water", entities: { "area_slug" => "mz-izmisljeni-vrt" }, context:, locale: "sr")
        end

        def check(status, error_code: nil)
          FakeCheck.new(source_key: "water_service", status:, notices: [], checked_at: @now - 3600, error_code:)
        end

        def read(check:, topic: "water", slugs: ["mz-izmisljeni-vrt"])
          port = ReadPort.new(organization: @organization, event_feed: FakeFeed.new([]),
                              source_checker: FakeChecker.new(check))
          port.call(action: "ask_information", topic:, entities: { "area_slug" => slugs.first },
                    context: context, locale: "sr")
        end

        def context
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "d" * 64, actor_id: nil,
            account_state: "anonymous", capabilities: ["public_reads"], now: @now, deadline: nil
          )
        end
      end
    end
  end
end
