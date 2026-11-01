# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_journey_scenarios"

module DecidimApp
  module Bijeljina
    module Milica
      # Frozen journeys over authored toy text sections and points. The real
      # preparer, calendar ambiguity, route planner and typed reader remain active.
      class TransportJourneyScenariosTest < ActiveSupport::TestCase
        include SyntheticJourneyScenarios
        PREPARED_AT = Time.utc(2026, 9, 9, 10)
        SARAJEVO = ActiveSupport::TimeZone["Europe/Sarajevo"]
        CENTER_STOPS = ["Bijeljina (NAS)", "Bijeljina (spomenik)", "Bijeljina (Saborna crkva)", "Bijeljina (sud)"].freeze
        FRIDAY_EVENING = SARAJEVO.local(2026, 9, 11, 20, 0)
        SATURDAY_MORNING = SARAJEVO.local(2026, 9, 12, 10, 0)
        SATURDAY_NIGHT = SARAJEVO.local(2026, 9, 12, 21, 0)
        SUNDAY_MORNING = SARAJEVO.local(2026, 9, 13, 10, 0)
        WEDNESDAY_MORNING = SARAJEVO.local(2026, 9, 16, 7, 0)
        WEDNESDAY_LATE_MORNING = SARAJEVO.local(2026, 9, 16, 10, 0)
        WEDNESDAY_NIGHT = SARAJEVO.local(2026, 9, 16, 21, 0)

        FakeChecker = Struct.new(:notices, :checked_at) do
          def check(**)
            [CityServiceNoticeCollector::SourceCheckResult.new(source_key: "public_transport", status: :ok, notices:, checked_at:)]
          end
        end

        setup do
          DecidimApp::CityServiceSourceSnapshot.delete_all
          @organization = create_organization
          @store = CityServiceSourceCheckStore.new(clock: -> { PREPARED_AT })
          install_synthetic_journey_scenarios
          @notices = synthetic_journey_documents.map do |code, body|
            notice = CityServiceNoticeCollector::Notice.new(source_key: "public_transport", title: "Javni prevoz #{code} — izmišljeni test",
              url: "https://community.example.invalid/scenario/#{code}.pdf", fetched_at: PREPARED_AT)
            writer = PublicTransportTimetable.new(fetcher: ->(*) { body }, text_extractor: ->(text) { text }, clock: -> { PREPARED_AT },
              snapshot_store: @store, prepared_only: true, cache: false)
            assert_equal :ok, writer.prepare(notices: [notice]).first.fetch(:status), code
            notice
          end
        end

        teardown { restore_synthetic_journey_scenarios }

        # 1. Weekday morning, citizen text only: the model extracted nothing.
        test "morning journey from the citizen's words gives the next two departures towards the town centre" do
          result = read({ "query" => "kad ide sljedeci autobus iz Primjervrt (CSP) za centar" }, now: WEDNESDAY_MORNING)

          assert_next_journey(result, now: WEDNESDAY_MORNING, origin: "primjervrt csp", destination: "centar")
          assert_equal 2, result.coverage.fetch("options")
          assert_includes CENTER_STOPS, legs(result).first.fetch("coverage").fetch("destination")
          assert_equal "2026-09-16", result.coverage.fetch("service_day")
          assert_not result.validity.has_key?("rolled_over")
        end

        test "a broad settlement origin offers named stops without choosing one for the citizen" do
          result = read({ "query" => "kad ide sljedeci autobus iz Primjervrta za centar" }, now: WEDNESDAY_MORNING)

          assert_equal "ambiguous", result.status
          assert_includes result.warnings, "transport_origin_ambiguous"
          assert_empty result.facts
          assert_operator result.candidates.length, :>, 1
          assert(result.candidates.any? { |candidate| candidate.fetch("text").include?("Primjervrt (CSP)") })
        end

        # 2. Evening: nothing left today, rolls to tomorrow and says so.
        test "evening journey rolls to tomorrow and says today is finished" do
          result = read({ "query" => "kad ide sljedeci autobus iz Primjervrt (CSP) za centar" }, now: WEDNESDAY_NIGHT)

          assert_next_journey(result, now: WEDNESDAY_NIGHT, origin: "primjervrt csp", destination: "centar")
          assert_equal "2026-09-16", result.coverage.fetch("requested_service_day")
          assert_equal "2026-09-17", result.coverage.fetch("service_day")
          assert_equal true, result.validity.fetch("rolled_over")
          assert_includes legs(result).first.fetch("text"), "Danas više nema polazaka"
          assert_includes legs(result).first.fetch("text"), "sutra (četvrtak 17.9.2026)"
        end

        # 3. Saturday night: Sunday publishes no departures, so Monday it is.
        test "saturday night rolls past the unpublished sunday to monday" do
          result = read({ "query" => "kad ide sljedeci autobus iz Primjervrt (CSP) za centar" }, now: SATURDAY_NIGHT)

          assert_next_journey(result, now: SATURDAY_NIGHT, origin: "primjervrt csp", destination: "centar")
          assert_equal "2026-09-14", result.coverage.fetch("service_day")
          assert_includes result.warnings, "no_departures_published_for_service_day"
          assert_includes legs(result).first.fetch("text"), "u ponedjeljak 14.9.2026"
        end

        # 4. Sunday: the requested day itself has no published departures.
        test "sunday morning names the day without departures and gives monday's first bus" do
          result = read({ "query" => "kad ide sljedeci autobus iz Primjervrt (CSP) za centar" }, now: SUNDAY_MORNING)

          assert_next_journey(result, now: SUNDAY_MORNING, origin: "primjervrt csp", destination: "centar")
          assert_equal "2026-09-13", result.coverage.fetch("requested_service_day")
          assert_equal "2026-09-14", result.coverage.fetch("service_day")
          assert_includes legs(result).first.fetch("text"), "Danas (nedjelja) nema objavljenih polazaka"
        end

        # 5. Holiday: the documents publish no holiday section; nothing is invented.
        test "a holiday request without a reviewed holiday section invents no departure" do
          result = read({ "query" => "kad ide autobus iz Primjervrt (CSP) za centar na praznik", "date" => "2026-11-21" }, now: WEDNESDAY_MORNING)

          assert_equal "unavailable", result.status, result.warnings.inspect
          assert_includes result.warnings, "unsupported_service_day"
          assert_empty result.facts
        end

        # 6. Missing then broad origin: destination survives both narrow clarifications.
        test "a destination-only question preserves its destination while narrowing a broad origin" do
          first = read({ "query" => "koji autobus ide za Primjerpolju i kad" }, now: SATURDAY_MORNING)

          assert_equal "ambiguous", first.status
          assert_equal ["transport_origin_required"], first.warnings
          assert_empty first.facts

          second = read({ "query" => "Krećem iz centra", "area_query" => "Primjerpolju", "stop" => "centra" }, now: SATURDAY_MORNING)

          assert_equal "ambiguous", second.status
          assert_includes second.warnings, "transport_origin_ambiguous"
          assert_empty second.facts
          assert_operator second.candidates.length, :>, 1

          third = read({ "query" => "Od NAS", "area_query" => "Primjerpolju", "stop" => "centra" }, now: SATURDAY_MORNING)
          assert_next_journey(third, now: SATURDAY_MORNING, origin: "nas", destination: "Primjerpolju")
          assert_match(/\APrimjerpolje/, legs(third).last.fetch("coverage").fetch("destination"))
        end

        # 7. Unknown destination: no reviewed stop supports it; a partial word
        #    overlap ("selo" in "Velino selo") cannot invent a candidate.
        test "an unknown destination is reported as unmatched instead of guessed" do
          unknown = read({ "query" => "kad ide autobus iz centra za Nepoznatovac" }, now: SATURDAY_MORNING)
          partial = read({ "query" => "kad ide autobus iz centra za Nepoznato Selo" }, now: SATURDAY_MORNING)

          assert_equal "empty", unknown.status
          assert_includes unknown.warnings, "destination_not_in_reviewed_timetable"
          assert_empty unknown.facts
          assert_equal "empty", partial.status
          assert_includes partial.warnings, "destination_not_in_reviewed_timetable"
          assert_empty partial.candidates
          assert_empty partial.facts
        end

        # 8. A fare question is not a journey.
        test "a fare question keeps the reviewed price answer and never a departure" do
          result = read({ "query" => "koliko kosta karta za autobus" }, now: SATURDAY_MORNING)

          assert_equal "ok", result.status
          assert_equal(["service_directory"], result.facts.map { |fact| fact.fetch("kind") })
          assert_includes result.facts.first.fetch("text"), "2,37 KM"
        end

        # 9. "Tomorrow morning" is tomorrow at 05:00, not tomorrow at this hour.
        test "tomorrow morning from Primjerpolje to Bijeljina starts at dawn on the next day" do
          result = read({ "query" => "autobus za Bijeljinu iz Primjerpolje (centar) sutra ujutru" }, now: FRIDAY_EVENING)

          # The toy stop has an explicitly assumed point; it is not surveyed geometry.
          assert_next_journey(result, now: FRIDAY_EVENING, origin: "primjerpolje centar", destination: "bijeljinu")
          assert_match(/Primjerpolje/, legs(result).first.fetch("coverage").fetch("origin"))
          assert_not_includes result.warnings, "stop_registry_partial"
          assert_includes result.warnings, "assumed_stop_coordinates"
          assert_equal "2026-09-12", result.coverage.fetch("requested_service_day")
          assert_equal "2026-09-12", result.coverage.fetch("service_day")
          departure = departures(result).first
          assert_operator departure, :>=, SARAJEVO.local(2026, 9, 12, 5, 0)
          assert_operator departure, :<, SARAJEVO.local(2026, 9, 12, 12, 0)
          assert_includes CENTER_STOPS, legs(result).last.fetch("coverage").fetch("destination")
          assert_not result.validity.has_key?("rolled_over")
        end

        # 10. A street is not a stop: nearest reviewed stop, said aloud, with the walking link.
        test "a street origin boards at the nearest reviewed stop and says so" do
          result = read({ "query" => "sa Izmišljene breze do bolnice" }, now: SATURDAY_MORNING)

          assert_next_journey(result, now: SATURDAY_MORNING, origin: "izmisljene breze", destination: "bolnice")
          assert_includes result.warnings, "origin_resolved_from_street"
          assert_equal "Izmišljena breza", result.coverage.fetch("origin_street")
          assert_equal "Bijeljina (bolnica)", legs(result).last.fetch("coverage").fetch("destination")
          assert_includes legs(result).first.fetch("text"), "Ulica Izmišljena breza nije stajalište"
          assert_includes legs(result).first.fetch("text"), result.coverage.fetch("origin")
        end

        # 11. "After 17h" is a lower bound on the requested day.
        test "after seventeen from the centre to Patkovača starts at seventeen" do
          result = read({ "query" => "iz NAS za Primjerdalje poslije 17h" }, now: SATURDAY_MORNING)

          assert_next_journey(result, now: SATURDAY_MORNING, origin: "nas", destination: "primjerdalje")
          assert_operator departures(result).first, :>=, SARAJEVO.local(2026, 9, 12, 17, 0)
          assert_equal "Primjerdalje (spomenik)", legs(result).last.fetch("coverage").fetch("destination")
          assert_equal "2026-09-12", result.coverage.fetch("service_day")
        end

        # 12. "Last tonight" is the latest departure still on the requested day.
        test "the last bus tonight is the latest departure of the day, one option only" do
          result = read({ "query" => "kad je zadnji autobus za Primjerpolju večeras", "stop" => "Bijeljina (NAS)" }, now: SATURDAY_MORNING)

          assert_next_journey(result, now: SATURDAY_MORNING, origin: "Bijeljina (NAS)", destination: "primjerpolju")
          assert_equal 1, result.coverage.fetch("options")
          assert_equal "2026-09-12 18:50", local(departures(result).first)
          assert_match(/\APrimjerpolje/, legs(result).last.fetch("coverage").fetch("destination"))
          assert_not result.validity.has_key?("rolled_over")
        end

        # 13. When the last bus has left and the next reviewed day is under review, nothing is invented.
        test "after the last bus a Primjerpolje request stays honest about the unreviewed weekday section" do
          result = read({ "query" => "kad je zadnji autobus za Primjerpolju večeras", "stop" => "Bijeljina (NAS)" }, now: SARAJEVO.local(2026, 9, 12, 20, 0))

          assert_equal "unreviewed", result.status
          assert_includes result.warnings, "service_calendar_requires_review"
          assert_empty result.facts
        end

        # 14. Cyrillic question, Cyrillic answer, same journey.
        test "a cyrillic journey question is answered in cyrillic with the same departures" do
          result = read({ "query" => "Кад иде следећи аутобус из Примјерврт (ЦСП) за центар" }, now: WEDNESDAY_MORNING, locale: "sr-Cyrl")
          latin = read({ "query" => "kad ide sljedeci autobus iz Primjervrt (CSP) za centar" }, now: WEDNESDAY_MORNING)

          assert_next_journey(result, now: WEDNESDAY_MORNING, origin: "primjervrt csp", destination: "centar", locale: "sr-Cyrl")
          assert_match(/\p{Cyrillic}/, legs(result).first.fetch("text"))
          assert_includes legs(result).first.fetch("text"), "Примјерврт"
          assert_equal departures(latin), departures(result)
        end

        # 15. A deliberately historical question may show past departures, and says so.
        test "this morning at seven shows the past departure and says it has passed" do
          result = read({ "query" => "koji je autobus vozio jutros u 7 iz NAS za Primjervrt" }, now: WEDNESDAY_LATE_MORNING)

          assert_equal "ok", result.status
          assert_equal true, result.validity.fetch("historical")
          assert_equal "2026-09-16 08:30", local(departures(result).first)
          assert_includes legs(result).first.fetch("text"), "već prošlo"
        end

        # 16. A "when" question with a clock that has passed drops the clock, says so, and never looks back.
        test "a next-bus question naming a past clock answers from now and says the clock has passed" do
          result = read({ "query" => "kad ide autobus iz NAS za Primjervrt danas u 7" }, now: WEDNESDAY_LATE_MORNING)

          assert_next_journey(result, now: WEDNESDAY_LATE_MORNING, origin: "nas", destination: "primjervrt")
          assert_includes legs(result).first.fetch("text"), "Polazak u 07:00 je već prošao"
        end

        private

        def read(entities, now:, location: nil, locale: "sr")
          reader = PublicTransportTimetable.new(clock: -> { now }, snapshot_store: @store, cache: false)
          port = ReadPort.new(organization: @organization, source_checker: FakeChecker.new(@notices, PREPARED_AT), timetable: reader)
          port.define_singleton_method(:log_failure) { |error, _action| raise error }
          context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "f" * 64, now:, capabilities: ["public_reads"]
          )
          port.call(action: "ask_information", topic: "transport", entities:, context:, locale:, location:)
        end

        def legs(result)
          result.facts.select { |fact| fact["kind"] == "transport_leg" }
        end

        def departures(result)
          legs(result).map { |fact| Time.iso8601(fact.fetch("starts_at")) }
        end

        def local(time)
          time.in_time_zone(SARAJEVO).strftime("%Y-%m-%d %H:%M")
        end

        def assert_next_journey(result, now:, origin:, destination:, **options)
          walking = options.fetch(:walking, true)
          locale = options.fetch(:locale, "sr")
          assert_equal "ok", result.status, result.warnings.inspect
          assert_operator legs(result).size, :>=, 1
          departures(result).each { |departure| assert_operator departure, :>, now, "departure #{local(departure)} is not after #{local(now)}" }
          alternative_departure(result)&.then { |departure| assert_operator departure, :>, now, "second option #{local(departure)} is not after #{local(now)}" }
          assert_operator result.coverage.fetch("options"), :<=, 2
          assert_equal origin, result.coverage.fetch("origin_query")
          assert_equal destination, result.coverage.fetch("destination_query")
          navigation = result.facts.find { |fact| fact["kind"] == "transport_navigation" }
          return assert_nil(navigation, "no walking link expected for a stop without reviewed coordinates") unless walking

          assert navigation, "walking link to the boarding stop expected"
          assert_includes navigation.fetch("destination"), "https://www.google.com/maps/dir/"
          boarding = Decidim::Bih::Transliterator.localize(legs(result).first.fetch("coverage").fetch("origin"), locale:)
          assert_includes navigation.fetch("text"), boarding
        end

        # The second option lives in the last leg's text; a plain HH:MM is on
        # the answered service day, a "(d.m.)" suffix on another day.
        def alternative_departure(result)
          text = legs(result).last.fetch("text")
          match = text.match(/Sljedeći polazak: (?<hour>\d{2}):(?<minute>\d{2})(?: \((?<day>\d{1,2})\.(?<month>\d{1,2})\.\))?/)
          return unless match

          date = Date.iso8601(result.coverage.fetch("service_day"))
          date = Date.new(date.year, match[:month].to_i, match[:day].to_i) if match[:day]
          SARAJEVO.local(date.year, date.month, date.day, match[:hour].to_i, match[:minute].to_i)
        end
      end
    end
  end
end
