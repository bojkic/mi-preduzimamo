# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_event_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceEventWorkflowTest < ActiveSupport::TestCase
      include SyntheticEventSourceRegistry
      include ActiveJob::TestHelper
      include ActiveSupport::Testing::TimeHelpers

      setup do
        travel_to Time.zone.local(2040, 6, 29, 8, 0, 0)
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @mz = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-synthetic-field",
          name: { "sr" => "Izmišljeno polje" }
        )
        @komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-synthetic-field",
          name: { "sr" => "Izmišljeno polje 1" },
          parent: @mz,
          primary_mz_slug: "mz-synthetic-field",
          overlapping_mz_slugs: ["mz-synthetic-field"]
        )
      end

      teardown { travel_back }

      test "electricity parser extracts planned outage candidates and matched areas" do
        events = ElectricityOutageParser.new(organization: @organization).call(
          html: electricity_html,
          source_url: "https://example.test/outages",
          fetched_at: Time.zone.parse("2040-06-28 08:00")
        )

        assert_equal 1, events.size
        event = events.first
        assert_equal "electricity_outages", event.source_key
        assert_equal "planned_outage", event.event_type
        assert_equal "service_outage", event.severity
        assert_equal "mz", event.targeting_level
        assert_includes event.affected_area_slugs, "mz-synthetic-field"
        assert_not_includes event.affected_area_slugs, "komsiluk-synthetic-field"
        assert_includes event.extraction_metadata.dig("coverage", "notification_candidates").map { |item| item.fetch("slug") }, "komsiluk-synthetic-field"
        assert_includes event.summary, "09:00"
        assert_match(/\A[a-f0-9]{24}\z/, event.source_fingerprint)
      end

      test "electricity parser returns no events for the current empty source shell" do
        html = "<html><title>Planirana isključenja</title><body>Izaberite Terensku jedinicu</body></html>"

        assert_equal [], ElectricityOutageParser.new(organization: @organization).call(html:)
      end

      test "water service parser creates pending review candidates from dated outage posts" do
        events = CityServiceEventIngestor.new(organization: @organization).dry_run(
          source_key: "water_service",
          html: official_post_html("30.06.2040. od 08:00 do 14:00 zbog radova dolazi do prekida vodosnabdijevanja u Izmišljenom polju."),
          fetched_at: Time.zone.parse("2040-06-30 10:00")
        )

        assert_equal 1, events.size
        event = events.first
        assert_equal "water_service", event.source_key
        assert_equal "planned_interruption", event.event_type
        assert_equal "service_outage", event.severity
        assert_includes event.affected_area_slugs, "mz-synthetic-field"
        assert_not_includes event.affected_area_slugs, "komsiluk-synthetic-field"
        assert_includes event.extraction_metadata.dig("coverage", "notification_candidates").map { |item| item.fetch("slug") }, "komsiluk-synthetic-field"
        assert_includes event.title, "Prekid vodosnabdijevanja"
      end

      test "official post parser ignores already-ended service interruptions" do
        events = CityServiceEventIngestor.new(organization: @organization).dry_run(
          source_key: "water_service",
          html: official_post_html("30.06.2040. od 08:00 do 14:00 zbog radova dolazi do prekida vodosnabdijevanja u Izmišljenom polju."),
          fetched_at: Time.zone.parse("2040-06-30 15:00")
        )

        assert_equal [], events
      end

      test "official post parser understands Serbian month-name dates from live-style listings" do
        events = CityServiceEventIngestor.new(organization: @organization).dry_run(
          source_key: "water_service",
          html: official_post_html("30. juna 2040. od 08:00 do 14:00 zbog radova dolazi do prekida vodosnabdijevanja u Izmišljenom polju."),
          fetched_at: Time.zone.parse("2040-06-30 10:00")
        )

        assert_equal 1, events.size
        event = events.first
        assert_equal Time.zone.parse("2040-06-30 08:00"), event.starts_at
        assert_equal Time.zone.parse("2040-06-30 14:00"), event.ends_at
        assert_includes event.affected_area_slugs, "mz-synthetic-field"
      end

      test "city official notice parser supports citywide safety notices" do
        events = CityServiceEventIngestor.new(organization: @organization).dry_run(
          source_key: "city_official_notices",
          html: official_post_html("30.06.2040. od 20:00 do 23:00 obavještenje o zaprašivanju komaraca na području grada Bijeljina."),
          fetched_at: Time.zone.parse("2040-06-30 10:00")
        )

        assert_equal 1, events.size
        event = events.first
        assert_equal "city_official_notices", event.source_key
        assert_equal "mosquito_spraying", event.event_type
        assert_equal "safety", event.severity
        assert_equal "citywide", event.targeting_level
        assert_empty event.affected_area_slugs
        assert_includes event.classifier_reasons, "citywide_notice"
      end

      test "heating service parser creates pending review candidates from dated interruption posts" do
        events = CityServiceEventIngestor.new(organization: @organization).dry_run(
          source_key: "heating_service",
          html: official_post_html("15.01.2041. od 09:00 do 12:00 zbog kvara na toplovodu moguć je prekid grijanja u Izmišljenom polju.")
        )

        assert_equal 1, events.size
        event = events.first
        assert_equal "heating_service", event.source_key
        assert_equal "heating_interruption", event.event_type
        assert_equal "service_outage", event.severity
        assert_includes event.affected_area_slugs, "mz-synthetic-field"
        assert_includes event.title, "Prekid grijanja"
      end

      test "official post parser ignores stale archive notices" do
        events = CityServiceEventIngestor.new(organization: @organization).dry_run(
          source_key: "heating_service",
          html: official_post_html("15.01.2039. od 09:00 do 12:00 zbog kvara na toplovodu moguć je prekid grijanja u Izmišljenom polju."),
          fetched_at: Time.zone.parse("2040-06-29 08:00")
        )

        assert_equal [], events
      end

      test "ingestor creates idempotent pending review rows without raw source text" do
        ingestor = CityServiceEventIngestor.new(organization: @organization)

        first = ingestor.ingest(source_key: "electricity_outages", html: electricity_html)
        second = ingestor.ingest(source_key: "electricity_outages", html: electricity_html)

        assert_equal 1, first.created
        assert_equal 0, second.created
        assert_equal 1, DecidimApp::Bijeljina::CityServiceEvent.count

        event = first.events.first
        assert event.pending_review?
        assert_not_includes event.attributes.to_json, "VRATI ME NA SAJT"
      end

      test "publishing a reviewed event creates scoped system Komšiluk posts and no Viber while disabled" do
        result = CityServiceEventIngestor.new(organization: @organization)
                                         .ingest(source_key: "electricity_outages", html: electricity_html)
        event = result.events.first

        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => nil) do
          assert_no_enqueued_jobs only: CityServiceAlertNotificationJob do
            assert_difference("Decidim::Bih::KomsilukPost.count", 1) do
              @result = CityServiceEventPublisher.new(event, actor: @admin).publish_with_viber_review!
            end
          end
        end

        post = Decidim::Bih::KomsilukPost.last
        assert_equal @komsiluk, post.komsiluk
        assert_nil post.author
        assert_equal "safety", post.category
        assert_includes post.title, "Planirano"

        assert_equal :published, @result.status
        assert_equal "dry_run", event.reload.viber_delivery
        assert_equal 0, event.viber_recipients_count
        assert_equal [post.id], event.komsiluk_post_id_values
        assert_equal [@mz.slug], event.area_slugs
        assert_equal [@komsiluk.slug], event.target_komsiluk_slugs
      end

      test "publishing an already published event is idempotent" do
        result = CityServiceEventIngestor.new(organization: @organization)
                                         .ingest(source_key: "electricity_outages", html: electricity_html)
        event = result.events.first
        first = CityServiceEventPublisher.new(event, actor: @admin).publish_board!

        assert_no_difference("Decidim::Bih::KomsilukPost.count") do
          second = CityServiceEventPublisher.new(event, actor: @admin).publish_board!
          assert_equal :already_published, second.status
          assert_equal first.post_ids, second.post_ids
        end
      end

      test "board-published event can later run viber review without duplicate board posts" do
        result = CityServiceEventIngestor.new(organization: @organization)
                                         .ingest(source_key: "electricity_outages", html: electricity_html)
        event = result.events.first
        board = CityServiceEventPublisher.new(event, actor: @admin).publish_board!

        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => nil) do
          assert_no_enqueued_jobs only: CityServiceAlertNotificationJob do
            assert_no_difference("Decidim::Bih::KomsilukPost.count") do
              @result = CityServiceEventPublisher.new(event, actor: @admin).publish_with_viber_review!
            end
          end
        end

        assert_equal :published, @result.status
        assert_equal "board_published", event.reload.state
        assert_equal board.post_ids, @result.post_ids
        assert_equal board.post_ids, event.komsiluk_post_id_values
        assert_equal "dry_run", event.viber_delivery
      end

      test "publishing degrades without Komšiluk polygons instead of crashing" do
        @komsiluk.destroy!
        result = CityServiceEventIngestor.new(organization: @organization)
                                         .ingest(source_key: "electricity_outages", html: electricity_html)
        event = result.events.first

        assert_no_difference("Decidim::Bih::KomsilukPost.count") do
          publish = CityServiceEventPublisher.new(event, actor: @admin).publish_board!
          assert_equal :no_target, publish.status
        end

        assert_equal "failed", event.reload.state
        assert_equal({ "status" => "no_target" }, event.policy_snapshot)
      end

      test "city event feed answers from reviewed visible events" do
        travel_to Time.zone.local(2040, 6, 29, 8, 30, 0) do
          result = CityServiceEventIngestor.new(organization: @organization)
                                           .ingest(source_key: "electricity_outages", html: electricity_html)
          event = result.events.first
          CityServiceEventPublisher.new(event, actor: @admin).publish_board!

          answer = CityServiceEventFeed.new(organization: @organization).answer(
            text: "Ima li danas isključenja struje u Izmišljenom polju?",
            locale: :sr
          )

          assert_includes answer, "Planirano isključenje struje"
          assert_includes answer, "Izvor:"
          assert_includes answer, "provjereno"
        end
      end

      test "city event feed does not treat the letter u inside struje as a location cue" do
        travel_to Time.zone.local(2040, 6, 29, 8, 30, 0) do
          result = CityServiceEventIngestor.new(organization: @organization)
                                           .ingest(source_key: "electricity_outages", html: electricity_html)
          event = result.events.first
          CityServiceEventPublisher.new(event, actor: @admin).publish_board!

          answer = CityServiceEventFeed.new(organization: @organization).answer(
            text: "Ima li struje danas?",
            locale: :sr
          )

          assert_includes answer, "Planirano isključenje struje"
          assert_not_includes answer, I18n.t("decidim_app.city_service_events.bot.location_unknown", locale: :sr)
        end
      end

      test "city event feed still asks for clearer location when a standalone location cue is unknown" do
        answer = CityServiceEventFeed.new(organization: @organization).answer(
          text: "Ima li struje u nepoznatom naselju?",
          locale: :sr
        )

        assert_equal I18n.t("decidim_app.city_service_events.bot.location_unknown", locale: :sr), answer
      end

      test "city event feed treats Bijeljina as a citywide electricity query" do
        travel_to Time.zone.local(2040, 6, 30, 10, 30, 0) do
          answer = CityServiceEventFeed.new(
            organization: @organization,
            source_checker: source_checker_at(Time.zone.parse("2040-06-30 10:15"))
          ).answer(
            text: "da li su planirana isključenja struje u Bijeljini",
            locale: :sr
          )

          assert_includes answer, "Bijeljinu"
          assert_includes answer, "Izvor Izmišljeni pružalac je uspješno pročitan 30.06.2040. u 10:15"
          assert_includes answer, "nemam pregledano obavještenje o isključenja električne energije"
          assert_includes answer, "ne potvrđuje da prekida nema"
          assert_not_includes answer, I18n.t("decidim_app.city_service_events.bot.location_unknown", locale: :sr)
        end
      end

      test "citywide electricity questions do not answer with unrelated current water events" do
        travel_to Time.zone.local(2040, 6, 30, 9, 0, 0) do
          CityServiceEvent.create!(
            organization: @organization,
            source_key: "water_service",
            source_label: "Vodovod",
            source_fingerprint: "water-citywide-current",
            source_url: "https://example.test/water",
            event_type: "planned_interruption",
            severity: "service_outage",
            targeting_level: "citywide",
            affected_area_slugs: [],
            title: "Prekid vodosnabdijevanja",
            summary: "Prekid vode na području grada.",
            starts_at: 1.hour.ago,
            ends_at: 2.hours.from_now,
            state: "published",
            parser_version: "test"
          )

          answer = CityServiceEventFeed.new(
            organization: @organization,
            source_checker: source_checker_at(Time.zone.parse("2040-06-30 08:55"))
          ).answer(
            text: "da li su planirana isključenja struje u Bijeljini",
            locale: :sr
          )

          assert_includes answer, "Bijeljinu"
          assert_includes answer, "Izmišljeni pružalac"
          assert_not_includes answer, "Prekid vodosnabdijevanja"
          assert_not_includes answer, "Prekid vode"
        end
      end

      test "dry-run formatter returns operator-readable TSV without persistence" do
        fetcher = ->(_source) { { http_status: 200, body: electricity_html, final_url: "https://example.test/outages" } }

        rows = CityServiceNoticesDryRun.new(organization: @organization, fetcher:).call(keys: ["electricity_outages"])
        output = CityServiceNoticesDryRun.format(rows)

        assert_equal 1, rows.size
        assert_includes output, "source\tfingerprint\tstarts_at"
        assert_includes output, "electricity_outages"
        assert_equal 0, CityServiceEvent.count
      end

      test "dry-run rejects non-success HTTP response bodies before parsing" do
        fetcher = ->(_source) { { http_status: 404, body: electricity_html, final_url: "https://example.test/outages" } }

        assert_raises(RuntimeError, match: /HTTP 404/) do
          CityServiceNoticesDryRun.new(organization: @organization, fetcher:).call(keys: ["electricity_outages"])
        end
      end

      test "a repeated source scrape cannot restore a withdrawn notice awaiting correction" do
        ingestor = CityServiceEventIngestor.new(organization: @organization)
        event = ingestor.ingest(source_key: "electricity_outages", html: electricity_html).events.first
        CityServiceEventPublisher.new(event, actor: @admin).publish_board!
        result = CityServicePublicationWithdrawal.call(event:, actor: @admin, review_token: event.answer_review_token, note: "Correct provider facts", correct: true)
        assert_equal :withdrawn, result
        ingestor.ingest(source_key: "electricity_outages", html: electricity_html)
        assert event.reload.extraction_metadata["publication_correction_pending"]
        assert_empty CityServiceEvent.milica_available.where(id: event.id)
        assert_equal :updated, CityServiceEventReview.new(event:, actor: @admin, attributes: {
                                                            content_version: event.content_version, review_token: event.answer_review_token, summary: "Corrected facts"
                                                          }).call
        assert_equal [event.id], CityServiceEvent.milica_available.where(id: event.id).pluck(:id)
      end

      private

      def electricity_html
        <<~HTML
          <html>
            <body>
              <p>29.06.2040.</p>
              <table>
                <tr>
                  <th>TJ</th><th>Objekat</th><th>Područje</th><th>Razlog</th><th>Početak</th><th>Završetak</th>
                </tr>
                <tr>
                  <td>Bijeljina</td>
                  <td>TS Izmišljeno polje 1</td>
                  <td>Izmišljeno polje, izlaz prema školi</td>
                  <td>Radovi</td>
                  <td>09:00</td>
                  <td>12:00</td>
                </tr>
              </table>
            </body>
          </html>
        HTML
      end

      def official_post_html(text)
        <<~HTML
          <html>
            <body>
              <article>
                <h2>#{text}</h2>
                <p>#{text}</p>
              </article>
            </body>
          </html>
        HTML
      end

      def source_checker_at(time)
        Class.new do
          define_method(:check) do |keys:, **|
            keys.map do |source_key|
              CityServiceNoticeCollector::SourceCheckResult.new(
                source_key:,
                status: :empty,
                notices: [],
                checked_at: time,
                error_code: nil
              )
            end
          end
        end.new
      end

      def with_env(values)
        previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
        values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        yield
      ensure
        previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
    end
  end
end
