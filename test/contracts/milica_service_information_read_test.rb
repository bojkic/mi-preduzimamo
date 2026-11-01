# frozen_string_literal: true

# ReadPort now uses the host's autoloaded directory/reference readers. Boot the
# host explicitly instead of depending on another test file to load Rails first.
require_relative "../test_helper"
require_relative "../support/synthetic_service_directory"
require_relative "../support/synthetic_transport_network"

# Minitest::Test has refute helpers, without ActiveSupport assert_not aliases.
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
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/city/matching")
require File.join(engine_root, "app/services/decidim/bih/city/service_directory")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/contracts")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/service_question")
# ReadPort asks QuestionFacet WHICH question is being asked before it picks
# a source. Without this the constant is missing, the NameError is swallowed
# as "unavailable", and every read below silently degrades.
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/question_facet")
require_relative "../../app/services/decidim_app/bijeljina/city_services_data"
require_relative "../../app/services/decidim_app/bijeljina/city_directory"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/city_service_source_check_store"
require_relative "../../app/services/decidim_app/bijeljina/city_service_event_feed"
require_relative "../../app/services/decidim_app/bijeljina/milica/directory_answer"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

# Actual public ReadPort and reviewed catalog; no external reads.
class MilicaServiceInformationReadTest < Minitest::Test
  include SyntheticServiceDirectory
  include SyntheticTransportNetwork
  ReadPort = DecidimApp::Bijeljina::Milica::ReadPort
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  Directory = DecidimApp::Bijeljina::CityDirectory
  SOURCE_QUESTION = "Gdje Vodovod objavljuje servisne informacije?"

  class UnusedAdapters
    attr_reader :calls

    def initialize = @calls = []

    def query(**) = unexpected(:event)

    def check(**) = unexpected(:source)

    def resolve(**) = unexpected(:area)

    def matches(**) = unexpected(:duplicates)

    def collection_days_for(*) = unexpected(:waste)

    private

    def unexpected(adapter)
      calls << adapter
      raise "Unexpected #{adapter} adapter call"
    end
  end

  class EventRouteProbe
    Area = Data.define(:slug)
    Resolution = Data.define(:status, :areas, :source)
    Result = Data.define(:status, :error_code)
    attr_reader :area_calls, :event_calls

    def initialize
      @area_calls = []
      @event_calls = []
    end

    def resolve(**attributes)
      area_calls << attributes
      Resolution.new(:ok, [Area.new("mz-primjervrt")], :query)
    end

    def query(**attributes)
      event_calls << attributes
      Result.new(:invalid, :event_route_probe)
    end
  end

  class TransportRouteProbe
    SOURCE = "https://community.example.invalid/synthetic/transport/P1.pdf"
    Notice = Data.define(:url, :source_key)
    Check = DecidimApp::Bijeljina::CityServiceSourceCheckStore::Result
    Leg = Data.define(:route_code, :route_title, :origin_label, :destination_label, :departure_at, :arrival_at, :direction_label)
    Itinerary = Data.define(:legs)
    Query = Data.define(:status, :itinerary, :sources, :warnings, :origin, :destination)
    attr_reader :calls

    def initialize = @calls = []

    def check(**)
      [Check.new(source_key: "public_transport", status: :ok, notices: [Notice.new(SOURCE, "public_transport")],
                 checked_at: Time.utc(2026, 9, 8, 11))]
    end

    def query(**attributes)
      calls << attributes
      leg = Leg.new("P1", "Synthetic timetable", attributes.fetch(:origin) || "Synthetic nearest stop", attributes.fetch(:destination),
                    Time.utc(2026, 9, 9, 3, 43), Time.utc(2026, 9, 9, 3, 46), "Outbound")
      Query.new(:ok, Itinerary.new([leg]), [SOURCE], [], leg.origin_label, leg.destination_label)
    end
  end

  # A waste schedule that answers one area, the way the parsed programme does:
  # canonical Latin ijekavian day tokens, whatever the PDF spelled.
  class WasteScheduleProbe
    SOURCE = "https://community.example.invalid/authored-waste.pdf"
    attr_reader :queries

    def initialize = @queries = []

    def areas = ["Izmišljena livada"]

    def data_year = 2026

    def source_url = SOURCE

    def source_checked_at = Time.utc(2026, 6, 7, 9)

    def collection_days_for(query, **)
      queries << query
      %w(srijeda četvrtak)
    end
  end

  def setup
    install_synthetic_service_directory
    sources = DecidimApp::Bijeljina::CityServiceSources
    directory_sources = sources::SOURCES.map do |row|
      row.merge(source_url: "https://community.example.invalid/sources/#{row.fetch(:key)}")
    end
    install_synthetic_transport
    configured = directory_sources.reject { |row| row[:key] == "public_transport" } + sources::SOURCES
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, configured.freeze)
    install_service_information_entries
    @previous_locales = I18n.available_locales
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    @organization = Data.define(:id).new(71)
    @unused = UnusedAdapters.new
  end

  def teardown
    I18n.available_locales = @previous_locales
    restore_synthetic_transport
    restore_synthetic_service_directory
  end

  def test_publication_questions_return_existing_reviewed_source_without_area_or_source_calls
    [
      ["water", SOURCE_QUESTION, "sr"],
      ["water", "Гдје Водовод објављује сервисне информације?", "sr-Cyrl"],
      ["electricity", "Koja je zvanična stranica testnog elektrodistributera?", "sr"],
      ["heating", "Where is the official heating website?", "en"]
    ].each do |topic, query, locale|
      result = read(topic:, entities: { "query" => query }, locale:)
      entry = Directory.find(ReadPort::DIRECTORY_TOPIC_KEYS.fetch(topic))

      assert_equal "ok", result.status, query
      assert_equal 1, result.facts.length
      fact = result.facts.fetch(0)
      assert_equal "service_directory", fact.fetch("kind")
      assert_equal Decidim::Bih::Transliterator.localize(entry.fetch(:answer).squish, locale:), fact.fetch("text")
      assert_equal entry.fetch(:source_url), result.source.fetch("url")
      assert_equal "2026-09-06", fact.fetch("observed_at")
      assert_equal false, result.validity.fetch("live_status")
      assert_includes result.warnings, "snapshot_not_live_status"
      assert_nil result.checked_at
      assert_empty @unused.calls
    end
  end

  def test_time_specific_and_mixed_questions_keep_the_existing_event_route
    [
      { "query" => SOURCE_QUESTION, "date" => "2026-09-08" },
      { "query" => SOURCE_QUESTION, "time_expression" => "sutra" },
      { "query" => "Gdje Vodovod objavljuje informacije i ima li danas prekida vode?" },
      { "query" => "Ima li planiranih prekida vode u Primjervrtu?" }
    ].each do |entities|
      assert_event_route(entities)
    end
  end

  def test_contact_question_uses_the_reviewed_directory_without_an_area_or_live_calls
    result = read(entities: { "query" => "Koji je telefon Vodovoda?" })
    entry = Directory.find(ReadPort::DIRECTORY_TOPIC_KEYS.fetch("water"))

    assert_equal "ok", result.status
    assert_equal 1, result.facts.length
    fact = result.facts.fetch(0)
    assert_equal "service_directory", fact.fetch("kind")
    assert_equal entry.fetch(:answer).squish, fact.fetch("text")
    assert_equal entry.fetch(:source_url), result.source.fetch("url")
    assert_equal false, result.validity.fetch("live_status")
    assert_empty @unused.calls
  end

  def test_unspecified_question_keeps_the_existing_event_route
    assert_event_route("query" => "")
  end

  def test_official_source_question_does_not_bypass_public_read_authority
    result = read(entities: { "query" => SOURCE_QUESTION }, capabilities: [])

    assert_equal "not_authorized", result.status
    assert_empty result.facts
    assert_empty @unused.calls
  end

  def test_anonymous_neighborhood_posts_are_denied_before_area_or_database_access
    context = Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "b" * 64,
                                            capabilities: ["public_reads"], now: Time.utc(2026, 9, 9, 12))
    port = ReadPort.new(organization: @organization, event_feed: @unused, area_matcher: @unused,
                        source_checker: @unused, timetable: @unused, directory: Directory,
                        duplicate_finder: @unused, waste_schedule: @unused)
    protected_calls = []
    [:actor_for!, :read_query].each do |method|
      port.define_singleton_method(method) do |*|
        protected_calls << method
        raise "Unexpected protected read"
      end
    end

    [{}, { "area_query" => "Synthetic neighborhood" }].each do |entities|
      result = port.call(action: "neighborhood_information", topic: "neighborhood", entities:, context:, locale: "sr")

      assert_equal "not_authorized", result.status
      assert_equal ["neighborhood_membership_required"], result.warnings
      assert_empty result.facts
      assert_empty @unused.calls
      assert_empty protected_calls
    end
  end

  def test_transport_missing_origin_asks_before_any_source_read
    result = read(topic: "transport", entities: { "area_query" => "Primjervrt" })

    assert_equal "ambiguous", result.status
    assert_equal ["transport_origin_required"], result.warnings
    assert_empty result.facts
    assert_empty @unused.calls
  end

  def test_transport_identical_stops_use_actual_timetable_canonicalization
    [["Primjervrt", "Primjervrt"], ["Примјерврт", "Primjervrt"], ["NAS-a", "Bijeljina (NAS)"]].each do |origin, destination|
      probe = TransportRouteProbe.new
      timetable = DecidimApp::Bijeljina::PublicTransportTimetable.new(
        cache: false, prepared_only: true, stop_registry: [],
        fetcher: ->(*) { raise "Same-stop validation must not fetch a timetable" }
      )
      probe.define_singleton_method(:query) do |**attributes|
        calls << attributes
        timetable.query(**attributes)
      end
      result = read(topic: "transport", entities: { "stop" => origin, "area_query" => destination }, transport: probe)

      assert_equal "ambiguous", result.status, [origin, result.warnings].inspect
      assert_equal ["transport_same_stop"], result.warnings
      assert_empty result.facts
      assert_equal 1, probe.calls.length
      assert_empty @unused.calls
    end
  end

  def test_transport_distinct_explicit_stops_keep_actual_departure_date
    probe = TransportRouteProbe.new
    result = read(topic: "transport", entities: { "stop" => "Primjervrt (CSP)", "area_query" => "Primjervrt (škola)" }, transport: probe)

    assert_equal "ok", result.status
    assert_equal "Primjervrt (CSP)", probe.calls.fetch(0).fetch(:origin)
    assert_equal "Primjervrt (škola)", probe.calls.fetch(0).fetch(:destination)
    assert_equal "P1 (smjer Outbound): Primjervrt (CSP) 2026-09-09 05:43 → Primjervrt (škola) 2026-09-09 05:46", result.facts.fetch(0).fetch("text")
    assert_equal false, result.validity.fetch("live_vehicle_status")
    assert_empty @unused.calls
  end

  def test_transport_relative_origin_without_coordinates_asks_before_source_read
    ["Sa moje lokacije.", "odavde", "Са моје локације", "from my current location"].each do |origin|
      result = read(topic: "transport", entities: { "stop" => origin, "area_query" => "Primjerpolje" })

      assert_equal "ambiguous", result.status
      assert_equal ["transport_origin_required"], result.warnings
      assert_empty result.facts
      assert_empty @unused.calls
    end
  end

  def test_transport_relative_origin_with_consented_coordinates_uses_timetable_location
    probe = TransportRouteProbe.new
    location = { latitude: 0.51, longitude: 0.50, accuracy: 12, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    result = read(topic: "transport", entities: { "stop" => "Sa moje lokacije.", "area_query" => "Primjerpolje" }, transport: probe, location:)

    assert_equal "ok", result.status
    assert_nil probe.calls.fetch(0).fetch(:origin)
    assert_equal "Primjerpolje", probe.calls.fetch(0).fetch(:destination)
    assert_equal location.transform_keys(&:to_s), probe.calls.fetch(0).fetch(:location)
    assert_equal "Synthetic nearest stop", result.coverage.fetch("origin")
    assert_equal false, result.validity.fetch("live_vehicle_status")
    assert_empty @unused.calls
  end

  def test_transport_named_stop_priority_and_coordinate_consent_are_unchanged
    probe = TransportRouteProbe.new
    location = { latitude: 0.51, longitude: 0.50, accuracy: 12, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    result = read(topic: "transport", entities: { "stop" => "Bijeljina (NAS)", "area_query" => "Primjerpolje" }, transport: probe, location:)

    assert_equal "ok", result.status
    assert_equal "Bijeljina (NAS)", probe.calls.fetch(0).fetch(:origin)
    assert_equal location.transform_keys(&:to_s), probe.calls.fetch(0).fetch(:location)
    assert_raises(Contracts::Invalid) do
      read(topic: "transport", entities: { "stop" => "odavde", "area_query" => "Primjerpolje" }, location: location.merge(consent: false))
    end
    assert_empty @unused.calls
  end

  def test_generic_transport_fare_uses_reviewed_price_source_without_journey_or_source_calls
    result = read(topic: "transport", entities: { "query" => "Koliko košta autobuska karta?" })

    assert_equal "ok", result.status
    assert_includes result.facts.first.fetch("text"), "2,35 KM"
    assert_includes result.source.fetch("url"), "/authored-fares"
    refute_includes result.source.fetch("url"), "/synthetic/transport"
    assert_equal "2026-09-06", result.validity.fetch("reviewed_on")
    assert_equal false, result.validity.fetch("live_status")
    assert_nil result.checked_at
    assert_empty @unused.calls

    denied = read(topic: "transport", entities: { "query" => "Koliko košta autobuska karta?" }, capabilities: [])
    assert_equal "not_authorized", denied.status
    assert_empty denied.facts
  end

  def test_cyrillic_transport_fare_keeps_one_untransliterated_source_url
    result = read(topic: "transport", entities: { "query" => "Колика је цијена аутобуске карте?" }, locale: "sr-Cyrl")

    assert_equal "ok", result.status
    fact = result.facts.fetch(0)
    assert_includes fact.fetch("text"), "карта"
    assert_includes fact.fetch("text"), "2,35 КМ"
    refute_match(%r{https?://|хттпс?://|www\.}, fact.fetch("text"))
    assert_equal Directory.find(:javni_prevoz).dig(:answer_sources, :fares), fact.fetch("source_url")
    assert_empty @unused.calls
  end

  # R7 — the one part of a waste answer that is OUR vocabulary, not the
  # source's prose. The published programme spells the day in Cyrillic and in
  # either dialect; the parser rewrites every spelling into these seven Latin
  # ijekavian tokens before anything downstream sees one, and a sr-Cyrl reply
  # already prints the token transliterated back. So the day follows the reply,
  # while everything a source actually wrote does not — measured on production
  # on 14.09.2026, an otherwise fully English answer read
  # 'Waste collection for "Izmisljena livada": srijeda, četvrtak.'
  def test_the_canonical_collection_days_are_rendered_in_the_reply_language
    schedule = WasteScheduleProbe.new
    port = ReadPort.new(organization: @organization, event_feed: @unused, area_matcher: @unused,
                        source_checker: @unused, timetable: @unused, directory: Directory,
                        duplicate_finder: @unused, waste_schedule: schedule)
    context = Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "d" * 64,
                                            capabilities: ["public_reads"], now: Time.utc(2026, 9, 14, 12))
    {
      "sr" => "srijeda, četvrtak", "bs" => "srijeda, četvrtak", "hr" => "srijeda, četvrtak",
      "sr-Cyrl" => "сриједа, четвртак", "en" => "Wednesday, Thursday"
    }.each do |locale, days|
      result = port.call(action: "ask_information", topic: "waste",
                         entities: { "area_query" => "Izmišljena livada" }, context:, locale:)

      assert_equal "ok", result.status, locale
      fact = result.facts.first

      assert_includes fact.fetch("text"), days, locale
      # The schedule's own answer is never rewritten in place: what the parser
      # returned stays on the fact, for every locale.
      assert_equal %w(srijeda četvrtak), fact.dig("coverage", "collection_days"), locale
      # Nothing the source published is translated. The label and the URL are
      # the citizen's way back to the programme itself.
      assert_equal WasteScheduleProbe::SOURCE, result.source.fetch("url"), locale
    end
  end

  private

  def install_service_information_entries
    host = DecidimApp::Bijeljina
    entries = host::CityServicesData::ENTRIES.map(&:dup)
    entries << { key: :toplana_grijanje, title: "Testna toplana", keywords: %w(toplana grijanje),
      answer: "IZMIŠLJENI PRIMJER objavljivanja informacija o grijanju.",
      source_url: "https://community.example.invalid/heating" }
    entries = entries.map do |entry|
      entry[:source_checked_on] = "2026-09-06"
      if entry[:key] == :javni_prevoz
        fare_url = "https://community.example.invalid/authored-fares"
        entry[:answer_sections] = { fares: "IZMIŠLJENI PRIMJER: autobuska karta 2,35 KM, nije stvarna cijena: #{fare_url}." }
        entry[:answer_sources] = { fares: fare_url }
      end
      entry[:facts] = host::CityServicesData.entry_facts(entry, checked_on: Date.new(2026, 9, 6))
      entry.freeze
    end
    swap_service_constant(host::CityServicesData, :ENTRIES, entries.freeze)
    host::CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new(entries))
  end

  def assert_event_route(entities)
    probe = EventRouteProbe.new
    result = read(entities: entities.merge("area_query" => "Primjervrt"), probe:)

    assert_equal "unavailable", result.status
    assert_equal ["event_route_probe"], result.warnings
    assert_empty result.facts
    assert_equal 1, probe.area_calls.length
    assert_equal 1, probe.event_calls.length
    assert_equal ["mz-primjervrt"], probe.event_calls.fetch(0).fetch(:area_identifiers)
    assert_empty @unused.calls
  end

  def read(entities:, topic: "water", locale: "sr", capabilities: ["public_reads"], probe: nil, transport: nil, location: nil) # rubocop:disable Metrics/ParameterLists -- explicit contract fixture fields
    context = Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "c" * 64,
                                            capabilities:, now: Time.utc(2026, 9, 8, 12, 0))
    port = ReadPort.new(organization: @organization, event_feed: probe || @unused, area_matcher: probe || @unused,
                        source_checker: transport || @unused, timetable: transport || @unused, directory: Directory,
                        duplicate_finder: @unused, waste_schedule: @unused)
    port.call(action: "ask_information", topic:, entities:, context:, locale:, location:)
  end
end

# rubocop:enable Rails/RefuteMethods
