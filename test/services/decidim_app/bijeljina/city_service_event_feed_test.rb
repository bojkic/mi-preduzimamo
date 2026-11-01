# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"
require "stringio"

module DecidimApp
  module Bijeljina
    class CityServiceEventFeedTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include ActiveSupport::Testing::TimeHelpers

      TestDeadline = Struct.new(:remaining_seconds) do
        def expired?
          remaining_seconds <= 0
        end

        def deadline
          123.0
        end

        def within(max_seconds)
          self.class.new([remaining_seconds, max_seconds].min)
        end
      end

      setup do
        Rails.cache.clear
        @organization = create_organization
        @feed = CityServiceEventFeed.new(organization: @organization)
      end

      teardown { travel_back }

      test "owner disabled heating never reads historical current events" do
        now = Time.zone.parse("2040-09-29 12:00")
        result = @feed.query(topic: :heating, area_identifiers: ["mz-centar"], starts_at: now,
                             ends_at: now + 1.hour, deadline: TestDeadline.new(1))
        assert_equal :unavailable, result.status
        assert_equal :source_disabled_by_owner, result.error_code
        assert_empty result.events
      end

      test "structured query filters area and time before applying its limit" do
        starts_at = Time.zone.parse("2040-09-05 08:00")
        ends_at = Time.zone.parse("2040-09-05 20:00")
        25.times do |index|
          create_event(
            fingerprint: "unrelated-#{index}",
            area_slugs: ["mz-unrelated-#{index}"],
            starts_at: starts_at + index.minutes,
            ends_at:
          )
        end
        expected = create_event(
          fingerprint: "requested-area",
          area_slugs: %w(mz-synthetic-field komsiluk-synthetic-field),
          starts_at: starts_at + 1.hour,
          ends_at:
        )

        result = @feed.query(
          topic: :electricity,
          area_identifiers: %w(komsiluk-synthetic-field),
          starts_at:,
          ends_at:,
          deadline: TestDeadline.new(1)
        )

        assert_equal :ok, result.status
        assert_equal [expected.id], result.events.map(&:id)
        assert_equal %w(komsiluk-synthetic-field), result.area_identifiers
      end

      test "structured query includes citywide and multi-area records but excludes other areas" do
        starts_at = Time.zone.parse("2040-09-05 08:00")
        ends_at = Time.zone.parse("2040-09-05 20:00")
        citywide = create_event(fingerprint: "citywide", targeting_level: "citywide", starts_at:, ends_at:)
        multi_area = create_event(
          fingerprint: "multi-area",
          area_slugs: %w(mz-synthetic-village mz-synthetic-field),
          starts_at:,
          ends_at:
        )
        create_event(fingerprint: "other-area", area_slugs: %w(mz-batkovi), starts_at:, ends_at:)

        result = @feed.query(
          topic: :electricity,
          area_identifiers: %w(mz-synthetic-field),
          starts_at:,
          ends_at:,
          deadline: TestDeadline.new(1)
        )

        assert_equal [citywide.id, multi_area.id].sort, result.events.map(&:id).sort
      end

      test "structured query uses explicit Sarajevo civil-time boundaries including DST day" do
        sarajevo = ActiveSupport::TimeZone["Europe/Sarajevo"]
        starts_at = sarajevo.local(2040, 10, 28, 1, 30)
        ends_at = sarajevo.local(2040, 10, 28, 3, 30)
        assert_equal 3600, starts_at.utc_offset - ends_at.utc_offset, "Exercise the installed timezone rules across the repeated civil hour"
        boundary = create_event(
          fingerprint: "dst-boundary",
          area_slugs: %w(mz-synthetic-field),
          starts_at: ends_at,
          ends_at: ends_at + 30.minutes
        )
        inside = create_event(
          fingerprint: "inside-dst-window", area_slugs: %w(mz-synthetic-field),
          starts_at: starts_at + 30.minutes, ends_at: ends_at
        )
        create_event(
          fingerprint: "outside-dst-window",
          area_slugs: %w(mz-synthetic-field),
          starts_at: ends_at + 1.second,
          ends_at: ends_at + 1.hour
        )

        result = @feed.query(
          topic: :electricity,
          area_identifiers: %w(mz-synthetic-field),
          starts_at:,
          ends_at:,
          deadline: TestDeadline.new(1)
        )

        assert_equal [inside.id], result.events.map(&:id)
        assert_not_includes result.events.map(&:id), boundary.id
        assert_equal starts_at, result.starts_at
        assert_equal ends_at, result.ends_at
      end

      test "expired structured query returns a typed deadline result" do
        result = @feed.query(
          topic: :electricity,
          area_identifiers: %w(mz-synthetic-field),
          starts_at: Time.zone.parse("2040-09-05 08:00"),
          ends_at: Time.zone.parse("2040-09-05 20:00"),
          deadline: TestDeadline.new(0)
        )

        assert_equal :deadline_exceeded, result.status
        assert_equal :deadline_exceeded, result.error_code
        assert_empty result.events
      end

      test "structured query rejects free-text time bounds instead of reparsing them" do
        result = @feed.query(
          topic: :electricity,
          area_identifiers: %w(mz-synthetic-field),
          starts_at: "sutra ujutro",
          ends_at: Time.zone.parse("2040-09-05 20:00"),
          deadline: TestDeadline.new(1)
        )

        assert_equal :invalid, result.status
        assert_equal :invalid_time_bound, result.error_code
        assert_empty result.events
      end

      test "structured query rejects numeric deadline ambiguity" do
        result = @feed.query(
          topic: :electricity,
          area_identifiers: %w(mz-synthetic-field),
          starts_at: Time.zone.parse("2040-09-05 08:00"),
          ends_at: Time.zone.parse("2040-09-05 20:00"),
          deadline: 12_345.0
        )

        assert_equal :invalid, result.status
        assert_equal :invalid_deadline, result.error_code
        assert_empty result.events
      end

      test "structured query installs a transaction-local statement timeout" do
        sql = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          sql << payload.fetch(:sql)
        end

        @feed.query(
          topic: :electricity,
          area_identifiers: %w(mz-synthetic-field),
          starts_at: Time.zone.parse("2040-09-05 08:00"),
          ends_at: Time.zone.parse("2040-09-05 20:00"),
          deadline: TestDeadline.new(0.75)
        )

        assert(sql.any? { |statement| statement.include?("SET LOCAL statement_timeout = 750") })
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end

      test "structured query has an overall wall-clock read boundary" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = @feed.stub(:with_statement_timeout, ->(_deadline) { sleep 0.2 }) do
          @feed.query(
            topic: :electricity,
            area_identifiers: %w(mz-synthetic-field),
            starts_at: Time.zone.parse("2040-09-05 08:00"),
            ends_at: Time.zone.parse("2040-09-05 20:00"),
            deadline: TestDeadline.new(0.05)
          )
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        assert_operator elapsed, :<, 0.18
        assert_equal :deadline_exceeded, result.status
        assert_equal :deadline_exceeded, result.error_code
      end

      test "published event without a valid source observation never receives a fabricated check time" do
        travel_to Time.zone.local(2040, 9, 5, 12, 34) do
          create_event(
            fingerprint: "missing-fetched-at",
            targeting_level: "citywide",
            starts_at: 1.hour.ago,
            ends_at: 1.hour.from_now,
            fetched_at: nil
          )

          answer = @feed.answer(text: "ima li struje danas", locale: :sr)

          assert_includes answer, "vrijeme provjere nije dostupno"
          assert_not_includes answer, "05.09.2040. u 12:34"
        end
      end

      test "failed source check is unavailable reassurance rather than no-outage reassurance" do
        feed = CityServiceEventFeed.new(
          organization: @organization,
          source_checker: source_checker(status: :unavailable, checked_at: nil, error_code: :fetch_error)
        )

        answer = feed.answer(text: "ima li struje danas", locale: :sr)

        assert_includes answer, "trenutno nije dostupan"
        assert_includes answer, "Ne mogu potvrditi stanje"
        assert_not_includes answer, "nema najavljenih"
      end

      test "reviewed empty source check says no reviewed match and not normal service" do
        travel_to Time.zone.local(2040, 9, 5, 10, 30) do
          feed = CityServiceEventFeed.new(
            organization: @organization,
            source_checker: source_checker(status: :empty, checked_at: Time.zone.parse("2040-09-05 10:15"))
          )

          answer = feed.answer(text: "ima li struje danas", locale: :sr)

          assert_includes answer, "nemam pregledano obavještenje"
          assert_includes answer, "ne potvrđuje da prekida nema"
          assert_not_includes answer, "nema najavljenih"
        end
      end

      test "invalid source check time is not replaced with current time" do
        travel_to Time.zone.local(2040, 9, 5, 12, 34) do
          feed = CityServiceEventFeed.new(
            organization: @organization,
            source_checker: source_checker(status: :empty, checked_at: "not-a-time")
          )

          answer = feed.answer(text: "ima li struje danas", locale: :sr)

          assert_includes answer, "trenutno nije dostupan"
          assert_not_includes answer, "05.09.2040. u 12:34"
        end
      end

      test "future event check time is not rendered as freshness" do
        travel_to Time.zone.local(2040, 9, 5, 12, 34) do
          create_event(
            fingerprint: "future-fetched-at",
            targeting_level: "citywide",
            starts_at: 1.hour.ago,
            ends_at: 1.hour.from_now,
            fetched_at: 1.hour.from_now
          )

          answer = @feed.answer(text: "ima li struje danas", locale: :sr)

          assert_includes answer, "vrijeme provjere nije dostupno"
          assert_not_includes answer, "05.09.2040. u 13:34"
        end
      end

      test "cache failure preserves the observed source check without fetching twice" do
        calls = 0
        checker = source_checker(status: :unavailable, checked_at: nil, error_code: :fetch_error)
        checker.define_singleton_method(:check) do |keys:, **|
          calls += 1
          super(keys:)
        end
        feed = CityServiceEventFeed.new(organization: @organization, source_checker: checker)
        failed_cache = lambda do |*_args, **_kwargs, &block|
          block.call
          raise TypeError, "cache serialization failed"
        end

        answer = Rails.cache.stub(:fetch, failed_cache) { feed.answer(text: "ima li struje danas", locale: :sr) }

        assert_equal 1, calls
        assert_includes answer, "trenutno nije dostupan"
        assert_includes answer, "Ne mogu potvrditi stanje"
      end

      test "failed source checker never falls back to a no-event reassurance" do
        checker = Object.new
        checker.define_singleton_method(:check) { |**| raise IOError, "synthetic failure" }
        feed = CityServiceEventFeed.new(organization: @organization, source_checker: checker)

        answer = feed.answer(text: "ima li struje danas", locale: :sr)

        assert_includes answer, "trenutno nije dostupan"
        assert_includes answer, "Ne mogu potvrditi stanje"
      end

      test "valid ISO source timestamps are preserved without parsing incomplete dates" do
        travel_to Time.zone.local(2040, 9, 5, 12, 34) do
          assert_equal "05.09.2040. u 12:15", @feed.send(:formatted_checked_at, "2040-09-05T10:15:00Z")
          assert_nil @feed.send(:formatted_checked_at, "2040-09")
        end
      end

      test "scoped query logs only error class and code" do
        output = StringIO.new
        logger = ActiveSupport::Logger.new(output)

        Rails.stub(:logger, logger) do
          CityServiceEvent.stub(:for_organization, ->(*) { raise "citizen secret and raw SQL" }) do
            result = @feed.query(
              topic: :electricity,
              area_identifiers: %w(mz-synthetic-field),
              starts_at: Time.zone.parse("2040-09-05 08:00"),
              ends_at: Time.zone.parse("2040-09-05 20:00"),
              deadline: nil
            )

            assert_equal :unavailable, result.status
          end
        end

        assert_includes output.string, "error_class=RuntimeError error_code=query_failed"
        assert_not_includes output.string, "citizen secret"
        assert_not_includes output.string, "raw SQL"
      end

      test "Milica reads pending and failed public evidence without approval while excluding dismissed and replaced rows" do
        starts_at = Time.current
        ends_at = starts_at + 3.hours
        pending = create_event(fingerprint: "unconfirmed", starts_at:, ends_at:)
        pending.update!(state: "pending_review", targeting_level: "unknown", lifecycle: "scheduled")
        failed = create_event(fingerprint: "incomplete", starts_at: nil, ends_at: nil)
        failed.update!(state: "failed", targeting_level: "unknown")
        %w(dismissed superseded).each do |state|
          create_event(fingerprint: state, starts_at:, ends_at:).update!(state:)
        end
        other_org = create_event(fingerprint: "another-org", starts_at:, ends_at:)
        other_org.update!(organization: create_organization, targeting_level: "unknown")
        query = @feed.query(topic: :electricity, area_identifiers: ["komsiluk-requested"], starts_at:, ends_at:, deadline: nil)
        assert_equal :ok, query.status
        assert_equal [pending.id, failed.id].sort, query.events.map(&:id).sort
        assert_empty CityServiceEvent.citizen_visible.where(id: [pending.id, failed.id])
        text = @feed.send(:current_event, pending, locale: "sr", requested_area_slugs: ["komsiluk-requested"])
        assert_includes text, pending.summary
        assert_includes text, I18n.t("decidim_app.city_service_events.bot.unconfirmed_facts", locale: "sr")
        assert_includes text, I18n.t("decidim_app.city_service_events.bot.unconfirmed_area", locale: "sr")
        assert_nil pending.reload.reviewed_by_id
      end

      test "independent MZ coverage matches every declared street area without broadening a known different area" do
        starts_at = Time.current
        ends_at = starts_at + 3.hours
        street = create_event(fingerprint: "street-union", starts_at:, ends_at:, area_slugs: %w(komsiluk-1 komsiluk-2), targeting_level: "komsiluk")
        street.update!(state: "pending_review", extraction_metadata: { "coverage" => { "affected_places" => [
                         { "slug" => "mz-first", "kind" => "mz", "relation" => "part" },
                         { "slug" => "mz-second", "kind" => "mz", "relation" => "part" }
                       ] } })
        %w(komsiluk-1 komsiluk-2 mz-first mz-second).each do |slug|
          query = @feed.query(topic: :electricity, area_identifiers: [slug], starts_at:, ends_at:, deadline: nil)
          assert_equal [street.id], query.events.map(&:id)
        end
        query = @feed.query(topic: :electricity, area_identifiers: ["mz-other"], starts_at:, ends_at:, deadline: nil)
        assert_empty query.events
      end

      test "matching current-version place context ranks before unrelated unknown notices and stale context loses priority" do
        starts_at = Time.current
        ends_at = starts_at + 3.hours
        25.times do |index|
          create_event(fingerprint: "unknown-context-#{index}", starts_at:, ends_at:, targeting_level: "unknown").update!(state: "pending_review")
        end
        contextual = create_event(fingerprint: "context-batkovic", starts_at: starts_at + 1.minute, ends_at:, targeting_level: "unknown")
        contextual.update!(state: "pending_review", content_version: "provider-v1", extraction_metadata: {
                             "place_context" => { "source_content_version" => "provider-v1", "places" => [
                               { "slug" => "komsiluk-batkovic", "name" => "Batković", "kind" => "komsiluk", "relation" => "context_only",
                                 "source" => "provider_asset_label", "evidence" => "TS BATKOVIĆ CENTAR" }
                             ] }
                           })
        query = @feed.query(topic: :electricity, area_identifiers: ["komsiluk-batkovic"], starts_at:, ends_at:, deadline: nil)
        assert_equal :ok, query.status
        assert_equal CityServiceEventFeed::QUERY_LIMIT, query.events.size
        assert_equal contextual.id, query.events.first.id
        assert_equal ["komsiluk-batkovic"], CityServicePlaceContext.slugs(contextual)
        text = @feed.send(:current_event, contextual, locale: "sr", requested_area_slugs: ["komsiluk-batkovic"])
        assert_includes text, I18n.t("decidim_app.city_service_events.bot.place_context", names: "Batković", locale: "sr")
        assert_empty contextual.area_slugs
        assert_nil contextual.reviewed_at

        contextual.update!(content_version: "provider-v2")
        stale_query = @feed.query(topic: :electricity, area_identifiers: ["komsiluk-batkovic"], starts_at:, ends_at:, deadline: nil)
        assert_equal CityServiceEventFeed::QUERY_LIMIT, stale_query.events.size
        assert_not_includes stale_query.events.map(&:id), contextual.id
        assert_empty CityServicePlaceContext.places(contextual)
        assert_empty CityServicePlaceContext.notice(contextual, locale: "sr")
        assert CityServiceEvent.milica_available.exists?(contextual.id)
      end

      private

      def create_event(fingerprint:, starts_at:, ends_at:, **attributes)
        CityServiceEvent.create!(
          organization: @organization,
          source_key: "electricity_outages",
          source_label: "Izmišljeni pružalac",
          source_fingerprint: fingerprint,
          source_url: "https://example.test/electricity",
          event_type: "planned_outage",
          severity: "service_outage",
          targeting_level: attributes.fetch(:targeting_level, "mz"),
          affected_area_slugs: attributes.fetch(:area_slugs, []),
          title: "Planirano isključenje struje",
          summary: "Servisno obavještenje",
          starts_at:,
          ends_at:,
          fetched_at: attributes.fetch(:fetched_at, Time.zone.parse("2040-09-05 07:00")),
          state: "published",
          parser_version: "test"
        )
      end

      def source_checker(status:, checked_at:, error_code: nil)
        result_class = Struct.new(:source_key, :status, :notices, :checked_at, :error_code, keyword_init: true)
        Class.new do
          define_method(:initialize) do |result_status, result_checked_at, result_error_code, check_result_class|
            @status = result_status
            @checked_at = result_checked_at
            @error_code = result_error_code
            @result_class = check_result_class
          end

          define_method(:check) do |keys:, **|
            keys.map do |source_key|
              @result_class.new(
                source_key:,
                status: @status,
                notices: [],
                checked_at: @checked_at,
                error_code: @error_code
              )
            end
          end
        end.new(status, checked_at, error_code, result_class)
      end
    end
  end
end
