# frozen_string_literal: true

# Standalone Minitest has refute helpers, without ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "i18n"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/exclude"
require "active_support/core_ext/array/access"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/procedure_runner")
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/city_service_source_check_store"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_calendar"
require_relative "../../app/services/decidim_app/bijeljina/reviewed_transport_timetables"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_timetable"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_metrics"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"
require_relative "../support/synthetic_transport_network"

# Actual timetable parsing, stop selection, public adapter and fact rendering.
# Authored tables/stops/coordinates and explicit source/calendar/place registry; no external calls.
class MilicaTransportWalkingTest < Minitest::Test
  include SyntheticTransportNetwork
  Dialogue = Decidim::Bih::Concierge::Dialogue
  Timetable = DecidimApp::Bijeljina::PublicTransportTimetable
  ENGINE_ROOT = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
  NOW = Time.utc(2026, 9, 9, 8)
  SOURCE = "https://community.example.invalid/synthetic-P8.pdf"
  STOP_SOURCE = "Synthetic reviewed stop registry"
  LOCATION = { latitude: 0.500001, longitude: 0.500002, accuracy: 12, consent: true,
               purpose: "current_location", provenance: "browser_geolocation" }.freeze
  TEXT = <<~TEXT
    P8 Bijeljina-Primjervrt
    Bijeljina (NAS)     7,23 11:30 13:10
    Bijeljina (sud)     7,27 11:32 13:12
    Primjervrt (CSP)       7,59 11:43 13:23
  TEXT
  Notice = Data.define(:source_key, :url, :title)
  Check = DecidimApp::Bijeljina::CityServiceSourceCheckStore::Result
  class CountingTimetable < Timetable
    attr_reader :counts

    def initialize(**)
      @counts = Hash.new(0)
      super
    end

    private

    def best_itinerary(...)
      @counts[:searches] += 1
      super
    end

    def transfer_points_for_destination(...)
      @counts[:transfer_points] += 1
      super
    end

    def second_transfer_leg_index(...)
      @counts[:second_leg_index] += 1
      super
    end
  end

  # Same real search/ranking algorithm, with only the two new reuse paths off.
  class UncachedTimetable < CountingTimetable
    private

    def request_with_matched_origin(...)
      super.except(:selected_itinerary)
    end

    def transfer_itineraries(routes, request)
      super(routes, request.except(:transfer_invariants))
    end
  end

  def setup
    @prior_backend = I18n.backend
    @prior_locales = I18n.available_locales
    @prior_zone = Time.zone
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    I18n.backend.load_translations(File.join(ENGINE_ROOT, "config/locales/decidim_bih_dialogue.yml"),
                                   File.expand_path("../../config/locales/milica_directory_answers.yml", __dir__))
    Time.zone = "Europe/Sarajevo" # rubocop:disable Rails/TimeZoneAssignment -- paired setup/teardown restores the test zone
    @organization = Data.define(:id).new(71)
    @context = Dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                       capabilities: ["public_reads"], now: NOW)
    @notice = Notice.new("public_transport", SOURCE, "P8 Bijeljina-Primjervrt")
    @fetches = []
    install_synthetic_transport
    # This scenario supplies no reviewed city-centre boarding default.
    # Keep the broad qualifier out of the explicit place-alias registry.
    places_path = DecidimApp::Bijeljina::PublicTransportPlaces::DATA_PATH
    places = YAML.safe_load_file(places_path)
    places.fetch("places").each { |place| place.fetch("aliases").delete("centar") }
    File.write(places_path, YAML.dump(places))
  end

  def teardown
    restore_synthetic_transport
    Time.zone = @prior_zone # rubocop:disable Rails/TimeZoneAssignment -- paired setup/teardown restores the test zone
    I18n.backend = @prior_backend
    I18n.available_locales = @prior_locales
  end

  def test_nearest_stop_reads_validated_gps_without_requiring_a_destination
    result = read(entities: { "query" => "Koje je najbliže autobusko stajalište ovoj lokaciji?" })
    assert_equal "ok", result.status, result.warnings.inspect
    fact = result.facts.first
    assert_equal "transport_navigation", fact.fetch("kind")
    assert_includes fact.fetch("text"), "stajali"
    assert_walking_url(fact.fetch("destination"), destination: "0.500535,0.501077")
    refute result.coverage.has_key?("transport_query_entities")
  end

  def test_nearest_stop_does_not_accept_unconsented_gps
    assert_raises(Dialogue::Contracts::Invalid) do
      read(entities: { "query" => "Najbliže autobusko stajalište?" }, location: LOCATION.merge(consent: false))
    end
  end

  def test_parsed_journey_entities_survive_missing_origin
    result = read(entities: { "query" => "Do Primjervrta 16.9.2026. poslije 06:00" }, location: nil)
    assert_equal "ambiguous", result.status
    assert_includes result.warnings, "transport_origin_required"
    assert_equal "primjervrta", result.coverage.fetch("transport_query_entities").fetch("area_query")
    assert_equal "2026-09-16", result.coverage.fetch("transport_query_entities").fetch("date")
  end

  def test_relative_clock_uses_trusted_service_day_and_preserves_minutes
    port = DecidimApp::Bijeljina::Milica::ReadPort.allocate
    { "sutra oko 11" => "2026-09-10T11:00:00+02:00", "сутра око 11:30" => "2026-09-10T11:30:00+02:00",
      "tomorrow around 11:30" => "2026-09-10T11:30:00+02:00", "danas u 11" => "2026-09-09T11:00:00+02:00" }.each do |expression, expected|
      time, warning = port.send(:requested_time, { "time_expression" => expression, "date" => "2020-01-01" }, NOW)
      assert_nil warning
      assert_equal expected, time.iso8601
    end
    time, warning = port.send(:requested_time, { "time_expression" => "around 11:30", "date" => "2026-09-11" }, NOW)
    assert_nil warning
    assert_equal "2026-09-11T11:30:00+02:00", time.iso8601
    time, warning = port.send(:requested_time, { "time_expression" => "sutra oko 11" }, Time.utc(2026, 9, 9, 23))
    assert_nil warning
    assert_equal "2026-09-11T11:00:00+02:00", time.iso8601
  end

  def test_unsupported_clocks_and_dst_ambiguity_do_not_silently_use_date_or_roll_time
    port = DecidimApp::Bijeljina::Milica::ReadPort.allocate
    ["sutra oko 24", "sutra oko 11:60", "sutra oko 11:7", "sutra oko -1", "sutra oko 11 UTC"].each do |expression|
      time, warning = port.send(:requested_time, { "time_expression" => expression, "date" => "2026-09-10" }, NOW)
      assert_nil time
      assert_includes %w(invalid_date unsupported_time_expression), warning
    end
    %w(2026-03-29 2026-10-25).each do |date|
      assert_equal [nil, "invalid_date"], port.send(:requested_time, { "time_expression" => "02:30", "date" => date }, NOW)
    end
  end

  def test_named_noon_reaches_the_actual_timetable_on_the_requested_service_day
    port = DecidimApp::Bijeljina::Milica::ReadPort.allocate
    ["sutra u podne", "сутра у подне", "tomorrow at noon"].each do |expression|
      time, warning = port.send(:requested_time, { "time_expression" => expression, "date" => "2020-01-01" }, NOW)
      assert_nil warning
      assert_equal "2026-09-10T12:00:00+02:00", time.iso8601
      result = read(entities: { "time_expression" => expression })
      assert_equal "ok", result.status
      assert_equal "2026-09-10", result.coverage.fetch("service_day")
      assert_includes result.facts.first.fetch("text"), "13:12"
      refute_includes result.facts.first.fetch("text"), "11:32"
    end
    time, warning = port.send(:requested_time, { "time_expression" => "u podne", "date" => "2026-09-11" }, NOW)
    assert_nil warning
    assert_equal "2026-09-11T12:00:00+02:00", time.iso8601
    ["sutra prije podne", "sutra poslije podne", "tomorrow before noon"].each do |expression|
      assert_equal [nil, "unsupported_time_expression"], port.send(:requested_time, { "time_expression" => expression }, NOW)
    end
  end

  def test_relative_service_day_reaches_actual_timetable_without_weakening_calendar_gate
    result = read(entities: { "time_expression" => "sutra oko 11" })
    assert_equal "ok", result.status
    assert_equal "2026-09-10", result.coverage.fetch("service_day")
    assert_includes result.facts.first.fetch("text"), "2026-09-10 11:32"
    assert_includes result.warnings, "timetable_not_live_vehicle_status"
    rejected = read(entities: { "time_expression" => "sutra oko 11", "query" => "tokom raspusta" })
    assert_equal "ambiguous", rejected.status
    assert_equal ["transport_calendar_date_required"], rejected.warnings
  end

  def test_transfer_search_reuses_only_request_local_invariants_without_changing_selected_trip
    notices = [Notice.new("public_transport", "https://community.example.invalid/synthetic-P2.pdf", "P2 Bijeljina-Presjedanje"),
               Notice.new("public_transport", SOURCE, "P8 Presjedanje-Primjervrt")]
    texts = { notices.first.url => "Bijeljina (bliže)    7,23 11:00\nBijeljina (dalje)    7,23 11:05\nPresjedanje    7,23 11:20\n",
              SOURCE => "Presjedanje    7,23 11:30\nPrimjervrt (CSP)    7,23 11:45\n" }
    registry = [stop(label: "Bijeljina (bliže)"), stop(label: "Bijeljina (dalje)", latitude: 0.5045)]
    options = { fetcher: ->(url) { texts.fetch(url) }, text_extractor: ->(body) { body }, clock: -> { NOW.in_time_zone },
                cache: false, stop_registry: registry, snapshot_store: Object.new }
    optimized = CountingTimetable.new(**options)
    baseline = UncachedTimetable.new(**options)
    query = { origin: nil, destination: "Primjervrt", notices:, requested_at: NOW, location: LOCATION }
    expected = baseline.query(**query)
    actual = optimized.query(**query)
    assert_equal :ok, expected.status
    assert_equal expected.to_h, actual.to_h
    assert_equal 2, actual.itinerary.legs.length
    assert_equal({ searches: 3, transfer_points: 3, second_leg_index: 3 }, baseline.counts)
    assert_equal({ searches: 2, transfer_points: 1, second_leg_index: 1 }, optimized.counts)
    assert_equal :ok, optimized.query(**query).status
    assert_equal({ searches: 4, transfer_points: 2, second_leg_index: 2 }, optimized.counts)
  end

  def test_current_location_route_renders_destination_only_walking_link_and_keeps_timetable_evidence
    result = read
    assert_equal "ok", result.status
    leg, walking = result.facts
    assert_equal "P8 (smjer prema Primjervrt (CSP)): Bijeljina (sud) 2026-09-09 11:32 → Primjervrt (CSP) 2026-09-09 11:43", leg.fetch("text")
    assert_equal SOURCE, leg.fetch("source_url")
    assert_equal "2026-09-09", result.coverage.fetch("service_day")
    assert_equal false, result.validity.fetch("live_vehicle_status")
    assert_equal "transport_navigation", walking.fetch("kind")
    assert_equal "public_transport_stop_registry", walking.fetch("source_id")
    assert_equal "Registar stajališta javnog prevoza", walking.fetch("source_label")
    assert_equal STOP_SOURCE, walking.fetch("source_url")
    assert_equal "provided", walking.fetch("coverage").fetch("coordinate_accuracy")
    assert_includes result.warnings, "walking_distance_is_approximate"
    assert_includes result.warnings, "timetable_not_live_vehicle_status"
    assert_walking_url(walking.fetch("destination"), destination: "0.500535,0.501077")

    answer = render(result, locale: "sr")
    assert_includes answer, walking.fetch("destination")
    assert_includes answer, SOURCE
    assert_includes answer, "Pješke do polaznog stajališta Bijeljina (sud)"
    refute_includes answer, LOCATION.fetch(:latitude).to_s
    refute_includes answer, LOCATION.fetch(:longitude).to_s
  end

  def test_stop_accuracy_remains_explicit_and_cyrillic_does_not_transliterate_the_url
    %w(verified provided assumed).each do |accuracy|
      result = read(registry: [stop(accuracy:)], locale: "en")
      walking = result.facts.find { |fact| fact["kind"] == "transport_navigation" }
      assert_equal accuracy, walking.fetch("coverage").fetch("coordinate_accuracy")
      expected = I18n.t("decidim_app.milica.directory_answers.transport_walk_#{accuracy}", stop: "Bijeljina (sud)", locale: "en")
      assert_equal "#{expected}\n#{walking.fetch("destination")}", walking.fetch("text")
      assert_equal 1, render(result, locale: "en").scan(walking.fetch("destination")).size
      assert_includes walking.fetch("warning_codes"), "assumed_stop_coordinates" if accuracy == "assumed"
    end

    result = read(locale: "sr-Cyrl")
    walking = result.facts.find { |fact| fact["kind"] == "transport_navigation" }
    assert_includes walking.fetch("text"), "Пјешке до полазног стајалишта Бијељина (суд)"
    assert_includes render(result, locale: "sr-Cyrl"), walking.fetch("destination")
    assert_walking_url(walking.fetch("destination"), destination: "0.500535,0.501077")
  end

  def test_navigation_follows_the_route_selected_boarding_stop_not_first_nearest_candidate
    text = <<~TEXT
      P8 Bijeljina-Primjervrt
      Bijeljina (bliže)       7,23 12:00 14:00
      Bijeljina (brža veza)   7,23 10:00 11:00
      Primjervrt (CSP)           7,59 13:00 12:00
    TEXT
    registry = [stop(label: "Bijeljina (bliže)", latitude: LOCATION.fetch(:latitude), longitude: LOCATION.fetch(:longitude)),
                stop(label: "Bijeljina (brža veza)", latitude: 0.5045, longitude: 0.5055)]
    result = read(registry:, text:)

    assert_equal "ok", result.status
    assert_equal "Bijeljina (brža veza)", result.coverage.fetch("origin")
    walking = result.facts.find { |fact| fact["kind"] == "transport_navigation" }
    assert_includes walking.fetch("text"), "Bijeljina (brža veza)"
    assert_walking_url(walking.fetch("destination"), destination: "0.504500,0.505500")
  end

  def test_missing_or_invalid_stop_coordinates_or_provenance_never_produce_navigation
    [[], [stop(latitude: 91)], [stop(longitude: Float::INFINITY)]].each do |registry|
      result = read(registry:)
      assert_empty result.facts
      refute_includes result.to_h.to_s, "google.com/maps"
    end

    result = read(registry: [stop(source: nil)])
    assert_equal "ok", result.status
    assert_equal(["transport_leg"], result.facts.map { |fact| fact.fetch("kind") })
  end

  def test_named_stop_and_missing_or_unconsented_location_keep_existing_authority
    named = read(origin: "Bijeljina (sud)")
    assert_equal "ok", named.status
    assert_equal(%w(transport_leg transport_navigation), named.facts.map { |fact| fact.fetch("kind") })
    assert_walking_url(named.facts.last.fetch("destination"), destination: "0.500535,0.501077")

    missing = read(location: nil)
    assert_equal "ambiguous", missing.status
    assert_empty missing.facts
    assert_equal ["transport_origin_required"], missing.warnings
    @fetches.clear
    assert_raises(Dialogue::Contracts::Invalid) { read(location: LOCATION.merge(consent: false)) }
    assert_empty @fetches
  end

  def test_legacy_walking_chip_remains_unchanged
    answer = timetable.answer(text: "kako odavde do primjervrta javnim prevozom", notices: [@notice], location: LOCATION)
    chip = answer.quick_replies.fetch(0)
    assert_equal "Pješke do stajališta", chip.fetch(:label)
    parameters = URI.decode_www_form(URI.parse(chip.fetch(:url)).query).to_h
    assert_equal "0.500001,0.500002", parameters.fetch("origin")
    assert_equal "0.500535,0.501077", parameters.fetch("destination")
    assert_equal "walking", parameters.fetch("travelmode")
  rescue StandardError => e
    raise(e.cause || e)
  end

  def test_followup_rereads_retained_public_stop_without_location_pdf_fetch_or_losing_trip_evidence
    first = read
    evidence = Dialogue::PriorEvidence.capture(result: first, facts: first.facts, action: "ask_information", topic: "transport",
                                               now: NOW, expires_at: NOW.to_f + 600)
    state = Dialogue::StateStore.new.empty_state(@context).merge("active_task" => "ask_information", "topic" => "transport", "prior_evidence" => evidence)
    runner = Dialogue::ProcedureRunner.new(read_port: @last_port, registration_port: ->(**) { raise "Unexpected account read" }, destinations: {})
    @fetches.clear
    followup = runner.transport_walking_follow_up(state:, context: @context, message: "Kako da pješke stignem do te autobuske stanice?")

    assert_equal "answered", followup.resolution
    walking = first.facts.find { |fact| fact["kind"] == "transport_navigation" }
    assert_includes followup.reply.text, walking.fetch("destination")
    assert_equal evidence, followup.state.fetch("prior_evidence")
    assert_empty @fetches
    refute_includes followup.state.to_s, "google.com/maps"
    refute_includes followup.state.to_s, LOCATION.fetch(:latitude).to_s
  end

  def test_broad_origin_requires_selection_of_an_actual_boarding_stop
    refute DecidimApp::Bijeljina::PublicTransportPlaces.entries.any? { |place| place.fetch("aliases").include?("centar") }
    result = read(origin: nil, location: nil, entities: { "area_query" => nil, "query" => "Kako da stignem od centra do Primjervrta sutra u podne?" })
    assert_equal "ambiguous", result.status
    assert_includes result.warnings, "transport_origin_ambiguous"
    assert_equal(["Bijeljina (NAS)", "Bijeljina (sud)"], result.candidates.map { |candidate| candidate.fetch("text") })
    assert_empty result.facts
  end

  def test_complete_citizen_journey_selects_dvorovi_not_a_second_city_stop_and_keeps_text_origin_navigation
    query = "Kako da stignem od Bijeljina (NAS) do Primjervrta sutra u podne?"
    text = "P8 Bijeljina-Primjervrt\nBijeljina (NAS)   7,23 12:05\nBijeljina (sud)   7,27 12:07\nBijeljina (testni most)   7,31 12:09\nPrimjervrt (CSP)   7,59 12:23\n"
    result = read(text:, registry: [stop(label: "Bijeljina (NAS)")], origin: nil, location: nil,
                  entities: { "area_query" => nil, "query" => query, "time_expression" => nil })
    assert_equal "ok", result.status
    assert_equal "primjervrta", result.coverage.fetch("destination")
    assert_equal "2026-09-10", result.coverage.fetch("service_day")
    leg, walking = result.facts
    assert_includes leg.fetch("text"), "→ Primjervrt (CSP) 2026-09-10 12:23"
    refute_includes leg.fetch("text"), "→ Bijeljina (testni most)"
    assert_equal SOURCE, leg.fetch("source_url")
    assert_equal "transport_navigation", walking.fetch("kind")
    assert_includes walking.fetch("text"), "Bijeljina (NAS)"
    assert_walking_url(walking.fetch("destination"), destination: "0.500535,0.501077")

    evidence = Dialogue::PriorEvidence.capture(result:, facts: result.facts, action: "ask_information", topic: "transport",
                                               now: NOW, expires_at: NOW.to_f + 600)
    state = Dialogue::StateStore.new.empty_state(@context).merge("active_task" => "ask_information", "topic" => "transport", "prior_evidence" => evidence)
    runner = Dialogue::ProcedureRunner.new(read_port: @last_port, registration_port: ->(**) { raise "Unexpected account read" }, destinations: {})
    @fetches.clear
    followup = runner.transport_walking_follow_up(state:, context: @context, message: "Otvori mapu do te autobuske stanice.")
    assert_equal "answered", followup.resolution
    assert_includes followup.reply.text, walking.fetch("destination")
    assert_equal evidence, followup.state.fetch("prior_evidence")
    assert_empty @fetches
    refute_includes followup.state.to_s, "google.com/maps"
  end

  def test_complete_pair_cyrillic_and_english_preserve_source_matching_and_explicit_stop_labels
    ["Како да стигнем од Bijeljina (sud) до Примјерврта сутра у подне?",
     "How can I get from Bijeljina (sud) to Primjervrt tomorrow at noon?"].each do |query|
      result = read(origin: nil, location: nil, entities: { "area_query" => nil, "query" => query })
      assert_equal "ok", result.status
      assert_includes result.facts.first.fetch("text"), "Bijeljina (sud) 2026-09-10 13:12 → Primjervrt (CSP)"
      assert_equal "transport_navigation", result.facts.last.fetch("kind")
    end
  end

  def test_unextractable_or_compound_journey_never_passes_a_whole_sentence_as_destination
    ["Kako mogu do centra i dalje do Primjervrta?", "Od centra do Primjervrta ili Primjerpolja", "Od centra do Primjervrta pa prijavi problem"].each do |query|
      @fetches.clear
      result = read(origin: "centra", location: nil, entities: { "area_query" => nil, "query" => query })
      assert_equal "ambiguous", result.status
      assert_includes result.warnings, "transport_destination_required"
      assert_empty result.facts
      assert_empty @fetches
    end
    unknown = read(origin: nil, location: nil, entities: { "area_query" => nil, "query" => "Od centra do NeprovjereneLokacije sutra u podne" })
    assert_equal "empty", unknown.status
    assert_empty unknown.facts
    unsupported_destination = read(origin: "centra", location: nil, entities: { "area_query" => nil, "query" => "Bus Bijeljina Primjervrt" })
    assert_equal "ambiguous", unsupported_destination.status
    assert_includes unsupported_destination.warnings, "transport_destination_required"
    assert_empty unsupported_destination.facts
  end

  def test_text_origin_navigation_requires_unique_exact_registry_identity_with_provenance
    [[stop(label: "Bijeljina (NAS)"), stop(label: "Bijeljina (NAS)")], [stop(label: "Bijeljina (NAS)", source: nil)],
     [stop(label: "Bijeljina (sud)")]].each do |registry|
      result = read(registry:, origin: "Bijeljina (NAS)", location: nil, entities: { "time_expression" => "sutra u podne" })
      assert_equal "ok", result.status
      assert_equal(["transport_leg"], result.facts.map { |fact| fact.fetch("kind") })
    end
  end

  def test_registry_followup_refuses_unknown_duplicate_or_unproven_stop_and_public_read_denial
    id = "transport_stop:#{Digest::SHA256.hexdigest("Bijeljina (sud)")[0, 12]}"
    assert_nil timetable.walking_directions(stop_id: "https://untrusted.example/stop")
    assert_nil timetable.walking_directions(stop_id: "transport_stop:000000000000")
    assert_nil timetable(registry: [stop, stop]).walking_directions(stop_id: id)
    assert_nil timetable(registry: [stop(source: nil)]).walking_directions(stop_id: id)
    read
    @fetches.clear
    denied = @last_port.transport_walking_directions(stop_id: id, context: @context.with(capabilities: []))
    assert_equal "not_authorized", denied.status
    assert_empty denied.facts
    assert_empty @fetches
  end

  private

  def stop(label: "Bijeljina (sud)", latitude: 0.500535, longitude: 0.501077, accuracy: "provided", source: STOP_SOURCE)
    { label:, latitude:, longitude:, accuracy:, source: }
  end

  def timetable(registry: [stop], text: TEXT)
    Timetable.new(fetcher: lambda { |url|
      @fetches << url
      text
    }, text_extractor: ->(body) { body },
                  clock: -> { NOW.in_time_zone }, cache: false, stop_registry: registry, snapshot_store: Object.new)
  end

  def read(registry: [stop], text: TEXT, locale: "sr", origin: "odavde", location: LOCATION, entities: {}) # rubocop:disable Metrics/ParameterLists
    unused = Object.new
    directory = Object.new
    directory.define_singleton_method(:find) { |_| nil }
    checker = Object.new
    check = Check.new(source_key: "public_transport", status: :ok, notices: [@notice], checked_at: NOW)
    checker.define_singleton_method(:check) { |**| [check] }
    port = DecidimApp::Bijeljina::Milica::ReadPort.new(organization: @organization, timetable: timetable(registry:, text:),
                                                       source_checker: checker, event_feed: unused, area_matcher: unused,
                                                       directory:, duplicate_finder: unused, waste_schedule: unused)
    port.define_singleton_method(:log_failure) { |error, _action| raise error }
    @last_port = port
    port.call(action: "ask_information", topic: "transport", entities: { "stop" => origin, "area_query" => "Primjervrt" }.merge(entities),
              context: @context, locale:, location:)
  end

  def render(result, locale:)
    turn = Dialogue::ProcedureRunner::Turn.new(read_port: nil, registration_port: nil, destinations: {},
                                               state: { "entities" => {}, "entity_provenance" => {}, "locale" => locale },
                                               context: @context, message: nil, understanding: nil)
    turn.send(:validated_facts, result).map { |fact| turn.send(:render_fact, fact) }.join("\n\n")
  end

  def assert_walking_url(url, destination:)
    uri = URI.parse(url)
    assert_equal "https", uri.scheme
    assert_equal "www.google.com", uri.host
    assert_equal "/maps/dir/", uri.path
    assert_equal({ "api" => "1", "destination" => destination, "travelmode" => "walking" }, URI.decode_www_form(uri.query).to_h)
    assert_nil uri.userinfo
    assert_nil uri.fragment
  end
end

# rubocop:enable Rails/RefuteMethods
