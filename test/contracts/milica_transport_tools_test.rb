# frozen_string_literal: true

# rubocop:disable Rails/RefuteMethods -- standalone Minitest, no ActiveSupport::TestCase helpers

ENV["MT_NO_PLUGINS"] = "1"
require "bundler/setup"
gem "minitest", ">= 5.1", "< 6"
require "minitest/autorun"
require "json"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/hash/slice"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/exclude"
require "active_support/core_ext/array/access"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/read_tool_registry")
%w(walking_estimate nearby_stops timetable_snapshot journey_query journey_planner stop_resolver).each do |name|
  require File.join(engine_root, "app/services/decidim/bih/transport", name)
end
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/source_refresh_budget"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_calendar"
require_relative "../../app/services/decidim_app/bijeljina/reviewed_transport_timetables"
require_relative "../../app/services/decidim_app/bijeljina/public_transport_timetable"
require_relative "../../app/services/decidim_app/bijeljina/milica/transport_tools"
require_relative "../../app/services/decidim_app/bijeljina/milica/verified_answer_renderer"

# Authored synthetic prepared snapshots; no Rails, DB, provider,
# network, PDF extraction or materialization job. Fetching is always forbidden.
require_relative "../support/synthetic_transport_network"

class MilicaTransportToolsTest < Minitest::Test
  include SyntheticTransportNetwork
  Host = DecidimApp::Bijeljina
  Dialogue = Decidim::Bih::Concierge::Dialogue
  Reviewed = Host::ReviewedTransportTimetables
  Tools = Host::Milica::TransportTools
  Notice = Data.define(:source_key, :url, :title)
  Row = Data.define(:source_version, :last_success_at, :check_payload, :last_good_payload)
  NOW = Time.utc(2026, 9, 16, 6)

  class Timetable < Host::PublicTransportTimetable
    private

    def default_stop_registry_path
      ENV.fetch("MI_TRANSPORT_STOPS_PATH")
    end
  end

  class Snapshots
    attr_reader :rows

    def initialize = @rows = {}

    def snapshot(source_key:) = rows[source_key]

    def version_for(*) = "probe-checked-in-corpus-v1"
  end

  def setup
    install_synthetic_transport
    @prior_zone = Time.zone
    Time.zone = "UTC" # rubocop:disable Rails/TimeZoneAssignment -- deliberately test a different process zone
    @store = Snapshots.new
    @allowed = true
    @notices = Reviewed.manifest.fetch("routes").map { |entry| Notice.new("public_transport", entry.dig("timetable", "url"), entry.fetch("title")) }
    @reader = Timetable.new(clock: -> { NOW }, snapshot_store: @store, prepared_only: true, cache: false,
                            source_validator: ->(url, source) { @allowed && source == "public_transport" && @notices.any? { |notice| notice.url == url } },
                            fetcher: ->(*) { flunk "fetch forbidden" }, text_extractor: ->(*) { flunk "PDF extraction forbidden" })
    @notices.each { |notice| prepare_fixture(notice) }
    @tools = Tools.new(organization_id: 1, registry_epoch: "transport-probe-v1", timetable: @reader, notices: @notices)
    @registry = Dialogue::ReadToolRegistry.new(definitions: @tools.definitions)
    @context = context
    @eligibility = ->(**) { true } # Registry trust behavior is independently exercised below.
  end

  def test_foreign_new_stations_do_not_become_bijeljina_nas
    ["nova autobuska stanica Primjerpolje", "Nova autobuska Primjervrt", "Novo naselje"].each do |query|
      refute resolve(query).candidates.any? { |row| row.fetch("label").include?("NAS") }, query
    end
  end

  def test_calendar_evidence_distinguishes_range_holiday_and_unpublished_sunday
    { "2027-06-02" => "outside_reviewed_calendar_range", "2027-01-07" => "holiday_or_exception_not_reviewed",
      "2026-09-20" => "sunday_timetable_not_published", "2026-09-19" => "reviewed_calendar_kind" }.each do |date, reason|
      result = @registry.call(name: "service_calendar", arguments: { "line" => "G1", "date" => date }, context: @context, eligibility: @eligibility)
      assert_equal "ok", result.status
      assert_equal reason, result.evidence.first.fetch("facts").fetch("calendar_date_status")
      assert_equal date, result.evidence.first.fetch("facts").fetch("requested_service_date")
    end
  end

  def test_outside_calendar_horizon_returns_one_sourced_boundary_without_a_journey
    result = compound("NAS", "ATC", "date" => "2027-06-02", "after_time" => "08:00")
    assert_equal "ok", result.status
    assert_equal 1, result.evidence.size
    record = result.evidence.first
    assert_equal "transport:calendar:#{Reviewed::CALENDAR_ID}", record.fetch("document_id")
    facts = record.fetch("facts")
    assert_equal "unsupported", facts.fetch("journey_status")
    assert_equal "outside_reviewed_calendar_range", facts.fetch("calendar_date_status")
    assert_equal "2027-05-13", facts.fetch("reviewed_until")
    assert_equal "2027-06-02", facts.fetch("requested_service_date")
    refute facts.has_key?("departure_at")
    refute facts.has_key?("route_code")
    refute result.coverage_complete
    assert_equal Reviewed.manifest.fetch("calendar").fetch("sources").map { |row| row.fetch("url") },
                 (facts.fetch("calendar_source_documents").map { |row| row.fetch("url") })
    @allowed = false
    revoked = compound("NAS", "ATC", "date" => "2027-06-02", "after_time" => "08:00")
    assert_equal "unavailable", revoked.status
    assert_empty revoked.evidence
  end

  def test_same_trip_column_preserves_blank_nas_departure
    result = @registry.call(name: "inspect_timetable_trip",
                            arguments: { "line" => "P13", "date" => "2026-09-16", "stop_query" => "Primjerpolje škola", "at_time" => "12:15" },
                            context: @context, eligibility: @eligibility)
    assert_equal "ok", result.status
    facts = result.evidence.first.fetch("facts")
    assert_equal 2, facts.fetch("trip_column_index")
    cells = facts.fetch("cells")
    assert_nil cells.find { |row| row.fetch("stop_label").include?("NAS") }.fetch("time")
    assert_equal "12:15", cells.find { |row| row.fetch("stop_label") == "Primjerpolje (škola)" }.fetch("time")
    assert_includes result.warnings, "same_trip_column_only"
  end

  def test_named_navigation_rereads_map_and_nas_does_not_invent_platform
    map = @registry.call(name: "resolve_walking_directions", arguments: { "query" => "Izmišljena ulica" }, context: @context, eligibility: @eligibility)
    assert_equal "ok", map.status
    assert_match(%r{https://}, map.evidence.first.fetch("facts").fetch("walking_map_url"))
    nas = @registry.call(name: "resolve_walking_directions", arguments: { "query" => "Nova autobuska Bijeljina" }, context: @context, eligibility: @eligibility)
    assert_equal "ok", nas.status
    assert_equal false, nas.evidence.first.fetch("facts").fetch("physical_platform_assignment_verified")
    refute nas.evidence.first.fetch("facts").has_key?("walking_map_url")
  end

  def teardown
    restore_synthetic_transport
    Time.zone = @prior_zone # rubocop:disable Rails/TimeZoneAssignment -- restore isolated test state
  end

  def test_natural_aliases_resolve_one_logical_station_without_inventing_platforms
    expected = resolve("Bijeljina (NAS)").candidates
    queries = ["NAS", "nova autobuska stanica", "novoj autobuskoj stanici", "Nova AS", "Nova autobuska stanica Bijeljina",
               "Nova autobuska", "Новој аутобуској станици у Бијељини"]
    queries.each do |query|
      assert_equal expected, resolve(query).candidates, query
      assert_equal "ok", resolve(query).status
    end
    assert_equal 1, expected.size
    candidate = expected.first
    assert_match(/\Atransport_station:[a-f0-9]{12}\z/, candidate.fetch("id"))
    assert_equal "Bijeljina (NAS)", candidate.fetch("label")
    assert_equal Tools::STOP_DOCUMENT, candidate.fetch("document_id")
    assert_match(/\A[a-f0-9]{64}\z/, candidate.fetch("revision"))
    # A logical station is not permission to choose one approximate map point.
    assert_nil @reader.walking_directions(stop_id: candidate.fetch("id"))
    physical = stop("Bijeljina (NAS)", code: "P13", direction: "A")
    assert_equal physical, @reader.walking_directions(stop_id: physical).fetch("id")
  end

  def test_logical_station_preserves_directional_source_rows_for_city_and_school_journeys
    station = resolve("NAS").candidates.first.fetch("id")
    city = compound("nova autobuska stanica", "Primjerpark")
    school = compound("NAS", "škola u Primjerpolju")
    [[city, "G1", "08:30", "08:40"], [school, "P12", "11:20", "11:50"]].each do |result, code, departure, arrival|
      assert_equal "ok", result.status, result.warnings.inspect
      facts = result.evidence.first.fetch("facts")
      assert_equal code, facts.fetch("route_code")
      assert_equal "#{facts.fetch("origin_label")} → #{facts.fetch("destination_label")}", facts.fetch("direction")
      assert_equal stop("Bijeljina (NAS)", code: code, direction: "A"), facts.fetch("origin_id")
      assert_equal departure, Time.iso8601(facts.fetch("departure_at")).strftime("%H:%M")
      assert_equal arrival, Time.iso8601(facts.fetch("arrival_at")).strftime("%H:%M")
      assert_equal station, result.query_scope.fetch("subject_ids").first
    end
    assert_equal city.evidence, journey(station, resolve("Primjerpark").candidates.first.fetch("id")).evidence
    @reader.define_singleton_method(:build_planner_cache) { nil }
    assert_equal city.evidence, compound("NAS", "Primjerpark").evidence
    assert_equal school.evidence, compound("NAS", "škola u Primjerpolju").evidence
  end

  def test_circular_route_direction_describes_boarding_leg_without_reversing_source_times
    outward = compound("NAS", "Primjerpark", "date" => "2026-09-17", "after_time" => "10:00", "route_code" => "G1")
    reverse = compound("Primjerpark", "NAS", "date" => "2026-09-17", "after_time" => "10:00", "route_code" => "G1")
    [[outward, "Bijeljina (NAS) → Primjerpark", "10:30", "10:40"],
     [reverse, "Primjerpark → Bijeljina (NAS)", "10:40", "11:05"]].each do |result, direction, departure, arrival|
      assert_equal "ok", result.status
      record = result.evidence.first
      facts = record.fetch("facts")
      assert_equal direction, facts.fetch("direction")
      assert_equal "boarding_to_alighting", facts.fetch("direction_scope")
      assert_equal "Radni dan ŠKOLA", facts.fetch("source_calendar_heading")
      assert_equal departure, Time.iso8601(facts.fetch("departure_at")).strftime("%H:%M")
      assert_equal arrival, Time.iso8601(facts.fetch("arrival_at")).strftime("%H:%M")
      assert_equal Reviewed.manifest.fetch("routes").find { |route| route.fetch("code") == "G1" }.dig("timetable", "url"), record.fetch("source_url")
      refute_empty record.fetch("revision")
    end
  end

  def test_logical_station_respects_reverse_direction_route_and_service_day
    station = resolve("NAS").candidates.first.fetch("id")
    intergaj = resolve("Primjerpark").candidates.first.fetch("id")
    reverse = journey(intergaj, station, "route_code" => "G1")
    assert_equal "ok", reverse.status
    assert_equal "Primjerpark", reverse.evidence.first.dig("facts", "origin_label")
    assert_equal stop("Bijeljina (NAS)", code: "G1", direction: "A"), reverse.evidence.last.dig("facts", "destination_id")
    wrong_line = journey(station, intergaj, "route_code" => "G2")
    assert_equal "unsupported", wrong_line.status
    assert_empty wrong_line.evidence
    sunday = journey(station, intergaj, "date" => "2026-09-20", "route_code" => "G1")
    assert_equal "unsupported", sunday.status
    assert_empty sunday.evidence
    assert_includes sunday.warnings, "no_departures_published_for_service_day"
    refute sunday.coverage_complete
  end

  def test_logical_station_does_not_collapse_distinct_locality_choices_or_invent_ids
    %w(Primjerpolje Primjervrt).each do |place|
      result = compound("NAS", place)
      assert_equal "ambiguous", result.status
      assert_empty result.evidence
      assert_includes result.warnings, "transport_destination_ambiguous"
      refute_includes result.warnings, "transport_origin_ambiguous"
      assert_operator result.candidates.map { |item| item.fetch("label") }.uniq.size, :>, 1
    end
    invalid = journey("transport_station:000000000000", resolve("Primjerpark").candidates.first.fetch("id"))
    assert_includes invalid.warnings, "unknown_transport_stop_id"
    assert_empty invalid.evidence
    logical = resolve("NAS").candidates.first.fetch("id")
    physical = stop("Bijeljina (NAS)", code: "G1", direction: "A")
    assert_empty journey(logical, physical).evidence
  end

  def test_qualifiers_and_ambiguous_places_remain_candidates
    school = resolve("škola u Primjerpolju")
    refute_empty school.candidates
    assert(school.candidates.all? { |candidate| candidate.fetch("label").include?("Primjerpolje (škola)") })
    locality = resolve("Primjervrt")
    assert_equal "ambiguous", locality.status
    assert_operator locality.candidates.size, :>, 1
    assert(locality.candidates.any? { |candidate| candidate.fetch("label").include?("CSP") })
    assert_empty locality.evidence
    refute locality.coverage_complete
  end

  def test_bound_journey_uses_exact_directional_ids_and_calculated_timestamps
    origin = stop("Bijeljina (NAS)", code: "P13", direction: "A")
    destination = stop("Primjerpolje (centar)", code: "P13", direction: "A")
    result = journey(origin, destination)
    assert_equal "ok", result.status, result.warnings.inspect
    first = result.evidence.first.fetch("facts")
    assert_equal origin, first.fetch("origin_id")
    assert_equal destination, result.evidence.last.fetch("facts").fetch("destination_id")
    assert_equal "2026-09-16", first.fetch("requested_service_date")
    assert first.fetch("departure_at").end_with?("+02:00")
    assert_operator Time.iso8601(first.fetch("departure_at")), :>, Time.iso8601("2026-09-16T08:00:00+02:00")
    assert(result.evidence.all? { |record| record.fetch("document_id").start_with?("transport:") && record.fetch("revision").size == 64 })
    refute result.coverage_complete
    # Supplying an old physical ID still restricts the calculator to that ID.
    other = stop("Bijeljina (NAS)", code: "G1", direction: "A")
    other_result = journey(other, destination)
    assert(other_result.evidence.all? { |record| record.fetch("facts").fetch("leg_index") != 0 || record.fetch("facts").fetch("origin_id") == other })
  end

  def test_transfer_evidence_carries_each_leg_and_wait_and_direct_constraint
    origin = stop("Primjervrt (CSP)", code: "P1", direction: "B")
    destination = stop("Primjerpolje (centar)", code: "P13", direction: "A")
    result = journey(origin, destination, "after_time" => "06:00")
    assert_equal "ok", result.status, result.warnings.inspect
    assert_equal 2, result.evidence.size
    legs = result.evidence.map { |record| record.fetch("facts") }
    assert_equal 1, legs.first.fetch("transfer_count")
    assert_equal (Time.iso8601(legs.last.fetch("departure_at")) - Time.iso8601(legs.first.fetch("arrival_at"))).to_i, legs.last.fetch("wait_before_seconds")
    direct = journey(origin, destination, "after_time" => "06:00", "direct_only" => true)
    refute_equal "ok", direct.status
    assert_empty direct.evidence
  end

  def test_cached_and_uncached_matching_produce_identical_bound_tuples
    origin = stop("Bijeljina (NAS)", code: "P13", direction: "A")
    destination = stop("Primjerpolje (centar)", code: "P13", direction: "A")
    cached = journey(origin, destination).evidence
    @reader.define_singleton_method(:build_planner_cache) { nil }
    assert_equal cached, journey(origin, destination).evidence
  end

  def test_explicit_service_day_never_rolls_to_tomorrow_and_unpublished_calendar_is_not_a_schedule
    origin = stop("Bijeljina (NAS)", code: "P13", direction: "A")
    destination = stop("Primjerpolje (centar)", code: "P13", direction: "A")
    late = journey(origin, destination, "after_time" => "23:59")
    refute_equal "ok", late.status
    assert_empty late.evidence
    sunday = journey(origin, destination, "date" => "2026-09-20")
    refute_equal "ok", sunday.status
    assert_empty sunday.evidence
    refute sunday.coverage_complete
  end

  def test_expired_prepared_documents_are_not_exposed
    @store.rows.transform_values! { |row| Row.new(row.source_version, NOW - 15.days, row.check_payload, row.last_good_payload) }
    assert_equal "unavailable", resolve("NAS").status
    assert_empty resolve("NAS").candidates
  end

  def test_one_round_convenience_reuses_bound_calculator_and_source_provenance
    origin = resolve("Izmišljena ulica").candidates.fetch(0).fetch("id")
    destination = resolve("Primjerpark").candidates.fetch(0).fetch("id")
    result = compound("Izmišljena ulica", "Primjerpark")
    assert_equal "ok", result.status, result.warnings.inspect
    expected = journey(origin, destination)
    assert_equal expected.evidence, result.evidence
    assert_equal [origin, destination], result.query_scope.fetch("subject_ids")
    assert_equal expected.query_scope, result.query_scope
    expected = %w(resolve_stops published_boarding_points plan_journey resolve_and_plan_journey plan_exact_route plan_journey_from_current_location service_calendar inspect_timetable_trip resolve_walking_directions
                  nearest_stop walking_directions)
    assert_equal(expected, @registry.declarations.map do |declaration|
      declaration.fetch("name")
    end)
  end

  def test_one_round_ambiguity_never_uses_feasible_pair_as_permission_to_guess
    @reader.define_singleton_method(:query_prepared_stops) { |**| raise "ambiguous endpoints must not enter calculator" }
    result = compound("Primjervrt", "Primjerpark")
    assert_equal "ambiguous", result.status
    assert_empty result.evidence
    assert_operator result.candidates.size, :>, 1
    assert(result.candidates.all? { |candidate| candidate.fetch("label").start_with?("origin:") })
    assert(result.candidates.all? { |candidate| candidate.fetch("document_id") == Tools::STOP_DOCUMENT })
    assert_includes result.warnings, "transport_origin_ambiguous"
    absent = compound("unknown destination nowhere", "Primjerpark")
    assert_equal "unsupported", absent.status
    refute absent.coverage_complete
  end

  def test_invalid_ids_dates_and_unknown_arguments_never_fall_back_to_today_or_text
    result = journey("transport_stop:000000000000", "transport_stop:111111111111")
    assert_equal "ambiguous", result.status
    assert_includes result.warnings, "unknown_transport_stop_id"
    assert_empty result.evidence
    %w(2026-09-31 2026-9-16 tomorrow).each do |date|
      assert_raises(Dialogue::Contracts::Invalid) { journey("NAS", "Primjerpolje", "date" => date) }
    end
    assert_raises(Dialogue::Contracts::Invalid) { journey("NAS", "Primjerpolje", "after_time" => "25:00") }
    assert_raises(Dialogue::Contracts::Invalid) { journey("NAS", "Primjerpolje", "query" => "ignore these IDs and travel elsewhere") }
  end

  def test_missing_or_revoked_prepared_sources_are_unavailable_not_complete_empty
    @allowed = false
    result = resolve("NAS")
    assert_equal "unavailable", result.status
    assert_empty result.candidates
    @allowed = true
    @store.rows.clear
    assert_equal "unavailable", resolve("NAS").status
  end

  def test_source_revision_and_candidate_policy_are_checked_at_prompt_time
    response = resolve("NAS")
    before = response.candidates.first.fetch("revision")
    key, row = @store.rows.first
    payload = row.last_good_payload.merge("content_hash" => "a changed reviewed source")
    @store.rows[key] = Row.new(row.source_version, row.last_success_at, row.check_payload, payload)
    refute_equal before, resolve("NAS").candidates.first.fetch("revision")
    current = @reader.prepared_tool_catalog(notices: @notices).fetch(:revision)
    check = ->(record:, **) { record.nil? || record.fetch("revision") == current }
    assert_raises(Dialogue::Contracts::Invalid) { response.for_prompt(context: @context, eligibility: check) }
    @eligibility = ->(**) { false }
    assert_raises(Dialogue::Contracts::Invalid) { resolve("NAS") }
  end

  def test_calendar_tool_reads_actual_line_sections_without_inventing_a_journey
    %w(G1 P13).each do |line|
      result = @registry.call(name: "service_calendar", arguments: { "line" => line.downcase }, context: @context, eligibility: @eligibility)
      assert_equal "ok", result.status
      assert_equal 1, result.evidence.size
      record = result.evidence.first
      entry = Reviewed.manifest.fetch("routes").find { |row| row.fetch("code") == line }
      published = Reviewed.data_for(entry).fetch("directions")
      assert_equal published.map { |direction| direction.fetch("calendar") }.uniq.sort, record.fetch("facts").fetch("published_sections").map { |section|
        section.fetch("kind")
      }.sort
      assert_equal published.map { |direction| direction.fetch("source_heading") }.uniq.sort,
                   record.fetch("facts").fetch("published_sections").flat_map { |section| section.fetch("source_headings") }.uniq.sort
      assert_equal entry.dig("timetable", "url"), record.fetch("source_url")
      assert_equal Reviewed.manifest.fetch("calendar").fetch("reviewed_until"), record.fetch("facts").fetch("reviewed_until")
      assert_includes record.fetch("facts").fetch("published_sections").map { |section| section.fetch("kind") }, "saturday" if line == "G1"
      assert_includes result.warnings, "holiday_exceptions_unverified"
      refute result.coverage_complete
    end
  end

  def test_calendar_tool_unknown_line_revocation_and_extra_arguments_fail_closed
    unknown = @registry.call(name: "service_calendar", arguments: { "line" => "X99" }, context: @context, eligibility: @eligibility)
    assert_equal "unsupported", unknown.status
    assert_empty unknown.evidence
    assert_raises(Dialogue::Contracts::Invalid) do
      @registry.call(name: "service_calendar", arguments: { "line" => "G1", "actor_id" => 3 }, context: @context, eligibility: @eligibility)
    end
    @allowed = false
    revoked = @registry.call(name: "service_calendar", arguments: { "line" => "G1" }, context: @context, eligibility: @eligibility)
    assert_equal "unavailable", revoked.status
    assert_empty revoked.evidence
  end

  def test_coordinate_nearest_stop_reuses_reviewed_distance_and_public_map_without_origin
    coordinates = { "latitude" => 0.500031, "longitude" => 0.502051 }
    existing = @reader.nearest_stop(location: coordinates, deadline: @context.deadline)
    result = @registry.call(name: "nearest_stop", arguments: coordinates, context: @context, eligibility: @eligibility)
    assert_equal "ok", result.status
    record = result.evidence.fetch(0)
    facts = record.fetch("facts")
    assert_equal existing.boarding_stop.fetch("id"), facts.fetch("stop_id")
    assert_equal existing.origin, facts.fetch("stop_label")
    assert_equal existing.candidates.find { |candidate| candidate.fetch("id") == facts.fetch("stop_id") }.dig("coverage", "distance_meters"), facts.fetch("distance_meters")
    assert_equal "straight_line", facts.fetch("distance_kind")
    assert_includes record.fetch("limitations"), "walking_route_not_verified"
    assert_includes record.fetch("limitations"), "assumed_stop_coordinates"
    refute_includes JSON.generate(result.for_prompt(context: @context, eligibility: @eligibility)), coordinates.fetch("latitude").to_s
    query = URI.decode_www_form(URI(facts.fetch("walking_map_url")).query).to_h
    assert_equal "walking", query.fetch("travelmode")
    refute query.has_key?("origin")
    refute result.coverage_complete
    walking = @registry.call(name: "walking_directions", arguments: { "stop_id" => facts.fetch("stop_id") }, context: @context, eligibility: @eligibility)
    assert_equal facts.fetch("walking_map_url"), walking.evidence.fetch(0).fetch("facts").fetch("walking_map_url")
    refute walking.evidence.fetch(0).fetch("facts").has_key?("distance_meters")
  end

  def test_consented_nearest_stop_uses_server_location_even_when_model_supplies_other_coordinates
    location = { latitude: 0.50025, longitude: 0.50025, consent: true, purpose: "current_location", provenance: "browser_geolocation" }
    tools = Tools.new(organization_id: 1, registry_epoch: "transport-probe-v1", timetable: @reader, notices: @notices, location:)
    registry = Dialogue::ReadToolRegistry.new(definitions: tools.definitions)
    at_location = registry.call(name: "nearest_stop", arguments: {}, context: @context, eligibility: @eligibility)
    misleading = registry.call(name: "nearest_stop", arguments: { "latitude" => 0.5000, "longitude" => 0.5040 },
                                context: @context, eligibility: @eligibility)
    expected = @reader.nearest_stop(location:, deadline: @context.deadline)
    [at_location, misleading].each do |result|
      assert_equal "ok", result.status
      assert_equal expected.origin, result.evidence.fetch(0).dig("facts", "stop_label")
      assert_equal expected.candidates.fetch(0).dig("coverage", "distance_meters"), result.evidence.fetch(0).dig("facts", "distance_meters")
      assert_equal "Bijeljina (NAS)", result.evidence.fetch(0).dig("facts", "stop_label")
    end

    record = misleading.evidence.fetch(0)
    payload = { "kind" => "answer", "answer" => "Vučko je 237 metara od vas.", "evidence_ids" => [record.fetch("id")] }
    rendered = Host::Milica::VerifiedAnswerRenderer.new.call(payload:, evidence: [misleading.for_prompt(context: @context, eligibility: @eligibility)],
                                                              question: "Koje je najbliže autobusko stajalište ovoj lokaciji?")
    assert_equal "validated_claims", rendered.reason
    assert_includes rendered.text, "Bijeljina (NAS)"
    refute_includes rendered.text, "Vučko"
    refute_includes rendered.text, "237"
    assert_match(/pješački put nije provjeren/i, rendered.text)
    uncited = Host::Milica::VerifiedAnswerRenderer.new.call(payload: payload.merge("evidence_ids" => []),
                                                            evidence: [misleading.for_prompt(context: @context, eligibility: @eligibility)],
                                                            question: "Koje je najbliže autobusko stajalište ovoj lokaciji?")
    assert_equal "high_risk_unverified", uncited.reason
    refute_includes uncited.text, "Vučko"
  end

  def test_navigation_rejects_missing_coordinates_unknown_stops_and_revoked_sources
    assert_raises(Dialogue::Contracts::Invalid) { @registry.call(name: "nearest_stop", arguments: { "latitude" => 0.5 }, context: @context, eligibility: @eligibility) }
    assert_raises(Dialogue::Contracts::Invalid) do
      @registry.call(name: "nearest_stop", arguments: { "latitude" => 91, "longitude" => 0.5 }, context: @context, eligibility: @eligibility)
    end
    absent = @registry.call(name: "walking_directions", arguments: { "stop_id" => "transport_stop:000000000000" }, context: @context, eligibility: @eligibility)
    assert_equal "unsupported", absent.status
    assert_empty absent.evidence
    distant = @registry.call(name: "nearest_stop", arguments: { "latitude" => 0, "longitude" => 0 }, context: @context, eligibility: @eligibility)
    assert_equal "unsupported", distant.status
    assert_empty distant.evidence
    @allowed = false
    revoked = @registry.call(name: "nearest_stop", arguments: { "latitude" => 0.5000, "longitude" => 0.50205 }, context: @context, eligibility: @eligibility)
    assert_equal "unavailable", revoked.status
    assert_empty revoked.evidence
  end

  def test_wrong_tenant_expired_deadline_and_unauthenticated_authority_are_rejected
    @context = context(organization_id: 2)
    assert_raises(Dialogue::Contracts::Invalid) { resolve("NAS") }
    @context = context(capabilities: [])
    assert_raises(Dialogue::Contracts::Invalid) { resolve("NAS") }
    @context = context(deadline: Host::SourceRefreshBudget.new(timeout: 0.001, clock: -> { 1_000_000 }))
    @context.deadline.instance_variable_set(:@deadline, 0)
    assert_raises(Dialogue::Contracts::Invalid) { resolve("NAS") }
  end

  def test_optional_route_constraint_is_shared_and_never_relaxes_to_other_lines
    origin = resolve("Izmišljena ulica").candidates.first.fetch("id")
    destination = resolve("Primjerpark").candidates.first.fetch("id")
    result = journey(origin, destination, "route_code" => "G1", "date" => "2026-09-19")
    assert_equal "ok", result.status
    assert_equal "2026-09-19T10:14:00+02:00", result.evidence.first.dig("facts", "departure_at")
    assert_includes result.query_scope.fetch("subject_ids"), "transport-route:G1"
    assert(result.evidence.all? { |record| record.dig("facts", "route_code") == "G1" })
    compound = @registry.call(name: "resolve_and_plan_journey", arguments: { "origin_query" => "Izmišljena ulica", "destination_query" => "Primjerpark",
                                                                             "date" => "2026-09-19", "after_time" => "08:00", "route_code" => "G1" },
                              context: @context, eligibility: @eligibility)
    assert_equal result.evidence, compound.evidence
    assert_equal result.query_scope, compound.query_scope
    wrong_line = journey(origin, destination, "route_code" => "G2")
    assert_equal "unsupported", wrong_line.status
    assert_empty wrong_line.evidence
    refute wrong_line.coverage_complete
    assert_includes wrong_line.query_scope.fetch("subject_ids"), "transport-route:G2"
    unknown = journey(origin, destination, "route_code" => "G99")
    assert_equal "unsupported", unknown.status
    assert_includes unknown.warnings, "line_not_in_reviewed_snapshot"
    assert_empty unknown.evidence
  end

  def test_route_constraint_is_validated_even_before_ambiguous_resolution
    %w(G0 GP 1).each do |invalid|
      assert_raises(Dialogue::Contracts::Invalid) do
        @registry.call(name: "resolve_and_plan_journey", arguments: { "origin_query" => "Primjervrt", "destination_query" => "Primjerpolje",
                                                                      "date" => "2026-09-16", "after_time" => "08:00", "route_code" => invalid },
                       context: @context, eligibility: @eligibility)
      end
    end
    unresolved = @registry.call(name: "resolve_and_plan_journey", arguments: { "origin_query" => "Primjervrt", "destination_query" => "Primjerpolje",
                                                                               "date" => "2026-09-16", "after_time" => "08:00", "route_code" => "P1" },
                                context: @context, eligibility: @eligibility)
    assert_equal "ambiguous", unresolved.status
    assert_includes unresolved.query_scope.fetch("subject_ids"), "transport-route:P1"
    assert_empty unresolved.evidence
  end

  def test_cyrillic_and_case_variants_canonicalize_to_source_route_ids
    origin = resolve("Izmišljena ulica").candidates.first.fetch("id")
    destination = resolve("Primjerpark").candidates.first.fetch("id")
    %w(Г1 г1 g1 G1).each do |spelling|
      result = journey(origin, destination, "route_code" => spelling, "date" => "2026-09-19")
      assert_equal "ok", result.status, spelling
      assert_equal "G1", result.evidence.first.dig("facts", "route_code")
      assert_equal "G1", result.evidence.first.dig("facts", "requested_constraints", "route_code")
      assert_includes result.query_scope.fetch("subject_ids"), "transport-route:G1"
    end
    calendar = @registry.call(name: "service_calendar", arguments: { "line" => "Г1", "date" => "2026-09-19" },
                              context: @context, eligibility: @eligibility)
    assert_equal "ok", calendar.status
    assert_includes calendar.query_scope.fetch("subject_ids"), "G1"
  end

  def test_area_default_and_fastest_planner_disclose_the_selected_stop
    old_area = ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"]
    old_planner = ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"]
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = "true"
    ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] = "true"

    result = compound("Bijeljina", "Primjerpolje", "date" => "2026-09-17", "after_time" => "11:00")
    assert_equal "ok", result.status
    assert_equal true, result.query_scope.fetch("search_complete")
    assert_equal "fastest_arrival", result.evidence.first.dig("facts", "objective")
    assert_equal "Primjerpolje (centar)", result.evidence.first.dig("facts", "assumed_stop").find { |item| item.fetch("place_id") == "transport-place:primjerpolje" }.fetch("selected_stop")
    assert_equal result.query_scope.fetch("resolved_query"), result.evidence.first.dig("facts", "resolved_query")
    assert result.evidence.first.dig("facts", "leave_at")
  ensure
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = old_area
    ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] = old_planner
  end

  def test_area_default_resolution_exposes_reviewed_stop_and_alternatives_as_evidence
    old_area = ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"]
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = "true"
    result = resolve("Primjervrta")
    assert_equal "ok", result.status
    assert_equal 1, result.candidates.size
    assert_equal "assumed_area_stop", result.evidence.first.dig("facts", "kind")
    assert_equal "Primjervrt (CSP)", result.evidence.first.dig("facts", "selected_stop")
    assert_includes result.evidence.first.dig("facts", "alternative_stops"), "Primjervrt (škola)"
    assert_equal result.candidates.first.fetch("selection_key"), result.evidence.first.dig("facts", "stop_id")
    assert_equal resolve("Primjerpolje (centar)").candidates.map { |row| row.fetch("selection_key") },
                 resolve("Primjerpolja (centar)").candidates.map { |row| row.fetch("selection_key") }
  ensure
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = old_area
  end

  def test_v2_renderer_distinguishes_destination_assumption_and_deduplicates_journey
    old_area = ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"]
    old_planner = ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"]
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = "true"
    ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] = "true"
    result = compound("Primjer (AMD)", "NAS", "date" => "2026-09-17", "after_time" => "09:00")
    assert_equal "ok", result.status
    selected = result.evidence.find { |row| row.dig("facts", "leg_index") == 0 }
    payload = { "kind" => "answer", "answer" => "", "evidence_ids" => [selected.fetch("id")],
                "claim_selections" => Array.new(2) { { "kind" => "selected_journey", "evidence_id" => selected.fetch("id") } } }
    rendered = Host::Milica::VerifiedAnswerRenderer.new.call(payload:, evidence: [result.for_prompt(context: @context, eligibility: @eligibility)],
                                                              question: "Od Primjer (AMD) do NAS-a nakon 09:00")
    assert_equal "validated_claims", rendered.reason
    assert_equal 1, rendered.text.scan("Najbrži procijenjeni dolazak").size
    assert_includes rendered.text, "Za odredište računam do stajališta Bijeljina (NAS)"
    refute_includes rendered.text, "Računam od stajališta Bijeljina (NAS)"
  ensure
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = old_area
    ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] = old_planner
  end

  def test_retained_consent_location_reuses_the_private_nearby_planner_path
    old_area = ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"]
    old_planner = ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"]
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = "true"
    ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] = "true"
    base = { latitude: 0.50015, longitude: 0.50015, accuracy: 20, consent: true, purpose: "current_location" }
    arguments = { "destination_query" => "Primjerpolje", "date" => "2026-09-17", "after_time" => "11:00" }
    results = %w(browser_geolocation retained_consent).map do |provenance|
      tools = Tools.new(organization_id: 1, registry_epoch: "transport-probe-v1", timetable: @reader, notices: @notices,
                        location: base.merge(provenance:))
      registry = Dialogue::ReadToolRegistry.new(definitions: tools.definitions)
      registry.call(name: "plan_journey_from_current_location", arguments:, context: @context, eligibility: @eligibility)
    end

    assert_equal %w(ok ok), results.map(&:status)
    assert_equal results.first.evidence, results.last.evidence
    assert_equal "consented_current_location", results.last.query_scope.dig("resolved_query", "origin_resolution")
    inflected = Tools.new(organization_id: 1, registry_epoch: "transport-probe-v1", timetable: @reader, notices: @notices,
                          location: base.merge(provenance: "browser_geolocation"))
    inflected_result = Dialogue::ReadToolRegistry.new(definitions: inflected.definitions).call(
      name: "plan_journey_from_current_location", arguments: arguments.merge("destination_query" => "Primjerpolja (centar)"),
      context: @context, eligibility: @eligibility
    )
    assert_equal "ok", inflected_result.status
    assert_equal "Primjerpolje (centar)", inflected_result.evidence.last.dig("facts", "journey_destination_label")
    refute_includes JSON.generate(results.last.query_scope), base.fetch(:latitude).to_s
    refute_includes JSON.generate(results.last.query_scope), base.fetch(:longitude).to_s
  ensure
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = old_area
    ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] = old_planner
  end

  def test_published_boarding_has_provenance_without_departure_or_walk_claim
    result = published_boarding
    assert_equal "ok", result.status, result.warnings.inspect
    refute result.coverage_complete
    refute result.query_scope.key?("date")
    assert_includes result.warnings, "walking_path_not_verified"
    assert result.evidence.any?
    result.evidence.each do |record|
      facts = record.fetch("facts")
      assert_equal "P1", facts.fetch("route_code")
      assert_equal "A", facts.fetch("published_direction")
      assert_equal "Primjervrt (CSP)", facts.fetch("origin_label")
      assert_equal "Primjervrt (škola)", facts.fetch("destination_label")
      assert_operator facts.fetch("source_row_from"), :<, facts.fetch("source_row_to")
      %w(service_date_selected departure_confirmed walking_path_verified).each { |key| assert_equal false, facts.fetch(key) }
      %w(departure_at arrival_at service_date).each { |key| refute facts.key?(key) }
      assert_match %r{\Ahttps://community\.example\.invalid/}, record.fetch("source_url")
      refute_empty record.fetch("revision")
    end
  end

  def test_published_boarding_does_not_join_different_lines
    result = published_boarding("Primjer (AMD)", "Primjerpolje (škola)")
    assert_equal "unsupported", result.status
    assert_empty result.evidence
    assert_includes result.warnings, "no_shared_trip_column_in_reviewed_scope"
    refute result.coverage_complete
  end

  def test_published_boarding_rejects_split_columns_and_reverse_order
    catalog = @reader.prepared_tool_catalog(notices: @notices)
    route = catalog.fetch(:routes).find { |row| row.code == "P1" }.dup
    direction = route.directions.find { |row| row.name == "A" }.dup
    origin = direction.stops.find { |row| row.label == "Primjervrt (CSP)" }.dup
    destination = direction.stops.find { |row| row.label == "Primjervrt (škola)" }.dup
    origin.times = ["08:00", nil]
    destination.times = [nil, "08:30"]
    direction.stops = [origin, destination]
    route.directions = [direction]
    @reader.stub(:prepared_tool_catalog, catalog.merge(routes: [route])) do
      result = published_boarding
      assert_equal "unsupported", result.status
      assert_empty result.evidence
      destination.times = ["08:30", nil]
      direction.stops = [destination, origin]
      result = published_boarding
      assert_equal "unsupported", result.status
      assert_empty result.evidence
    end
  end

  def test_published_boarding_rejects_revoked_and_expired_sources
    @allowed = false
    result = published_boarding
    assert_equal "unavailable", result.status
    assert_empty result.evidence
    @allowed = true
    @store.rows.transform_values! { |row| Row.new(row.source_version, NOW - 15.days, row.check_payload, row.last_good_payload) }
    result = published_boarding
    assert_equal "unavailable", result.status
    assert_empty result.evidence
  end

  def test_published_boarding_rechecks_revision_before_exposing_records
    catalog = @reader.prepared_tool_catalog(notices: @notices)
    calls = 0
    @reader.stub(:prepared_tool_catalog, ->(**) { calls += 1; calls == 1 ? catalog : catalog.merge(revision: "replacement-revision") }) do
      result = published_boarding
      assert_equal "unavailable", result.status
      assert_empty result.evidence
      assert_includes result.warnings, "prepared_timetable_changed_during_search"
      assert_equal 2, calls
    end
  end

  def test_published_boarding_preserves_trust_and_unresolved_boundaries
    @context = context(organization_id: 2)
    assert_raises(Dialogue::Contracts::Invalid) { published_boarding }
    @context = context(capabilities: [])
    assert_raises(Dialogue::Contracts::Invalid) { published_boarding }
    @context = context(deadline: Host::SourceRefreshBudget.new(timeout: 0.001, clock: -> { 1_000_000 }))
    @context.deadline.instance_variable_set(:@deadline, 0)
    assert_raises(Dialogue::Contracts::Invalid) { published_boarding }
    @context = context
    result = published_boarding("Unknown invented stop nowhere", "Primjervrt (škola)")
    assert_equal "unsupported", result.status
    assert_empty result.evidence
    result = published_boarding("Primjervrt (CSP)", "Primjervrt (CSP)")
    assert_equal "ambiguous", result.status
    assert_empty result.evidence
    assert_includes result.warnings, "published_boarding_endpoints_overlap"
    assert_empty @reader.prepared_physical_stop_ids(id: "transport-stop:not-in-catalog", catalog: @reader.prepared_tool_catalog(notices: @notices))
  end

  def test_published_boarding_never_uses_legacy_center_shortcut_without_place_configuration
    catalog = @reader.prepared_tool_catalog(notices: @notices)
    assert @reader.resolve_prepared_stops(query: "centar", catalog:).any?, "fixture must expose legacy center shortcut"
    @reader.define_singleton_method(:resolve_prepared_stops) { |**| raise "Legacy local fallback forbidden for this operation" }
    with_boarding_area_setting("true") do
      Host::PublicTransportPlaces.stub(:entries, []) do
        result = published_boarding("centar", "Primjervrt (škola)")
        assert_equal "unsupported", result.status
        assert_empty result.evidence
        assert_includes result.warnings, "published_boarding_endpoints_unresolved"
      end
    end
  end

  def test_published_boarding_uses_only_explicit_enabled_center_mapping
    with_boarding_area_setting("true") do
      result = published_boarding("centar", "Primjervrt (škola)")
      assert_equal "ok", result.status, result.warnings.inspect
      assert_includes result.warnings, "configured_area_stop_assumption"
      assert result.evidence.any?
      assert result.evidence.all? { |row| row.dig("facts", "origin_label") == "Bijeljina (NAS)" }
      refute result.evidence.any? { |row| row.dig("facts", "origin_label") == "Bijeljina (spomenik)" }
      assert result.evidence.all? { |row| row.fetch("source_url").start_with?("https://community.example.invalid/") }
    end
  end

  def test_published_boarding_does_not_activate_configured_areas_when_switch_is_off
    with_boarding_area_setting("false") do
      result = published_boarding("centar", "Primjervrt (škola)")
      assert_equal "unsupported", result.status
      assert_empty result.evidence
      assert_equal "ok", published_boarding.status
    end
  end

  def test_published_boarding_exact_stops_work_without_any_optional_place_file
    with_boarding_area_setting("false") do
      Host::PublicTransportPlaces.stub(:entries, -> { raise "Disabled area configuration must not be read" }) do
        result = published_boarding
        assert_equal "ok", result.status
        refute_includes result.warnings, "configured_area_stop_assumption"
      end
    end
  end

  def test_published_boarding_keeps_conflicting_configured_centers_ambiguous
    places = Host::PublicTransportPlaces.entries
    another = { "id" => "transport-place:other-authored-center", "name" => "Drugi centar", "aliases" => ["centar"],
                "default_label" => "Primjer (AMD)", "member_labels" => ["Primjer (AMD)"], "assumption_reason" => "authored_conflict" }
    with_boarding_area_setting("true") do
      Host::PublicTransportPlaces.stub(:entries, places + [another]) do
        result = published_boarding("centar", "Primjervrt (škola)")
        assert_equal "ambiguous", result.status
        assert_empty result.evidence
        assert_includes result.warnings, "published_boarding_places_ambiguous"
        assert_operator result.candidates.size, :>=, 2
        assert result.candidates.any? { |row| row.fetch("label").include?("Drugi centar") }
      end
    end
  end

  private

  def context(**overrides)
    Dialogue::Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, capabilities: ["public_reads"], now: NOW,
                                            deadline: Host::SourceRefreshBudget.new(timeout: 30), **overrides)
  end

  def resolve(query)
    @registry.call(name: "resolve_stops", arguments: { "query" => query }, context: @context, eligibility: @eligibility)
  end

  def with_boarding_area_setting(value)
    prior = ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"]
    ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = value
    yield
  ensure
    prior.nil? ? ENV.delete("MILICA_AREA_DEFAULT_STOPS_ENABLED") : ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] = prior
  end

  def published_boarding(origin = "Primjervrt (CSP)", destination = "Primjervrt (škola)")
    @registry.call(name: "published_boarding_points", arguments: { "origin_query" => origin, "destination_query" => destination },
                   context: @context, eligibility: @eligibility)
  end

  def compound(origin, destination, overrides = {})
    @registry.call(name: "resolve_and_plan_journey", arguments: { "origin_query" => origin, "destination_query" => destination,
                                                                  "date" => "2026-09-16", "after_time" => "08:00" }.merge(overrides), context: @context, eligibility: @eligibility)
  end

  def journey(origin, destination, overrides = {})
    @registry.call(name: "plan_journey", arguments: { "origin_id" => origin, "destination_id" => destination,
                                                      "date" => "2026-09-16", "after_time" => "08:00" }.merge(overrides), context: @context, eligibility: @eligibility)
  end

  def stop(label, code:, direction:)
    catalog = @reader.prepared_tool_catalog(notices: @notices)
    route = catalog.fetch(:routes).find { |candidate| candidate.code == code }
    row = route.directions.find { |candidate| candidate.name == direction }.stops.find { |candidate| candidate.label == label }
    raise "fixture stop missing: #{label} #{code} #{direction}" unless row

    @reader.prepared_stop_id(row)
  end

  def prepare_fixture(notice)
    entry = Reviewed.entry_for(notice.url)
    data = Reviewed.data_for(entry)
    directions = data.fetch("directions").map do |direction|
      stops = direction.fetch("stops").each_with_index.map do |row, index|
        point = Reviewed.stop_location_for(entry.fetch("code"), direction.fetch("name"), row.fetch("label"))
        { "label" => row.fetch("label"), "normalized_label" => @reader.send(:normalized_text, row.fetch("label")),
          "times" => row.fetch("times"), "index" => index, "latitude" => point.fetch("latitude"), "longitude" => point.fetch("longitude"),
          "coordinates_source" => point.fetch("image_url"), "coordinates_accuracy" => point.fetch("accuracy") }
      end
      { "name" => direction.fetch("name"), "calendar" => Reviewed.calendar_metadata(direction, entry), "stops" => stops }
    end
    payload = { "status" => "ok", "checked_at" => NOW.iso8601, "content_hash" => entry.dig("timetable", "sha256"), "source_url" => notice.url,
                "directions" => directions, "calendars" => directions.map { |direction| direction.fetch("calendar") }.uniq { |calendar| calendar.fetch("kind") } }
    @store.rows[@reader.send(:document_key, notice)] = Row.new(@reader.send(:document_version, notice), NOW, { "status" => "ok" }, payload)
  end
end

# rubocop:enable Rails/RefuteMethods
