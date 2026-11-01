# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "json"
require "i18n"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/hash/slice"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/exclude"
require "active_support/core_ext/array/access"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
# Standalone contract files must not depend on another test loading transport.
%w(walking_estimate nearby_stops timetable_snapshot journey_query journey_planner stop_resolver).each do |name|
  require File.join(engine_root, "app/services/decidim/bih/transport", name)
end
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/procedure_runner")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/coordinator")
require File.join(engine_root, "app/services/decidim/bih/infobip/bounded_chat_text")
require_relative "../../app/services/decidim_app/bijeljina/chat_text_rendering"
require File.join(engine_root, "lib/decidim/bih/transliterator")
require_relative "../../app/services/decidim_app/bijeljina/milica/transport_journey_question"
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/source_refresh_budget"
require_relative "../../app/services/decidim_app/bijeljina/city_service_source_check_store"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_calendar"
require_relative "../../app/services/decidim_app/bijeljina/reviewed_transport_timetables"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_timetable"

require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

# Authored synthetic image-backed schedules; no Rails, database or network.
require_relative "../support/synthetic_transport_network"

class MilicaTransportQualityTest < Minitest::Test
  include SyntheticTransportNetwork
  class CalendarMemoryRedis
    def initialize = @data = {}
    def get(key) = @data[key]
    def eval(script, keys:, argv:)
      raise "Unexpected state operation" unless script == Decidim::Bih::Concierge::Dialogue::StateStore::WRITE_SCRIPT
      version = @data[keys.first] ? JSON.parse(@data[keys.first]).fetch("version") : 0
      return 0 unless version == argv.first

      @data[keys.first] = argv[1]
      1
    end
  end

  class CalendarInlineRuntime
    def call
      dialogue = Decidim::Bih::Concierge::Dialogue
      dialogue::AdmissionControl::Result.new(status: :admitted, value: yield(dialogue::TurnBudget.new(timeout: 2, clock: -> { 0.0 })))
    end
  end

  def test_calendar_followups_use_actual_serialized_state_and_reader
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
      capabilities: ["public_reads"], now: NOW)
    [
      ["Koji G1 polasci važe u nedjelju 20.9.2026?", "Da li za taj datum imaš potvrđenu uslugu?", "no_departures_published_for_service_day"],
      ["Kako ide G1 na državni praznik?", "Treba li ti tačan datum?", "transport_calendar_date_required"]
    ].each do |opening, followup, warning|
      [{}, { "query" => "G1" }, { "stop" => "G1", "area_query" => opening.include?("nedjelju") ? "nedjelju" : "državni praznik" }].each do |model_entities|
        store = dialogue::StateStore.new(redis: CalendarMemoryRedis.new)
        reads = []
        model_calls = 0
        runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
          result = transport_port.call(**args)
          reads << result
          result
        }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
        coordinator = dialogue::Coordinator.new(procedures: runner, state_store: store, runtime: CalendarInlineRuntime.new,
          understanding: lambda { |**|
            model_calls += 1
            flunk "Calendar follow-up reached model" if model_calls > 1
            dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "start",
              entities: model_entities, locale: "sr", needs_clarification: false, secondary: nil)
          })
        message = Struct.new(:text, :dialogue_location)
        first_result = I18n.with_locale(:sr) { coordinator.call(message: message.new(opening, nil), context:) }
        persisted = store.read(context:)
        assert_equal opening, persisted&.dig("entities", "query"), {model_entities:, reads: reads.size, resolution: first_result.resolution, state: first_result.state&.slice("active_task", "entities", "entity_provenance"), persisted: persisted&.slice("active_task", "entities", "entity_provenance")}.inspect
        assert_equal "G1", persisted.dig("entities", "route")
        assert_nil persisted.dig("entities", "stop")
        assert_nil persisted.dig("entities", "area_query")
        final = I18n.with_locale(:sr) { coordinator.call(message: message.new(followup, nil), context:) }
        assert_equal 2, reads.length
        assert_includes reads.first.warnings, warning
        assert_includes reads.last.warnings, warning
        assert_equal opening, store.read(context:).dig("entities", "query")
        if warning == "transport_calendar_date_required"
          assert_equal "time_expression", final.state["pending_slot"]
          assert_includes final.reply.text, "Da, napiši tačan datum"
        else
          assert_equal "2026-09-20", final.state.dig("entities", "date")
          assert_includes final.reply.text, "To nije potvrda da autobus"
        end
        refute_includes final.reply.text, "Odakle"
      end
    end
  end

  def test_actual_journey_read_does_not_earn_calendar_query_retention
    dialogue = Decidim::Bih::Concierge::Dialogue
    text = "Od NAS do Primjerparka 16.9.2026. poslije 06:00"
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
      capabilities: ["public_reads"], now: NOW)
    reads = []
    runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
      result = transport_port.call(**args)
      reads << result
      result
    }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
    understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "start",
      entities: {}, locale: "sr", needs_clarification: false, secondary: nil)
    initial = runner.call(understanding:, state: dialogue::StateStore.new.empty_state(context), context:,
      message: Struct.new(:text, :dialogue_location).new(text, nil))
    assert_equal "ok", reads.first.status
    refute_equal "calendar", reads.first.coverage["transport_query_scope"]
    assert initial.state.dig("entities", "stop")
    assert initial.state.dig("entities", "area_query")
    assert_nil dialogue::TransportFollowUpQuestion.calendar_continuation_query("Da li za taj datum imaš potvrđenu uslugu?", state: initial.state)
  end

  def test_calendar_followup_retains_real_reader_scope_when_model_omits_or_shortens_query
    dialogue = Decidim::Bih::Concierge::Dialogue
    first = "Koji G1 polasci važe u nedjelju 20.9.2026?"
    followup = "Da li za taj datum imaš potvrđenu uslugu?"
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
      capabilities: ["public_reads"], now: NOW)
    [{}, { "query" => "G1" }, { "query" => first }, { "stop" => "G1", "area_query" => "nedjelju" }].each do |model_entities|
      state = dialogue::StateStore.new.empty_state(context)
      reads = []
      runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
        result = transport_port.call(**args)
        reads << result
        result
      }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "start",
        entities: model_entities, locale: "sr", needs_clarification: false, secondary: nil)
      initial = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(first, nil))
      assert_includes reads.first.warnings, "no_departures_published_for_service_day"
      state = initial.state
      continuation = dialogue::TransportFollowUpQuestion.call(followup, state:)
      refute_nil continuation, "Calendar lost after actual reader: #{state.slice('active_task', 'topic', 'pending_slot', 'entities').inspect}"
      following = runner.call(understanding: dialogue::Contracts::Understanding.parse(continuation), state:, context:,
        message: Struct.new(:text, :dialogue_location).new(followup, nil))
      assert_includes reads.last.warnings, "no_departures_published_for_service_day"
      assert_equal "2026-09-20", following.state.dig("entities", "date")
      assert_equal "G1", following.state.dig("entities", "route")
      assert_includes following.reply.text, "To nije potvrda da autobus"
      refute_includes following.reply.text, "Odakle"
    end
  end

  def test_route_then_vehicle_keeps_literal_destination_without_proving_connection
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["Mogu li G1 pa prigradskim za Primjerpolje?", "Могу ли Г1 па приградским за Примјерпоље?", "Može li P9 onda drugim autobusom do Primjervrta?"].each do |query|
      selected = parser.call({ "query" => query })
      assert_nil selected.warning, query
      assert_match(/primjerpolj|primjervrt/, selected.entities.fetch("area_query"))
      assert_nil selected.entities["stop"], "missing origin is never invented"
      assert_match(/\A[GP]\d+\z/, selected.entities.fetch("route"), "do not silently drop an explicit route constraint")
      answer = read({ "query" => query })
      assert_includes answer.warnings, "transport_origin_required"
      refute_includes answer.warnings, "transport_destination_required"
    end
    unsupported = parser.call({ "query" => "Od Primjerpolja do centra pa do Primjervrta" })
    assert_equal "transport_via_required", unsupported.warning
  end

  def test_origin_correction_preservation_clause_never_becomes_a_place
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["Ispravka: polazim iz Primjervrta, cilj je isti.", "Krećem iz Primjerpolja, odredište ostaje isto.", "Полазим из Примјерврта, крајње одредиште је исто."].each do |query|
      selected = parser.call({ "query" => query, "stop" => "Bijeljina NAS", "area_query" => "centar" })
      assert_nil selected.warning, query
      assert_match(/\A(?:primjervrta|primjerpolja)\z/, selected.entities.fetch("stop"))
      assert_equal "centar", selected.entities.fetch("area_query")
    end
    explicit = parser.call({ "query" => "Krećem iz Primjervrta za Primjerpolje", "area_query" => "centar" })
    assert_equal "primjerpolje", explicit.entities.fetch("area_query"), "a real destination change is retained"
  end

  def test_english_transport_return_prefix_is_not_a_destination
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["Back to the bus after 09:00", "Back to the bus at noon", "Return to transport on 19.9.2026. after 09:00"].each do |query|
      selected = parser.call({ "query" => query, "stop" => "Primjerpark", "area_query" => "ATC" })
      assert_nil selected.warning, query
      assert_equal "ATC", selected.entities.fetch("area_query")
      assert_equal query, selected.entities.fetch("query"), "the time parser keeps the original calendar and clock words"
    end
    ["Back to the bus, from NAS to ATC after 09:00", "Back to the bus from NAS to ATC after 09:00"].each do |query|
      selected = parser.call({ "query" => query, "stop" => "Primjerpark" })
      assert_nil selected.warning
      assert_equal "nas", selected.entities.fetch("stop")
      assert_equal "atc", selected.entities.fetch("area_query")
    end
  end

  def test_literal_part_of_day_overrides_retained_numeric_clock
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["Vratimo se autobusu u podne", "Vratimo se autobusu poslije podne", "Back to the bus at noon"].each do |query|
      selected = parser.call({ "query" => query, "stop" => "Primjerpark", "area_query" => "ATC", "date" => "2026-09-16", "time_expression" => "06:00" })
      assert_nil selected.warning, query
      assert_equal "12:00", selected.entities.fetch("time_expression")
      window = parser.requested_window(selected.entities, now: Time.utc(2026, 9, 15, 10))
      assert_equal "2026-09-16T12:00:00+02:00", window.earliest_after.iso8601
      assert_equal false, window.rolled_clock
    end
  end

  def test_real_bus_station_and_nonleading_return_are_not_stripped_as_control_phrases
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["Return to the bus station", "He said back to the bus at noon"].each do |query|
      # These are not affirmative conversation returns. They must not silently
      # turn into the retained ATC destination after prefix normalization.
      selected = parser.call({ "query" => query, "stop" => "Primjerpark", "area_query" => "ATC" })
      assert_equal false, selected.entities["area_query"] == "ATC", query
    end
  end

  def test_explicit_cyrillic_destination_correction_keeps_origin_and_window_with_real_reader
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: Time.utc(2026, 9, 15, 10))
    state = dialogue::StateStore.new.empty_state(context)
    reads = []
    runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
      result = transport_port.call(**args)
      reads << result
      result
    }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
    [
      ["Који аутобус иде од НАС-а до Примјерпарка 16.9.2026. послије 06:00?", "start"],
      ["Погријешио сам, не идем на Примјерпарк него на АТЦ. Полазим и даље са НАС-а.", "continue"]
    ].each do |text, operation|
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation:,
                                                               entities: {}, locale: "sr-Cyrl", needs_clarification: false, secondary: nil)
      message = Struct.new(:text, :dialogue_location).new(text, nil)
      result = runner.call(understanding:, state:, context:, message:)
      assert_equal "answered", result.resolution
      state = result.state
    end
    coverage = reads.last.coverage.fetch("transport_query_entities")
    assert_equal "atc", coverage.fetch("area_query")
    assert_equal "nas a", coverage.fetch("stop")
    assert_equal "2026-09-16", coverage.fetch("date")
    assert_equal "06:00", coverage.fetch("time_expression")
    leg = reads.last.facts.find { |fact| fact["kind"] == "transport_leg" }
    assert_includes leg.fetch("text"), "Г2"
    assert_includes leg.fetch("text"), "2026-09-16 07:25"
    assert_includes leg.fetch("text"), "2026-09-16 07:45"
    assert_equal false, leg.fetch("text").include?("Примјерпарк")
  end

  def test_destination_correction_is_bounded_and_invalidates_retained_route
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["Pogriješio sam, ne idem na Primjerpark nego na ATC. Polazim i dalje sa NAS-a.",
     "Не идем на Примјерпарк него на АТЦ. Полазим и даље са НАС-а."].each do |query|
      selected = parser.call({ "query" => query, "stop" => "other", "area_query" => "Primjerpark", "route" => "G1" })
      assert_nil selected.warning
      assert_equal "atc", selected.entities.fetch("area_query")
      assert_equal "nas a", selected.entities.fetch("stop")
      assert_equal false, selected.entities.has_key?("route")
    end
    ["Ne idem na Primjerpark", "Ne idem na Primjerpark nego na ATC ili bolnicu", "Ne idem na Primjerpark nego na ATC. Pošalji prijavu.",
     "Ne idem na praznik nego na posao", "Ne idem na Primjerpark nego na ATC. Ne polazim sa NAS-a."].each do |query|
      selected = parser.call({ "query" => query })
      assert_equal "transport_destination_required", selected.warning, query
    end
  end

  def test_holiday_suffix_is_not_part_of_the_destination
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["kad ide autobus iz Primjervrt (CSP) za centar na praznik",
     "кад иде аутобус из Примјерврт (ЦСП) за центар на празник"].each do |query|
      selected = parser.call({ "query" => query, "date" => "2026-11-21" }, now: Time.utc(2026, 9, 16, 5))
      assert_nil selected.warning
      assert_equal "centar", selected.entities.fetch("area_query")
      assert_equal "primjervrt csp", selected.entities.fetch("stop")
      assert_equal "2026-11-21", selected.entities.fetch("date")
      assert_equal query, selected.entities.fetch("query")
    end
  end

  def test_retest_nas_aliases_preserve_exact_boarding_and_exclude_unrelated_stops
    ["nova autobuska stanica", "nove autobuske stanice", "nove stanice", "нове аутобуске станице", "NAS-a", "Bijeljina (NAS)", "novoj autobuskoj stanici", "novom autobuskom stanicom", "Nova AS"].each do |origin|
      answer = @reader.query(origin:, destination: "ATC", requested_at: Time.zone.local(2026, 9, 16, 6), notices: @notices)
      assert_equal :ok, answer.status, origin
      assert_equal "Bijeljina (NAS)", answer.itinerary.legs.first.origin_label, origin
    end
    assert_equal [], @reader.send(:matching_stops, @reader.send(:stop_registry), "ne nova autobuska stanica")
    assert_equal [], @reader.send(:matching_stops, @reader.send(:stop_registry), "nepostojeca stanica")
  end

  def test_explicit_endpoint_role_declarations_are_bounded_and_order_independent
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    [
      "Polazim sa Primjervrt (CSP), odredište Primjerpolje (centar).",
      "Krećem iz Primjervrt (CSP); odredište je Primjerpolje (centar).",
      "Odredište je Primjerpolje (centar), polazište Primjervrt (CSP).",
      "Полазно стајалиште је Примјерврт (CSP); крајње одредиште Примјерпоље (центар)."
    ].each do |query|
      result = parser.call({ "query" => query, "stop" => "stale origin", "area_query" => "stale destination" }, now: NOW)
      assert_nil result.warning, query
      assert_equal "primjervrt csp", result.entities.fetch("stop"), query
      assert_equal "primjerpolje centar", result.entities.fetch("area_query"), query
    end
    initial = parser.call({ "query" => "Kako iz Primjervrta autobusom do Primjerpolja uz presjedanje?" }, now: NOW)
    assert_equal "primjervrta", initial.entities.fetch("stop")
    assert_equal "primjerpolja", initial.entities.fetch("area_query")

    ["Odredište nije Primjerpolje (centar).", "Odredište Primjerpolje ili Primjervrt.", "Odredište Primjerpolje, odredište Primjervrt."].each do |query|
      result = parser.call({ "query" => query, "stop" => "NAS", "area_query" => "ATC" }, now: NOW)
      assert_equal "NAS", result.entities.fetch("stop"), query
      assert_equal "ATC", result.entities.fetch("area_query"), query
    end
    preserved = parser.call({ "query" => "Polazim sa Bijeljina (NAS), cilj je isti.", "area_query" => "Primjerpolje" }, now: NOW)
    assert_equal "bijeljina nas", preserved.entities.fetch("stop")
    assert_equal "Primjerpolje", preserved.entities.fetch("area_query")
  end

  def test_retest2_parser_keeps_geography_separate_from_discourse_and_facets
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    first = parser.call({ "query" => "Iz Batkovića u centar pa do Primjervrta, može veza?" })
    assert_equal "primjervrta", first.entities.fetch("area_query")
    assert_equal "batkovica", first.entities.fetch("stop")
    assert_equal "centar", first.entities.fetch("via_stop")
    second = parser.call(first.entities.merge("query" => "Koliko vremena ostaje za prelazak do drugog stajališta?"))
    assert_equal "primjervrta", second.entities.fetch("area_query")
    assert_equal "batkovica", second.entities.fetch("stop")
    assert_equal "transport_via_required", second.warning
    ["Razlikuje li se od smjera ka spomeniku?", "Odvoji gradske podatke od međugradskog reda."].each do |query|
      selected = parser.call({ "query" => query, "stop" => "NAS", "area_query" => "Primjerpolje" })
      assert_equal "NAS", selected.entities.fetch("stop")
    end
    missing = parser.call({ "query" => "Krećem sa Bijeljina (NAS)." })
    assert_equal "transport_destination_required", missing.warning
    assert_equal "bijeljina nas", missing.entities.fetch("stop")
  end

  def test_retest2_saturday_origin_and_destination_exclude_departure_words
    answer = read({ "query" => "Za subotu 19.9.2026, sa NAS do centra, prvi polazak nakon 08:10?" })
    assert_equal "ok", answer.status
    assert_equal "centra", answer.coverage.fetch("transport_query_entities").fetch("area_query")
    assert_equal "2026-09-19", answer.coverage.fetch("transport_query_entities").fetch("date")
    assert answer.facts.any? { |fact| fact["kind"] == "transport_leg" && fact.fetch("text").include?("Bijeljina (NAS)") }
    scope = read({ "query" => "Odvoji gradske podatke od međugradskog reda.", "stop" => "centar", "area_query" => "Sarajevo" })
    assert_equal "ok", scope.status
    assert_includes scope.facts.first.fetch("text"), "ne mogu potvrditi međugradski red"
  end

  def test_retest2_successful_calendar_facts_satisfy_real_runner_contract
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: NOW)
    state = dialogue::StateStore.new.empty_state(context)
    runner = dialogue::ProcedureRunner.new(read_port: transport_port, registration_port: ->(**) { flunk "No write" }, destinations: { support: "/pages/pomoc" })
    ["Г1 у суботу у смјеру ка НАС?", "Разликује ли се од смјера ка споменику?"].each_with_index do |text, index|
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                               entities: {}, locale: "sr-Cyrl", needs_clarification: false, secondary: nil)
      result = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil))
      assert_equal "answered", result.resolution
      assert_includes result.reply.text, "Г1"
      state = result.state
    end
    assert_equal "G1", state.fetch("entities").fetch("route")
    assert_equal "2026-09-19", state.fetch("entities").fetch("date")
    assert_nil state.fetch("entities")["stop"]
    assert_equal false, DecidimApp::Bijeljina::Milica::TransportJourneyQuestion.calendar_question?({ "query" => "Telefon prevoznika G1 za smjer ka NAS?", "route" => "G1" })
  end

  def test_retest2_calendar_day_followup_does_not_start_a_journey
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: NOW)
    state = dialogue::StateStore.new.empty_state(context)
    reads = []
    runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
      answer = transport_port.call(**args)
      reads << answer
      answer
    }, registration_port: ->(**) { flunk "No write" }, destinations: { support: "/pages/pomoc" })
    ["Vozi li G1 subotom?", "A nedjeljom?"].each_with_index do |text, index|
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                               entities: {}, locale: "sr", needs_clarification: false, secondary: nil)
      state = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil)).state
    end
    assert_equal "ok", reads.first.status
    assert_equal "empty", reads.last.status
    assert_includes reads.last.warnings, "no_departures_published_for_service_day"
    assert_equal "2026-09-20", state.fetch("entities").fetch("date")
    assert_nil state.fetch("entities")["stop"]
    assert_equal false, DecidimApp::Bijeljina::Milica::TransportJourneyQuestion.calendar_question?({ "query" => "A nedjeljom?", "route" => "G1", "date" => "2026-09-19", "stop" => "NAS", "area_query" => "ATC" })
  end

  def test_retest2_named_primjerpolje_candidates_precede_anonymous_placeholders
    answer = journey("Primjerpolje", "centar")
    assert_equal :ambiguous, answer.status
    assert_includes answer.warnings, "transport_origin_ambiguous"
    labels = answer.candidates.map { |candidate| candidate.fetch("text") }
    assert_includes labels, "Primjerpolje (škola)"
    assert_includes labels, "Primjerpolje (centar)"
    assert_equal false, labels.first.start_with?("N.N.")
  end

  def test_retest2_transfer_detail_uses_computed_stops_and_wait
    answer = read({ "query" => "Gdje tačno presjedam i koliko čekam drugi autobus?", "stop" => "Primjerpark", "area_query" => "ATC",
                    "date" => "2026-09-16", "time_expression" => "06:00" })
    assert_equal "ok", answer.status
    assert_equal 1, answer.facts.size
    assert_includes answer.facts.first.fetch("text"), "20 minuta"
    assert_includes answer.facts.first.fetch("text"), "Bijeljina (NAS)"
    assert_includes answer.facts.first.fetch("text"), "G1 → G2"
    assert_includes answer.facts.first.fetch("text"), "nije potvrda stanja uživo"
    assert_equal "ATC", answer.coverage.fetch("transport_query_entities").fetch("area_query")
  end

  def test_pending_primjervrt_origin_cannot_be_selected_by_model_without_citizen_choice
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
      capabilities: ["public_reads"], now: Time.utc(2026, 9, 15, 22, 13, 38))
    ["Polazim sa Primjervrt (CSP), odredište Primjerpolje (centar).",
     "Odredište je Primjerpolje (centar); polazište je Primjervrt (CSP)."].each do |choice|
      state = dialogue::StateStore.new.empty_state(context)
      reads = []
      runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
        answer = transport_port.call(**args)
        reads << answer
        answer
      }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
      [
        ["Kako iz Primjervrta autobusom do Primjerpolja uz presjedanje?", {}],
        ["Sačuvaj oba kraja puta dok tražiš vezu.", { stop: "Primjervrt (CSP)", area_query: "Primjerpolje (centar)" }],
        [choice, { stop: "Primjervrt (CSP)", area_query: "Primjerpolje (centar)" }]
      ].each_with_index do |(text, entities), index|
        understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport",
          operation: index.zero? ? "start" : "continue", entities:, locale: "sr", needs_clarification: false, secondary: nil)
        result = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil))
        state = result.state
        if index < 2
          assert_equal "ambiguous", reads.last.status
          assert_includes reads.last.warnings, "transport_origin_ambiguous"
          assert_equal "stop", state["pending_slot"]
          assert_empty reads.last.facts
          refute_match(/06:27|07:33|maps[.]google|google[.]com.*maps/, result.reply.text)
        else
          assert_equal "ok", reads.last.status
          assert_equal "primjervrt csp", state.fetch("entities").fetch("stop")
          assert_equal "primjerpolje centar", state.fetch("entities").fetch("area_query")
          assert reads.last.facts.any? { |fact| fact["kind"] == "transport_leg" && fact["text"].include?("Primjervrt (CSP)") }
        end
      end
    end
  end

  def test_retest2_exact_known_origin_followup_retains_primjerpolje_and_day
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: Time.utc(2026, 9, 15, 20, 59, 40))
    [{}, { "area_query" => "Primjerpolje", "time_expression" => "16.9.2026. poslije 08:00" },
     { "area_query" => "Primjerpolje", "date" => "2026-09-16", "time_expression" => "08:00" }].each do |initial_entities|
      state = dialogue::StateStore.new.empty_state(context)
      reads = []
      runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
        answer = transport_port.call(**args)
        reads << answer
        answer
      }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
      ["Koji autobus ide za Primjerpolje 16.9.2026. poslije 08:00?", "Krećem sa Bijeljina (NAS)."].each_with_index do |text, index|
        understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                                 entities: index.zero? ? initial_entities : {}, locale: "sr", needs_clarification: false, secondary: nil)
        reply = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil))
        state = reply.state
      end
      assert_includes reads.first.warnings, "transport_origin_required"
      assert_equal "ok", reads.last.status
      assert_match(/Primjerpolje|primjerpolj/, state.fetch("entities").fetch("area_query"))
      assert_equal "2026-09-16", state.fetch("entities").fetch("date")
      assert reads.last.facts.any? { |fact| fact["kind"] == "transport_leg" && fact.fetch("text").include?("Primjerpolje") }
    end
  end

  def test_retest_destination_refinement_does_not_supply_missing_origin
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: NOW)
    state = dialogue::StateStore.new.empty_state(context)
    reads = []
    runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
      answer = transport_port.call(**args)
      reads << answer
      answer
    }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
    turns = [
      ["Koji autobus ide do škole?", { "area_query" => "škole" }],
      ["Mislim na školu u Primjerpolju.", { "stop" => "škola u Primjerpolju", "area_query" => "Primjerpolje" }]
    ]
    turns.each_with_index do |(text, entities), index|
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                               entities:, locale: "sr", needs_clarification: false, secondary: nil)
      reply = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil))
      state = reply.state
    end
    assert_includes reads.first.warnings, "transport_origin_required"
    assert_includes reads.last.warnings, "transport_origin_required"
    assert_equal "primjerpolju skola", state.fetch("entities").fetch("area_query")
    assert_nil state.fetch("entities")["stop"]
    assert_equal "stop", state.fetch("pending_slot")
    understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "continue",
                                                             entities: {}, locale: "sr", needs_clarification: false, secondary: nil)
    reply = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new("Sa nove autobuske stanice.", nil))
    assert_equal "answered", reply.resolution
    assert_equal "primjerpolju skola", reply.state.fetch("entities").fetch("area_query")
    assert_equal "ok", reads.last.status
    assert reads.last.facts.any? { |fact| fact["kind"] == "transport_leg" && fact.fetch("text").include?("Bijeljina (NAS)") }
  end

  def test_retest_destination_refinement_preserves_an_independent_origin
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: NOW)
    ["Od NAS do škole?", "Od Primjerpolje (škola) do centra?"].each do |opening|
      state = dialogue::StateStore.new.empty_state(context)
      reads = []
      runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
        answer = transport_port.call(**args)
        reads << answer
        answer
      }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
      original_stop = nil
      refinement = opening.include?("Primjerpolje") ? "До школе у Примјерпољу." : "Мислим на школу у Примјерпољу."
      [opening, refinement].each_with_index do |text, index|
        entities = index.zero? ? {} : { "stop" => "škola u Primjerpolju", "area_query" => "Primjerpolje" }
        understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                                 entities:, locale: "sr", needs_clarification: false, secondary: nil)
        reply = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil))
        state = reply.state
        original_stop = state.fetch("entities").fetch("stop") if index.zero?
      end
      assert_equal original_stop, state.fetch("entities").fetch("stop"), opening
      assert_equal "primjerpolju skola", state.fetch("entities").fetch("area_query")
      assert_equal false, reads.last.warnings.include?("transport_origin_required")
      assert_includes reads.last.warnings, "transport_same_stop" if opening.include?("Primjerpolje")
    end
  end

  def test_retest_school_qualifier_is_retained_before_matching
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["Mislim na školu u Primjerpolju.", "Мислим на школу у Примјерпољу."].each do |query|
      selected = parser.call({ "query" => query, "area_query" => "škole", "stop" => "NAS" })
      assert_nil selected.warning
      assert_equal "primjerpolju skola", selected.entities.fetch("area_query")
      rows = @reader.send(:route_matrix, @notices, request: {}).flat_map { |route| route.directions.flat_map(&:stops) }
      matches = @reader.send(:matching_stops, rows, selected.entities.fetch("area_query"))
      assert_equal ["Primjerpolje (škola)"], matches.map(&:label).uniq
      cached = @reader.send(:matching_stops_from_details, rows, @reader.send(:stop_match_details, selected.entities.fetch("area_query")), term_cache: {})
      assert_equal matches, cached
      answer = read({ "query" => query, "area_query" => "škole", "stop" => "NAS" })
      assert_equal "primjerpolju skola", answer.coverage.fetch("transport_query_entities").fetch("area_query")
      assert_equal false, answer.candidates.any? { |candidate| !candidate.fetch("text").include?("Primjerpolje") }
      assert_operator @reader.send(:matching_stops, rows, "škola").map(&:label).uniq.size, :>, 1
    end
  end

  def test_retest_compound_preserves_final_destination_and_via_in_both_scripts
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    ["Nađi vezu iz Primjervrta do centra pa do škole u Primjerpolju.", "Нађи везу из Примјерврта до центра па до школе у Примјерпољу."].each do |query|
      selected = parser.call({ "query" => query })
      assert_equal "transport_via_required", selected.warning
      assert_equal "primjervrta", selected.entities.fetch("stop")
      assert_equal "centra", selected.entities.fetch("via_stop")
      assert_equal "primjerpolju skola", selected.entities.fetch("area_query")
      followup = parser.call(selected.entities.merge("query" => "Ne mijenjaj odredište u centar."))
      assert_equal "primjerpolju skola", followup.entities.fetch("area_query")
      assert_equal "centra", followup.entities.fetch("via_stop")
      assert_equal "transport_via_required", followup.warning
    end
  end

  def test_retest_transfer_question_answers_from_selected_itinerary
    direct = read({ "query" => "Da li moram presjedati?", "stop" => "Primjervrt (CSP)", "area_query" => "Bijeljina (spomenik)", "date" => "2026-09-16", "time_expression" => "10:00" })
    assert_equal "ok", direct.status
    assert direct.facts.first.fetch("text").start_with?("Ne, ovaj objavljeni polazak je direktan")
    transfer = read({ "query" => "Da li moram presjedati?", "stop" => "Primjerpark", "area_query" => "ATC", "date" => "2026-09-16", "time_expression" => "06:00" })
    assert_equal "ok", transfer.status
    assert transfer.facts.first.fetch("text").start_with?("Da, za ovu objavljenu vezu potrebno je presjedanje")
  end

  def test_retest_explicit_direct_constraint_never_returns_a_transfer
    entities = { "query" => "Direktno do ATC, bez presjedanja.", "stop" => "Primjerpark", "area_query" => "ATC", "date" => "2026-09-16", "time_expression" => "06:00" }
    first = read(entities)
    assert_equal "empty", first.status
    assert_equal 0, first.validity.fetch("maximum_transfers")
    retained = first.coverage.fetch("transport_query_entities")
    assert_equal "direct", retained.fetch("transfer_mode")
    second = read(retained.merge("query" => "Prvi nakon 6 časova."))
    assert_equal "empty", second.status
    third = read(retained.merge("query" => "Može i presjedanje."))
    assert_equal "ok", third.status
    assert_includes third.coverage.fetch("transport_query_invalidated_entities"), "transfer_mode"
    assert_equal false, third.coverage.fetch("transport_query_entities").has_key?("transfer_mode")
  end

  def test_retest_inflected_month_dates_never_fall_back_to_today
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    { 9 => %w(septembar septembra septembru септембра), 10 => %w(oktobar oktobra oktobru октобра),
      11 => %w(novembar novembra novembru новембра), 12 => %w(decembar decembra decembru децембра) }.each do |month, names|
      names.each do |name|
        selected = parser.calendar_entities({ "query" => "Polasci G1 20. #{name} 2026" }, now: NOW)
        assert_nil selected.warning
        assert_equal format("2026-%02d-20", month), selected.entities.fetch("date"), name
      end
    end
    answer = read({ "query" => "Поласци Г1 20. септембра 2026" }, locale: "sr-Cyrl")
    assert_equal "2026-09-20", answer.coverage.fetch("transport_query_entities").fetch("date")
    assert_equal "empty", answer.status
    assert_includes answer.warnings, "no_departures_published_for_service_day"
    invalid = parser.calendar_entities({ "query" => "Polasci G1 31. novembra 2026" }, now: NOW)
    assert_equal "invalid_date", invalid.warning
  end

  def test_retest_stop_navigation_category_uses_named_stop_without_gps
    answer = read({ "query" => "Samo mi ovdje napiši uputstvo i link.", "category" => "stop_navigation", "stop" => "NAS" })
    assert_equal "ok", answer.status
    assert_includes answer.facts.first.fetch("text"), "Bijeljina (NAS)"
    assert_includes answer.facts.first.fetch("destination"), "travelmode=walking"
    missing = read({ "query" => "Samo mi ovdje napiši uputstvo.", "category" => "stop_navigation" })
    assert_equal "ambiguous", missing.status
    assert_includes missing.warnings, "transport_navigation_stop_required"
    named = read({ "query" => "NAS", "category" => "stop_navigation" })
    assert_equal "ok", named.status
    assert_includes named.facts.first.fetch("destination"), "travelmode=walking"
  end

  def test_retest_weekday_transport_is_calendar_not_office_hours
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: NOW)
    state = dialogue::StateStore.new.empty_state(context)
    reads = []
    runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
      answer = transport_port.call(**args)
      reads << answer
      answer
    }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
    ["Vozi li G1 nedjeljom?", "Je li nedjeljni red vožnje objavljen ili nije?"].each_with_index do |text, index|
      entities = index.zero? ? { "route" => "G1", "time_expression" => "nedjeljom" } : {}
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                               entities:, locale: "sr", needs_clarification: false, secondary: nil)
      state = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil)).state
    end
    reads.each do |answer|
      assert_equal "empty", answer.status
      assert_includes answer.warnings, "no_departures_published_for_service_day"
      assert_equal "2026-09-20", answer.coverage.fetch("transport_query_entities").fetch("date")
      assert_equal "G1", answer.coverage.fetch("transport_query_entities").fetch("route")
    end
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    assert_equal false, parser.calendar_question?({ "query" => "Koji je telefon za G1 nedjeljom?" })
    assert_equal false, parser.calendar_question?({ "query" => "Radno vrijeme autobuske stanice nedjeljom?" })
    standalone = read({ "query" => "Је ли недјељни ред вожње објављен?" }, locale: "sr-Cyrl")
    assert_includes standalone.warnings, "no_departures_published_for_service_day"
    assert_equal "2026-09-20", standalone.coverage.fetch("transport_query_entities").fetch("date")
  end

  def test_retest_calendar_does_not_publish_empty_seasonal_departures
    reader = @reader.dup
    routes = reader.send(:route_matrix, @notices.first(1), request: {}).map do |route|
      route.dup.tap do |copy|
        copy.directions = route.directions.map do |direction|
          direction.dup.tap do |entry|
            entry.stops = direction.stops.map(&:dup)
            entry.stops.first.times = []
          end
        end
      end
    end
    reader.define_singleton_method(:route_matrix) { |*, **| routes }
    answer = reader.calendar_query(notices: @notices.first(1), requested_at: Time.zone.local(2026, 9, 16, 6))
    assert_equal "empty", answer.fetch(:status)
    assert_empty answer.fetch(:directions)
    assert_includes answer.fetch(:warnings), "no_departures_published_for_service_day"
  end

  def test_retest_explicit_via_removal_survives_three_turns
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: NOW)
    ["Ne treba preko centra, direktno do škole u Primjerpolju.", "Bez centra, samo do škole u Primjerpolju."].each do |removal|
      state = dialogue::StateStore.new.empty_state(context)
      reads = []
      runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
        answer = transport_port.call(**args)
        reads << answer
        answer
      }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
      ["Nađi vezu iz Primjervrta do centra pa do škole u Primjerpolju.", removal, "Prvi nakon 13 časova."].each_with_index do |text, index|
        understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                                 entities: {}, locale: "sr", needs_clarification: false, secondary: nil)
        reply = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil))
        state = reply.state
      end
      assert_includes reads.first.warnings, "transport_via_required"
      assert_includes reads[1].coverage.fetch("transport_query_invalidated_entities"), "via_stop"
      reads.drop(1).each do |answer|
        entities = answer.coverage.fetch("transport_query_entities")
        assert_equal "primjerpolju skola", entities.fetch("area_query")
        assert_equal "primjervrta", entities.fetch("stop")
        assert_equal false, entities.has_key?("via_stop")
        assert_equal "direct", entities.fetch("transfer_mode") if removal.include?("direktno")
        assert_equal false, answer.warnings.include?("transport_via_required")
      end
    end
  end

  def test_retest_explicit_stop_selection_produces_reviewed_walking_link_without_gps
    answer = read({ "query" => "Odaberi stanicu za polazak sa NAS." })
    assert_equal "ok", answer.status
    assert_includes answer.facts.first.fetch("text"), "Bijeljina (NAS)"
    assert_includes answer.facts.first.fetch("destination"), "travelmode=walking"
  end

  def test_retest_affirmative_endpoint_correction_does_not_reuse_negated_place
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    origin = parser.call({ "query" => "Ne iz Primjervrta nego iz Primjerpolja.", "stop" => "Primjervrt", "area_query" => "NAS" })
    assert_equal "primjerpolja", origin.entities.fetch("stop")
    assert_equal "NAS", origin.entities.fetch("area_query")
    destination = parser.call({ "query" => "Ne do centra nego do Primjerpolja.", "stop" => "NAS", "area_query" => "centar" })
    assert_equal "primjerpolja", destination.entities.fetch("area_query")
    assert_equal "NAS", destination.entities.fetch("stop")
  end

  def test_retest_time_correction_ignores_negated_old_clock
    parser = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    selected = parser.call({ "query" => "Ne u 9, treba mi prvi nakon 13 časova.", "stop" => "NAS", "area_query" => "ATC", "time_expression" => "09:00" })
    assert_nil selected.warning
    assert_equal "13:00", selected.entities.fetch("time_expression")
  end

  def test_retest_calendar_question_does_not_ask_for_boarding_origin
    answer = read({ "query" => "Koji G1 polasci važe u nedjelju 20.9.2026?" })
    assert_equal "empty", answer.status
    assert_includes answer.warnings, "no_departures_published_for_service_day"
    assert_equal "G1", answer.coverage.fetch("transport_query_entities").fetch("route")
    future = read({ "query" => "Za 1. januar 2027. imam li potvrđen polazak?" })
    assert_equal "unavailable", future.status
    assert_includes future.warnings, "unsupported_service_day"
    assert_equal "calendar", future.coverage.fetch("transport_query_scope")
    assert_equal "2027-01-01", future.coverage.fetch("transport_query_entities").fetch("date")
    saturday = read({ "query" => "G1 u subotu 19.9.2026. u smjeru ka NAS?" })
    assert_equal "ok", saturday.status
    assert saturday.facts.all? { |fact| fact.fetch("text").include?("G1") }
    assert_operator saturday.facts.size, :>=, 2, "both published directions are explicitly labelled"
    cyrillic = read({ "query" => "Г1 у суботу 19.9.2026. у смјеру ка НАС?" }, locale: "sr-Cyrl")
    assert_equal "ok", cyrillic.status
    assert cyrillic.facts.all? { |fact| fact.fetch("text").include?("објављени поласци") }
  end

  class Timetable < DecidimApp::Bijeljina::PublicTransportTimetable
    private

    def default_stop_registry_path
      ENV.fetch("MI_TRANSPORT_STOPS_PATH")
    end
  end
  Reviewed = DecidimApp::Bijeljina::ReviewedTransportTimetables
  Notice = Data.define(:source_key, :url, :title)
  Row = Data.define(:source_version, :last_success_at, :check_payload, :last_good_payload)
  NOW = Time.utc(2026, 9, 15, 6)

  class Snapshots
    def initialize = @rows = {}

    def snapshot(source_key:) = @rows[source_key]

    def version_for(*) = "checked-in-september-quality-v1"

    def promote(source_key:, source_version:, payload:, checked_at: nil, **)
      @rows[source_key] = Row.new(source_version, checked_at, { "status" => "ok" }, payload)
    end
  end

  def setup
    install_synthetic_transport
    @prior_zone = Time.zone
    @prior_backend = I18n.backend
    @prior_locales = I18n.available_locales
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    I18n.backend.load_translations(File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "config/locales/decidim_bih_dialogue.yml"),
                                   File.expand_path("../../config/locales/milica_directory_answers.yml", __dir__))
    Time.zone = "Europe/Sarajevo" # rubocop:disable Rails/TimeZoneAssignment
    @reader = Timetable.new(clock: -> { NOW }, snapshot_store: Snapshots.new, cache: false, prepared_only: true,
                            fetcher: ->(url) { File.binread(File.join(Reviewed::DATA_PATH, Reviewed.asset_for(url).fetch("file"))) })
    @notices = Reviewed.manifest.fetch("routes").map do |entry|
      Notice.new("public_transport", entry.dig("timetable", "url"), entry.fetch("title"))
    end
    @notices.each do |notice|
      entry = Reviewed.entry_for(notice.url)
      prepared = @reader.send(:prepare_reviewed_document, notice, entry, entry.dig("timetable", "sha256"), deadline: nil)
      assert_equal :ok, prepared.fetch(:status)
    end
  end

  def teardown
    restore_synthetic_transport
    Time.zone = @prior_zone # rubocop:disable Rails/TimeZoneAssignment
    I18n.backend = @prior_backend
    I18n.available_locales = @prior_locales
  end

  def test_nearby_origin_search_reuses_source_work_without_changing_candidates_or_ranking
    baseline = @reader.dup
    baseline.define_singleton_method(:build_planner_cache) { nil }
    readers = { baseline:, optimized: @reader }
    counts = readers.transform_values { |reader| count_planner_work(reader) }
    query = { origin: nil, destination: "bolnice", notices: @notices,
              requested_at: Time.zone.local(2026, 9, 15, 12), strict: true,
              location: { latitude: 0.5000, longitude: 0.5040 } }
    results = readers.transform_values do |reader|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = reader.query(**query)
      [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end
    expected = results.fetch(:baseline).first
    actual = results.fetch(:optimized).first
    assert_equal :ok, actual.status
    assert_equal expected.to_h, actual.to_h
    assert_equal "Bijeljina (spomenik)", actual.origin
    assert_equal "P6", actual.itinerary.legs.first.route_code
    assert_equal "2026-09-15T12:10:00+02:00", actual.itinerary.legs.first.departure_at.iso8601
    assert_equal "2026-09-15T12:16:00+02:00", actual.itinerary.legs.last.arrival_at.iso8601
    # The authored small network induces 11 direct searches, rather than the
    # private corpus's 49. Preserve identical candidate work and the >4x
    # normalization reduction below. This is not a production-size benchmark.
    assert_equal 11, counts.fetch(:baseline).fetch(:direct_itineraries)
    assert_equal counts.fetch(:baseline).fetch(:direct_itineraries), counts.fetch(:optimized).fetch(:direct_itineraries)
    assert_equal counts.fetch(:baseline).fetch(:transfer_itineraries), counts.fetch(:optimized).fetch(:transfer_itineraries)
    assert_operator counts.fetch(:optimized).fetch(:normalized_text), :<, counts.fetch(:baseline).fetch(:normalized_text) / 4
    assert_equal counts.fetch(:baseline).fetch(:legs_from_rows), counts.fetch(:optimized).fetch(:legs_from_rows)
    if ENV["MILICA_TRANSPORT_PROFILE"]
      puts JSON.generate(nearby_origin_search: results.transform_values(&:last), counts:,
                         result_sha256: Digest::SHA256.hexdigest(Marshal.dump(actual.to_h)))
    end

    # Reusing the same reader for a different day cannot reuse earlier legs.
    query[:requested_at] = Time.zone.local(2026, 9, 20, 12)
    assert_equal baseline.query(**query).to_h, @reader.query(**query).to_h
  end

  def test_planner_matching_cache_retains_exact_phrase_identity_and_source_order
    rows = [Timetable::StopRow.new(label: "Primjertok škola", normalized_label: "primjertok skola", index: 0),
            Timetable::StopRow.new(label: "Primjertok selo", normalized_label: "primjertok selo", index: 1)]
    cache = @reader.send(:build_planner_cache)
    phrases = ["Primjertok", Timetable::ExactStopPhrase.new("primjertok"), "centar", "Примјерток", "unmatched", nil]
    phrases.each do |phrase|
      expected = @reader.send(:matching_stops, rows, phrase)
      assert_equal expected, @reader.send(:planner_matching_stops, rows, phrase, cache)
      assert_equal expected, @reader.send(:planner_matching_stops, rows, phrase, cache)
    end
    assert_equal rows, @reader.send(:planner_matching_stops, rows, "Primjertok", cache)
    assert_empty @reader.send(:planner_matching_stops, rows, Timetable::ExactStopPhrase.new("primjertok"), cache)
  end

  def count_planner_work(reader)
    counts = Hash.new(0)
    wrapper = Module.new
    [:normalized_text, :legs_from_rows, :direct_itineraries, :transfer_itineraries].each do |name|
      wrapper.define_method(name) do |*args, **kwargs, &block|
        counts[name] += 1
        super(*args, **kwargs, &block)
      end
    end
    reader.singleton_class.prepend(wrapper)
    counts
  end

  def test_inflected_settlement_origin_does_not_mean_one_identical_boarding_stop
    result = read({ "stop" => "Primjervrta", "area_query" => "Primjervrt" })

    assert_equal "ambiguous", result.status, result.warnings.inspect
    assert_includes result.warnings, "transport_origin_ambiguous"
    assert_empty result.facts
    assert_operator result.candidates.length, :>, 1
    assert(result.candidates.any? { |candidate| candidate.fetch("text").include?("Primjervrt (CSP)") })
  end

  def test_live_vehicle_and_accessibility_questions_do_not_guess_from_timetable
    { "Možeš li uživo vidjeti kasni li taj autobus?" => "transport_live_status_unavailable",
      "А јесу ли Г1 аутобуси сигурно прилагођени колицима?" => "transport_accessibility_unverified" }.each do |query, warning|
      result = read({ "query" => query }, source_status: :unavailable)
      assert_equal "empty", result.status
      assert_equal [warning], result.warnings
      assert_empty result.facts
      assert_equal false, result.validity["live_vehicle_status"]
      assert_equal false, result.validity["accessibility_verified"]
    end
  end

  def test_new_topic_after_negated_live_status_is_not_a_capability_question
    port = DecidimApp::Bijeljina::Milica::ReadPort.allocate
    ["Ne zanima me da li autobus kasni. Gdje je biblioteka?", "Možeš li vidjeti kasni li autobus? Gdje je biblioteka?"].each do |query|
      assert_nil port.send(:transport_capability_warning, query)
    end
  end

  def test_journey_and_live_status_request_keeps_schedule_and_explains_tracking_limit
    result = read({ "query" => "Kako od NAS-a do Primjerparka 16.9.2026. poslije 08:00? Možeš li vidjeti kasni li autobus?" })
    assert_equal "ok", result.status
    assert_includes result.facts.first.fetch("text"), "Primjerpark"
    assert_includes result.facts.first.fetch("text"), "praćenje vozila uživo"
    assert_includes result.warnings, "transport_live_status_unavailable"
  end

  def test_wheelchair_context_does_not_discard_a_supported_journey
    result = read({ "query" => "Kada ide autobus od NAS-a do Primjerparka 16.9.2026. poslije 08:00? Koristim kolica." })
    assert_equal "ok", result.status
    assert_includes result.facts.first.fetch("text"), "Primjerpark"
    assert_includes result.facts.first.fetch("text"), "ivičnjacima"
    assert_includes result.warnings, "accessibility_unverified"
  end

  def test_saturday_short_nas_alias_keeps_the_requested_boarding_stop
    result = journey("NAS-a", "Primjerparka", day: 19, hour: 8)
    assert_equal :ok, result.status, result.warnings.inspect
    leg = result.itinerary.legs.first
    assert_equal "Bijeljina (NAS)", leg.origin_label
    assert_equal "2026-09-19T10:10:00+02:00", leg.departure_at.iso8601
    assert_equal "2026-09-19T10:20:00+02:00", leg.arrival_at.iso8601
    map = URI.decode_www_form(URI.parse(result.boarding_stop.fetch("destination")).query).to_h
    assert_equal "0.500000,0.500000", map.fetch("destination")
    assert_equal "walking", map.fetch("travelmode")
  end

  def test_plain_nas_and_cyrillic_nas_do_not_expand_to_city_centre
    ["NAS", "НАС", "Bijeljina (NAS)"].each do |origin|
      result = journey(origin, "Primjerpark", hour: 6)
      assert_equal :ok, result.status, [origin, result.warnings].inspect
      assert_equal "Bijeljina (NAS)", result.itinerary.legs.first.origin_label
      assert_equal "06:30", result.itinerary.legs.first.departure_at.strftime("%H:%M")
    end
  end

  def test_reviewed_two_line_connection_has_a_real_shared_stop_and_bounded_wait
    result = journey("Primjerparka", "ATC-a")
    assert_equal :ok, result.status, result.warnings.inspect
    legs = result.itinerary.legs
    assert_equal %w(G1 G2), legs.map(&:route_code)
    assert_equal legs.first.destination_label, legs.last.origin_label
    wait = legs.last.departure_at - legs.first.arrival_at
    assert_operator wait, :>=, 180
    assert_operator wait, :<=, 14_400
    assert_equal "06:40", legs.first.departure_at.strftime("%H:%M")
    assert_equal "07:45", legs.last.arrival_at.strftime("%H:%M")
  end

  def test_reverse_trip_preserves_direction_and_both_endpoints
    result = journey("Primjerpark", "NAS", hour: 7)
    assert_equal :ok, result.status
    leg = result.itinerary.legs.first
    assert_equal "Primjerpark", leg.origin_label
    assert_equal "Bijeljina (NAS)", leg.destination_label
    assert_equal "08:40", leg.departure_at.strftime("%H:%M")
    assert_equal "09:05", leg.arrival_at.strftime("%H:%M")
  end

  def test_unknown_destination_is_distinct_from_unpublished_sunday
    unknown = journey("NAS", "Nepoznatovac")
    assert_equal :empty, unknown.status
    assert_includes unknown.warnings, "destination_not_in_reviewed_timetable"
    sunday = journey("NAS", "Primjerpark", day: 20)
    assert_equal :empty, sunday.status
    assert_includes sunday.warnings, "no_departures_published_for_service_day"
  end

  def test_unsupported_holiday_takes_precedence_over_saturday
    result = @reader.query(origin: "NAS", destination: "Primjerpark", requested_at: Time.zone.local(2026, 11, 21, 6), notices: @notices)
    assert_equal :unavailable, result.status
    assert_includes result.warnings, "unsupported_service_day"
  end

  def test_reviewed_school_break_is_a_supported_date
    result = @reader.query(origin: "NAS", destination: "Primjerpark", requested_at: Time.zone.local(2027, 1, 5, 6), notices: @notices)
    assert_equal :ok, result.status, result.warnings.inspect
    assert_equal "06:30", result.itinerary.legs.first.departure_at.strftime("%H:%M")
    assert_equal "school_break", result.itinerary.legs.first.calendar.fetch("kind")
  end

  def test_nearest_public_landmark_and_retained_navigation_target
    result = @reader.nearest_stop(location: { latitude: 0.5000, longitude: 0.5040 })
    assert_equal :ok, result.status
    assert_equal "Bijeljina (spomenik)", result.origin
    assert_includes result.warnings, "assumed_stop_coordinates"
    fact = result.boarding_stop
    assert_equal "assumed", fact.dig("coverage", "coordinate_accuracy")
    map = URI.decode_www_form(URI.parse(fact.fetch("destination")).query).to_h
    assert_equal "0.500000,0.504000", map.fetch("destination")
    assert_equal "walking", map.fetch("travelmode")
    assert_equal false, map.has_key?("origin")
    retained = @reader.walking_directions(stop_id: fact.fetch("id"))
    assert_equal fact.fetch("destination"), retained.fetch("destination")
  end

  def test_requested_school_break_cannot_override_a_reviewed_saturday_or_holiday
    saturday = journey("NAS", "Primjerpark", day: 19, service_day_kind: "school_break")
    assert_equal :ambiguous, saturday.status
    assert_includes saturday.warnings, "transport_calendar_date_conflict"
    holiday = @reader.query(origin: "NAS", destination: "Primjerpark", requested_at: Time.zone.local(2026, 11, 21, 6),
                            notices: @notices, service_day_kind: "school_break")
    assert_equal :unavailable, holiday.status
    assert_includes holiday.warnings, "unsupported_service_day"
  end

  def test_explicit_reviewed_school_break_has_verified_calendar_evidence
    result = read({ "query" => "Od NAS-a do Primjerparka tokom raspusta 5.1.2027. poslije 06:00" })
    assert_equal "ok", result.status, result.warnings.inspect
    assert_equal false, result.warnings.include?("service_calendar_date_not_verified")
    assert_includes result.facts.first.fetch("text"), "2027-01-05 06:30"
  end

  def test_from_here_to_settlement_without_location_asks_for_origin_and_keeps_destination
    result = read({ "query" => "Kako autobusom odavde do Primjervrta 16.9.2026. poslije 06:00?" })
    assert_equal "ambiguous", result.status
    assert_includes result.warnings, "transport_origin_required"
    assert_equal "primjervrta", result.coverage.fetch("transport_query_entities").fetch("area_query")
    assert_empty result.facts
  end

  def test_from_here_to_settlement_with_trusted_location_finds_a_route_serving_it
    location = { latitude: 0.5000, longitude: 0.5040, accuracy: 10, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    result = read({ "query" => "Kako autobusom odavde do Primjervrta 16.9.2026. poslije 06:00?" }, location:)
    assert_equal "ok", result.status, result.warnings.inspect
    legs = result.facts.select { |fact| fact["kind"] == "transport_leg" }
    assert_match(/Primjervrt/, legs.last.fetch("coverage").fetch("destination"))
    navigation = result.facts.find { |fact| fact["kind"] == "transport_navigation" }
    assert_equal "assumed", navigation.fetch("coverage").fetch("coordinate_accuracy")
    assert_equal false, result.to_h.to_s.include?("browser_geolocation")
  end

  def test_read_port_transfer_names_wait_direction_and_each_leg_source
    result = read({ "query" => "Kako autobusom od Primjerparka do ATC-a 16.9.2026. poslije 06:00? Može i presjedanje." })
    assert_equal "ok", result.status, result.warnings.inspect
    legs = result.facts.select { |fact| fact["kind"] == "transport_leg" }
    assert_equal 2, legs.size
    assert_includes legs.last.fetch("text"), "čekanje 20 minuta"
    assert_includes legs.last.fetch("text"), "Presjedanje na Bijeljina (NAS)"
    assert_includes legs.last.fetch("text"), "smjer"
    %w(G1 G2).each_with_index do |code, index|
      entry = Reviewed.manifest.fetch("routes").find { |row| row.fetch("code") == code }
      assert_equal entry.dig("timetable", "url"), legs[index].fetch("source_url")
    end
    assert_equal "06:00", result.coverage.fetch("transport_query_entities").fetch("time_expression")
    assert_equal 1, result.validity.fetch("maximum_transfers")
    assert_equal false, result.validity.fetch("live_vehicle_status")
  end

  def test_empty_destination_result_retains_endpoints_and_invalidated_route_for_correction
    result = read({ "query" => "A do Nepoznatovca?", "stop" => "NAS", "area_query" => "Primjerpark", "route" => "G1",
                    "date" => "2026-09-16", "time_expression" => "06:00" })
    assert_equal "empty", result.status
    assert_includes result.warnings, "destination_not_in_reviewed_timetable"
    assert_equal ["route"], result.coverage.fetch("transport_query_invalidated_entities")
    assert_equal "NAS", result.coverage.fetch("transport_query_entities").fetch("stop")
    assert_equal "nepoznatovca", result.coverage.fetch("transport_query_entities").fetch("area_query")
  end

  def test_transfer_continuation_clears_retained_single_line_restriction
    result = read({ "query" => "A sa presjedanjem do ATC?", "stop" => "Primjerpark", "area_query" => "NAS", "route" => "G1",
                    "date" => "2026-09-16", "time_expression" => "06:00" })
    assert_equal "ok", result.status, result.warnings.inspect
    assert_equal ["route"], result.coverage.fetch("transport_query_invalidated_entities")
    retained = result.coverage.fetch("transport_query_entities")
    assert_equal "Primjerpark", retained.fetch("stop")
    assert_equal "atc", retained.fetch("area_query")
    assert_equal false, retained.has_key?("route")
    legs = result.facts.select { |fact| fact["kind"] == "transport_leg" }
    assert_equal 2, legs.size
    assert_match(/G1/, legs.first.fetch("text"))
    assert_match(/G2/, legs.last.fetch("text"))
  end

  def test_accessibility_query_uses_public_landmark_without_claiming_safe_access
    query = "Treba mi najbliže stajalište od spomenika u centru, koristim kolica. Može li se sigurno prići?"
    assert DecidimApp::Bijeljina::Milica::TransportJourneyQuestion.nearest_stop?("query" => query)
    result = read({ "query" => query, "area_query" => "centru koristim kolica moze" })
    assert_equal "ok", result.status, result.warnings.inspect
    assert_equal "Bijeljina (spomenik)", result.coverage.fetch("origin")
    assert_equal false, result.validity.fetch("accessibility_verified")
    assert_includes result.warnings, "accessibility_unverified"
    fact = result.facts.fetch(0)
    assert_includes fact.fetch("text"), "Nemam provjerene podatke"
    assert_includes fact.fetch("text"), "Mapa to ne potvrđuje"
    assert_includes fact.fetch("text"), "Položaj je približan"
    assert_includes fact.fetch("destination"), "https://www.google.com/maps/dir/"
  end

  def test_cyrillic_hospital_landmark_is_used_before_bogus_model_destination
    query = "Налазим се код болнице у Бијељини. Како до најближе аутобуске станице?"
    result = read({ "query" => query, "area_query" => "najblize autobuske stanice" }, locale: "sr-Cyrl")
    assert_equal "ok", result.status, result.warnings.inspect
    assert_equal "Bijeljina (bolnica)", result.coverage.fetch("origin")
    fact = result.facts.fetch(0)
    assert_includes fact.fetch("text"), "болница"
    assert_includes fact.fetch("text"), "Положај је приближан"
    assert_includes fact.fetch("destination"), "https://www.google.com/maps/dir/"
    assert_equal false, fact.fetch("text").include?("minuta")
  end

  def test_landmark_without_locality_keeps_distinct_settlements_ambiguous
    result = read({ "query" => "Najbliže stajalište kod spomenika?" })
    assert_equal "ambiguous", result.status
    assert_empty result.facts
    assert_operator result.candidates.length, :>, 1
    labels = result.candidates.map { |candidate| candidate.fetch("text") }
    assert_includes labels, "Bijeljina (spomenik)"
    assert_includes labels, "Primjerdalje (spomenik)"
  end

  def test_ambiguous_landmarks_do_not_select_the_first_place_or_stale_model_stop
    query = "Najbliže stajalište kod bolnice ili spomenika?"
    result = read({ "query" => query, "stop" => "NAS", "area_query" => "Bijeljina" })
    assert_equal "ambiguous", result.status
    assert_empty result.facts
    assert_includes result.warnings, "current_turn_location_required"
  end

  def test_source_failure_preserves_explicit_transport_fields_and_invalidated_route
    [:unavailable, :unreviewed].each do |source_status|
      result = read({ "query" => "Od Primjerparka do ATC-a 16.9.2026. poslije 06:00? Može presjedanje.", "route" => "G1" }, source_status:)
      assert_equal source_status.to_s, result.status
      assert_empty result.facts
      assert_equal ["route"], result.coverage.fetch("transport_query_invalidated_entities")
      assert_equal({ "stop" => "primjerparka", "area_query" => "atc", "date" => "2026-09-16", "time_expression" => "06:00" },
                   result.coverage.fetch("transport_query_entities"))
    end
  end

  def test_vehicle_suffix_and_late_clock_keep_dated_next_service
    ["Kako od NAS-a do Primjerparka autobusom 16.9.2026. poslije 23:30?",
     "Od NAS-a do Primjerparka autobusom 16.9.2026. poslije 23:30?",
     "Како од НАС-а до Примјерпарка аутобусом 16.9.2026. послије 23:30?"].each do |query|
      result = read({ "query" => query })
      assert_equal "ok", result.status, [query, result.warnings].inspect
      retained = result.coverage.fetch("transport_query_entities")
      assert_equal "primjerparka", retained.fetch("area_query")
      assert_equal "2026-09-16", retained.fetch("date")
      assert_equal "23:30", retained.fetch("time_expression")
      assert_equal "2026-09-17", result.coverage.fetch("service_day")
      assert_equal true, result.validity.fetch("rolled_over")
      leg = result.facts.find { |fact| fact["kind"] == "transport_leg" }
      assert_includes leg.fetch("text"), "Bijeljina (NAS) 2026-09-17 06:30"
      assert_includes leg.fetch("text"), "Primjerpark 2026-09-17 06:40"
      assert_includes leg.fetch("text"), "Za traženi dan (srijeda 16.9.2026) nema više polazaka"
      assert_equal false, leg.fetch("text").include?("danas već prošlo")
    end
  end

  def test_calendar_refusal_preserves_validated_query_for_school_break_correction
    holiday = read({ "query" => "Kako od NAS-a do Primjerparka autobusom na praznik 21.11.2026. poslije 06:00?" })
    assert_equal "unavailable", holiday.status
    assert_includes holiday.warnings, "unsupported_service_day"
    assert_empty holiday.facts
    retained = holiday.coverage.fetch("transport_query_entities")
    assert_equal "nas", retained.fetch("stop")
    assert_equal "primjerparka", retained.fetch("area_query")
    assert_equal "2026-11-21", retained.fetch("date")

    ["A za vrijeme školskog raspusta, 5.1.2027. poslije 06:00?",
     "А за вријеме школског распуста, 5.1.2027. послије 06:00?"].each do |query|
      corrected = read(retained.merge("query" => query))
      assert_equal "ok", corrected.status, corrected.warnings.inspect
      assert_equal "2027-01-05", corrected.coverage.fetch("transport_query_entities").fetch("date")
      assert_equal "primjerparka", corrected.coverage.fetch("transport_query_entities").fetch("area_query")
      leg = corrected.facts.find { |fact| fact["kind"] == "transport_leg" }
      assert_equal "school_break", leg.fetch("calendar").fetch("kind")
      assert_includes leg.fetch("text"), "Bijeljina (NAS) 2027-01-05 06:30"
      assert_includes leg.fetch("text"), "Primjerpark 2027-01-05 06:40"
      assert_equal false, leg.fetch("text").include?("već prošlo")
    end
  end

  def test_read_port_retains_future_saturday_and_route_specific_walking_identity
    result = read({ "query" => "Koji G1 ide od NAS-a do Primjerparka u subotu 19.9.2026. poslije 08:00?", "route" => "G1" })
    assert_equal "ok", result.status
    retained = result.coverage.fetch("transport_query_entities")
    assert_equal "2026-09-19", retained.fetch("date")
    assert_equal "08:00", retained.fetch("time_expression")
    assert_equal "2026-09-19", result.coverage.fetch("service_day")
    assert_equal "stop", result.coverage.fetch("destination_scope")
    assert_equal(false, result.facts.any? { |fact| fact.fetch("text").include?("danas već prošlo") })
    navigation = result.facts.find { |fact| fact["kind"] == "transport_navigation" }
    follow_up = @reader.walking_directions(stop_id: navigation.fetch("id"))
    map = URI.decode_www_form(URI.parse(follow_up.fetch("destination")).query).to_h
    assert_equal "0.500000,0.500000", map.fetch("destination")
  end

  def test_origin_locality_with_multiple_boarding_stops_requires_a_choice
    result = journey("Primjervrt", "Bijeljina (spomenik)")
    assert_equal :ambiguous, result.status
    assert_includes result.warnings, "transport_origin_ambiguous"
    assert_operator result.candidates.size, :>, 1
    assert(result.candidates.all? { |candidate| candidate.dig("coverage", "endpoint") == "origin" })
  end

  def test_destination_locality_is_an_option_with_an_explicit_alighting_stop
    result = journey("Bijeljina (spomenik)", "Primjervrt")
    assert_equal :ok, result.status, result.warnings.inspect
    assert_match(/Primjervrt/, result.itinerary.legs.last.destination_label)
    assert_equal "area", result.destination_scope
  end

  def test_named_stop_remains_available_without_gps
    result = @reader.nearest_stop(location: nil, place: "NAS-a")
    assert_equal :ok, result.status
    assert_equal "Bijeljina (NAS)", result.origin
    assert_includes result.boarding_stop.fetch("text"), "početak u mapi"
  end

  def test_equal_endpoints_are_not_a_missing_origin
    result = journey("NAS-a", "Bijeljina (NAS)")
    assert_equal :ambiguous, result.status
    assert_equal ["transport_same_stop"], result.warnings
  end

  def test_nearest_rejects_missing_invalid_and_outside_coverage_coordinates
    [nil, { latitude: 91, longitude: 19 }, { latitude: Float::NAN, longitude: 19 }].each do |location|
      result = @reader.nearest_stop(location:)
      assert_equal :ambiguous, result.status
      assert_includes result.warnings, "current_turn_location_required"
    end
    result = @reader.nearest_stop(location: { latitude: 0, longitude: 0 })
    assert_equal :empty, result.status
    assert_includes result.warnings, "reviewed_origin_stop_required"
  end

  def test_clock_only_return_journey_keeps_reader_resolved_future_day
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: NOW)
    state = dialogue::StateStore.new.empty_state(context)
    inputs = []
    source_results = []
    runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
      inputs << args.fetch(:entities)
      source_results << read(args.fetch(:entities))
      source_results.last
    }, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
    [
      ["Od NAS-a do Primjerparka 16.9.2026. poslije 06:00", "start", {}],
      ["A povratak od Primjerparka do NAS-a istog dana poslije 07:00?", "continue",
       { stop: "Primjerpark", area_query: "NAS", time_expression: "07:00" }]
    ].each do |text, operation, entities|
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation:, entities:, locale: "sr",
                                                              needs_clarification: false, secondary: nil)
      message = Struct.new(:text, :dialogue_location).new(text, nil)
      result = runner.call(understanding:, state:, context:, message:)
      assert_equal "answered", result.resolution
      state = result.state
    end
    assert_equal "2026-09-16", inputs.last.fetch("date")
    assert_equal "2026-09-16", source_results.last.coverage.fetch("transport_query_entities").fetch("date")
    assert_empty source_results.last.warnings.grep(/past/)
    text = source_results.last.facts.map { |fact| fact.fetch("text") }.join("\n")
    assert_includes text, "08:40"
    assert_includes text, "09:05"
    assert_includes text, "2026-09-16"
  end

  # These contracts use pure Minitest, whose negative assertions are refute methods.
  # rubocop:disable Rails/RefuteMethods
  def test_actual_nearest_and_boarding_facts_retain_walking_identity_without_retaining_coordinates
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64, capabilities: ["public_reads"], now: NOW)
    location = { latitude: 0.5000, longitude: 0.5040, accuracy: nil, consent: true, purpose: "current_location", provenance: "browser_geolocation" }
    [
      ["Koje je najbliže autobusko stajalište ovoj lokaciji?", location, "0.500000", "Bijeljina (spomenik)", "https://community.example.invalid/synthetic/transport/G1-map.png"],
      ["Od NAS-a do Primjerparka 16.9.2026. poslije 06:00", nil, "0.500000", "Bijeljina (NAS)", "https://community.example.invalid/synthetic/transport/G1-map.png"]
    ].each do |text, current_location, map_latitude, stop_name, source_url|
      port = transport_port
      runner = dialogue::ProcedureRunner.new(read_port: port, registration_port: ->(**) { flunk "No registration effect" }, destinations: { support: "/pages/pomoc" })
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "start", entities: {}, locale: "sr",
                                                               needs_clarification: false, secondary: nil)
      message = Struct.new(:text, :dialogue_location).new(text, current_location)
      first = runner.call(understanding:, state: dialogue::StateStore.new.empty_state(context), context:, message:)
      assert_equal "answered", first.resolution
      assert_equal 1, first.reply.text.scan("destination=#{map_latitude}").length
      assert_includes first.reply.text, source_url
      evidence = first.state.fetch("prior_evidence")
      refute_nil evidence, "actual navigation source metadata must be retainable"
      assert(evidence.fetch("facts").any? { |fact| fact["source_id"] == "public_transport_stop_registry" })
      refute_includes JSON.generate(evidence), map_latitude
      followup = "Kako da do tog stajališta dođem pješice?"
      assert dialogue::Coordinator::WALKING_STOP_REQUEST.match?(Decidim::Bih::Text.fold(followup))
      second = runner.transport_walking_follow_up(state: first.state, context:, message: Struct.new(:text).new(followup))
      assert_equal "answered", second.resolution
      assert_includes second.reply.text, stop_name
      assert_includes second.reply.text, "destination=#{map_latitude}"
      assert_includes second.reply.text, "travelmode=walking"
      assert_equal 1, second.reply.text.scan("destination=#{map_latitude}").length
      assert_includes second.reply.text, source_url
      cyrillic = runner.transport_walking_follow_up(state: first.state, context:, message: Struct.new(:text).new("Како да до тог стајалишта дођем пјешице?"))
      padded = Struct.new(:text, :quick_replies).new("#{cyrillic.reply.text}\n#{"Додатни опис. " * 200}", [])
      rendered = DecidimApp::Bijeljina::ChatTextRendering.render(channel: "whatsapp", reply: padded, host: "mi.example.test")
      assert_operator rendered.bytesize, :<=, 4096
      assert_equal 1, rendered.scan("destination=#{map_latitude}").length
      assert_includes rendered, source_url
      refute_includes second.reply.text, "G1 (smjer"
      assert_equal evidence, second.state.fetch("prior_evidence")
    end
  end

  # rubocop:enable Rails/RefuteMethods

  def test_navigation_source_url_does_not_relax_retained_evidence_label_rules
    dialogue = Decidim::Bih::Concierge::Dialogue
    result = read({ "query" => "Nalazim se kod bolnice u Bijeljini. Kako do najbliže autobuske stanice?" })
    assert_equal "ok", result.status
    assert_match(%r{\Ahttps://community.example.invalid/synthetic/transport/}, result.facts.first.fetch("source_url"))
    ["https://example.test/source", "password", "Izvor\nobavještenja"].each do |unsafe|
      facts = result.facts.map { |fact| fact.merge("source_label" => unsafe) }
      assert_nil dialogue::PriorEvidence.capture(result:, facts:, action: "ask_information", topic: "transport", now: NOW, expires_at: NOW.to_f + 600)
    end
  end

  private

  def read(entities, location: nil, source_status: :ok, locale: "sr")
    context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                                               capabilities: ["public_reads"], now: NOW)
    transport_port(source_status:).call(action: "ask_information", topic: "transport", entities:, context:, location:, locale:)
  end

  def transport_port(source_status: :ok)
    unused = Object.new
    directory = Object.new
    directory.define_singleton_method(:find) { |_| nil }
    checker = Object.new
    check = DecidimApp::Bijeljina::CityServiceSourceCheckStore::Result.new(source_key: "public_transport", status: source_status, notices: @notices, checked_at: NOW)
    checker.define_singleton_method(:check) { |**| [check] }
    port = DecidimApp::Bijeljina::Milica::ReadPort.new(organization: Data.define(:id).new(71), timetable: @reader, source_checker: checker,
                                                       event_feed: unused, area_matcher: unused, directory:, duplicate_finder: unused, waste_schedule: unused)
    port.define_singleton_method(:log_failure) { |error, _action| raise error }
    port
  end

  def journey(origin, destination, day: 16, hour: 6, **)
    @reader.query(origin:, destination:, requested_at: Time.zone.local(2026, 9, day, hour), notices: @notices, **)
  end
end

class MilicaTransportQuestionQualityTest < Minitest::Test
  Question = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
  NOW = Time.utc(2026, 9, 15, 8)

  def test_explicit_endpoint_spans_survive_dates_and_transfer_preference
    result = Question.call({ "query" => "Kako autobusom od Primjerparka do ATC-a 16.9.2026. poslije 06:00? Može i presjedanje." })
    assert_nil result.warning
    assert_equal "primjerparka", result.entities.fetch("stop")
    assert_equal "atc", result.entities.fetch("area_query")
    assert_equal "2026-09-16", result.entities.fetch("date")
    window = Question.requested_window(result.entities, now: NOW)
    assert_nil window.warning
    assert_equal "2026-09-16T06:00:00+02:00", window.earliest_after.iso8601
    assert_equal false, window.historical
    assert_nil window.past_clock
  end

  def test_future_retained_date_does_not_become_a_past_clock_today
    window = Question.requested_window({ "query" => "A sa NAS-a?", "date" => "2026-09-19", "time_expression" => "poslije 08:00" }, now: NOW)
    assert_nil window.warning
    assert_equal "2026-09-19T08:00:00+02:00", window.earliest_after.iso8601
    assert_equal false, window.historical
    assert_equal false, window.rolled_clock
    assert_nil window.past_clock
  end

  def test_current_citizen_date_and_time_replace_stale_slots
    window = Question.requested_window({ "query" => "A u nedjelju 20.9.2026. poslije 09:00?", "date" => "2026-09-19", "time_expression" => "08:00" }, now: NOW)
    assert_equal "2026-09-20T09:00:00+02:00", window.earliest_after.iso8601
  end

  def test_long_valid_web_question_uses_explicit_endpoints
    message = "Molim vas, možete li mi pomoći oko prevoza autobusom za putovanje koje planiram naredne sedmice jer treba da stignem " \
              "na dogovoreni sastanak: od NAS-a do Primjerparka 16.9.2026. poslije 06:00?"
    assert_operator message.length, :>, 160
    result = Question.call({ "query" => message })
    assert_nil result.warning
    assert_match(/\Anas(?:-a)?\z/i, result.entities.fetch("stop"))
    assert_equal "primjerparka", result.entities.fetch("area_query").downcase
  end

  def test_excess_length_and_invalid_date_have_distinct_warnings
    assert_equal "transport_query_too_long", Question.call({ "query" => "a" * 1001 }).warning
    assert_equal "invalid_date", Question.call({ "query" => "Od NAS-a do Primjerparka 31.9.2026. u 06:00" }).warning
  end

  def test_cyrillic_endpoints_and_iso_date
    result = Question.call({ "query" => "Од НАС-а до Примјерпарка 2026-09-19 у 08:00" })
    assert_nil result.warning
    assert_match(/\Anas(?:-a)?\z/i, result.entities.fetch("stop"))
    assert_equal "primjerparka", result.entities.fetch("area_query").downcase
    assert_equal "2026-09-19", result.entities.fetch("date")
  end

  def test_relative_citizen_day_and_clock_are_retained_explicitly
    result = Question.call({ "query" => "Od NAS-a do Primjerparka u subotu poslije 08:00" }, now: NOW)
    assert_nil result.warning
    assert_equal "2026-09-19", result.entities.fetch("date")
    assert_equal "08:00", result.entities.fetch("time_expression")
    follow_up = Question.requested_window(result.entities.merge("query" => "Gdje presjedam?"), now: NOW)
    assert_equal "2026-09-19T08:00:00+02:00", follow_up.earliest_after.iso8601
  end

  def test_relative_day_in_current_question_replaces_retained_date
    window = Question.requested_window({ "query" => "A u nedjelju u isto vrijeme?", "date" => "2026-09-19", "time_expression" => "08:00" }, now: NOW)
    assert_equal "2026-09-20T08:00:00+02:00", window.earliest_after.iso8601
  end

  def test_next_request_replaces_retained_last_mode
    window = Question.requested_window({ "query" => "A prvi sljedeći?", "date" => "2026-09-19", "time_expression" => "zadnji 08:00" }, now: NOW)
    assert_equal :next, window.mode
  end

  def test_nearest_stop_for_a_destination_uses_the_journey_path
    assert Question.nearest_stop?("query" => "Najbliže stajalište ovoj lokaciji?")
    assert_equal false, Question.nearest_stop?("query" => "Najbliže stajalište za ATC?")
  end

  def test_current_explicit_line_remains_a_real_restriction
    result = Question.call({ "query" => "A G2 od NAS-a do ATC?", "route" => "G1" })
    assert_nil result.warning
    assert_equal "G2", result.entities.fetch("route")
  end

  def test_date_is_not_misread_as_a_clock
    window = Question.requested_window({ "query" => "Od NAS-a do Primjerparka u subotu 19.9.2026.", "time_expression" => "19.9.2026." }, now: NOW)
    assert_nil window.warning
    assert_equal "2026-09-19T00:00:00+02:00", window.earliest_after.iso8601
  end
end
