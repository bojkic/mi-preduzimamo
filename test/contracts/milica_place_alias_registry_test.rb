# frozen_string_literal: true

# Standalone Minitest has refute helpers, without ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "json"
require_relative "../support/synthetic_place_areas"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/hash/slice"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/text")
require_relative "../../app/services/decidim_app/bijeljina/city_service_area_matcher"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/geo/area_locator")

# Invented names, topology and coordinates. No real GIS, capture, database or
# network. City-name literals only exercise the documented reference parser.
class MilicaPlaceAliasRegistryTest < Minitest::Test
  Area = Struct.new(:id, :kind, :slug, :name, :primary_mz_slug, :overlapping_mz_slugs, :boundary, keyword_init: true) do
    def translated_name = name.fetch("sr")
  end

  def setup
    @areas = SyntheticPlaceAreas.areas(Area)
    @registry = DecidimApp::Bijeljina::PlaceAliasRegistry.new(areas: @areas, config: SyntheticPlaceAreas.aliases)
    # Typed source records are fictional; loading configured adapters is covered
    # separately by public default/configuration tests.
    entry_class = DecidimApp::Bijeljina::PlaceAliasRegistry::Entry
    references = [
      entry_class.new(id: "synthetic-street", kind: "street_segment", label: "Izmišljena ulica", aliases: ["ul izmisljena", "izmisljena ulica"],
                      source: "https://community.example.invalid/parking", properties: { "relation" => "part", "area_slugs" => [] }),
      entry_class.new(id: "synthetic-stop", kind: "facility", label: "Izmišljeno stajalište", aliases: ["izmisljeno stajaliste"],
                      source: "https://community.example.invalid/map", properties: { "accuracy" => "assumed", "geographic_crosswalk" => "unknown" })
    ]
    @registry.define_singleton_method(:reference_entries) { references }
    @matcher = DecidimApp::Bijeljina::CityServiceAreaMatcher.new(organization: Struct.new(:id).new(1), alias_registry: @registry)
    @matcher.instance_variable_set(:@local_areas, @areas)
  end

  def test_complete_public_catalog_and_stable_slug_round_trip
    assert_equal 22, @areas.size
    assert_equal(10, @areas.count { |area| area.kind == "mz" })
    assert_equal(12, @areas.count { |area| area.kind == "komsiluk" })
    @areas.each do |area|
      result = @matcher.resolve(area_slug: area.slug)
      assert_equal :ok, result.status
      assert_equal [area.slug], result.areas.map(&:slug)
    end
  end

  def test_longest_qualified_name_does_not_expand_novi_or_lugovi
    result = @matcher.match("Radovi u MZ Novi Lugovi")
    assert_equal ["mz-novi-lugovi"], result.slugs
    assert_equal "mz", result.targeting_level
    assert_equal "part", result.coverage.fetch("affected_places").first.fetch("relation")
    assert_equal :ok, @matcher.resolve(area_query: "MZ Novi Lugovi").status
    assert_equal ["mz-novi-lugovi"], @matcher.resolve(area_query: "MZ Novi Lugovi").areas.map(&:slug)
  end

  def test_independent_named_places_are_retained
    result = @matcher.match("MZ Novi Lugovi i MZ Vrt")
    assert_equal %w(mz-novi-lugovi mz-vrt), result.slugs
    assert_empty result.coverage.fetch("ambiguous_places")
  end

  def test_shared_bare_and_inflected_names_require_clarification
    %w(Vrt Vrtu Врту Lugovi Lugovima Луговима Središte središtu).each do |query|
      resolution = @matcher.resolve(area_query: query)
      assert_equal :ambiguous, resolution.status, query
      assert_equal %w(komsiluk mz), resolution.areas.map(&:kind).sort, query
      result = @matcher.match(query)
      assert_empty result.slugs, query
      assert result.unknown?, query
      assert_equal "ambiguous", result.coverage.fetch("status"), query
    end
    assert_equal ["mz-lugovi"], @matcher.resolve(area_query: "Lugovima", place_kind: "mz").areas.map(&:slug)
    assert_equal ["komsiluk-vrt"], @matcher.resolve(area_query: "komšiluk Vrt").areas.map(&:slug)
  end

  # A village whose komšiluk and MZ are one place (the komšiluk lies in that
  # MZ alone and no other komšiluk touches it) names a single board, so the
  # provider's settlement list resolves instead of waiting for an operator.
  def test_provider_settlement_word_order_and_inflections_resolve_one_to_one_villages
    result = @matcher.match("Naseljena mjesta: Donji Gaj – Bočni dio, Nepregledana Dolina i dio Gornjeg Gaja")
    assert_equal %w(mz-gaj-donji mz-gaj-gornji), result.slugs
    assert_equal "mz", result.targeting_level
    assert_empty result.coverage.fetch("ambiguous_places")
    # Grabići is not one of our places. It must say so, or automation would
    # publish to Crnjelovo alone and call the list covered.
    assert_equal "partial", result.coverage.fetch("status")
    assert_equal [{ "kind" => "locality", "evidence" => "nepregledana dolina", "reason" => "containment_not_verified" }],
                 result.coverage.fetch("unresolved_places")
    assert_equal(%w(part part), result.coverage.fetch("affected_places").map { |place| place.fetch("relation") })
    assert_equal %w(komsiluk-zorice mz-zorice), @matcher.resolve(area_query: "dio Zorica").areas.map(&:slug).sort
    assert_empty @matcher.match("TS Donji Gaj").slugs
  end

  def test_synthetic_provider_lists_preserve_resolved_and_unresolved_places
    {
      "Naseljena mjesta: Zorice, Donji Gaj" => [%w(mz-gaj-donji mz-zorice), []],
      "Naseljena mjesta: Donji i Gornji Brijeg, Zorice" => [%w(mz-brijeg mz-zorice), []],
      "Naseljena mjesta: Donji Gaj i Gornji Gaj, Nepregledana Dolina" => [%w(mz-gaj-donji mz-gaj-gornji), ["nepregledana dolina"]],
      "Naseljena mjesta: Gornjeg Gaja, Neupisano Polje" => [["mz-gaj-gornji"], ["neupisano polje"]]
    }.each do |text, (slugs, missing)|
      result = @matcher.match(text)
      assert_equal slugs, result.slugs, text
      assert_equal missing, result.coverage.fetch("unresolved_places").map { |place| place.fetch("evidence") }, text
      assert_equal missing.empty? ? "resolved" : "partial", result.coverage.fetch("status"), text
    end
  end

  # Veliki Park spans two komšiluci; Vrt and Lugovi each share their MZ
  # with a neighbouring komšiluk. A bare name there still does not say which
  # board, so it still waits for a person.
  def test_a_name_shared_by_an_mz_and_a_partial_komsiluk_stays_ambiguous
    ["Vrt", "Lugovi", "Veliki Park"].each do |name|
      result = @matcher.match("Naseljena mjesta: #{name}")
      assert_empty result.slugs, name
      assert_equal "ambiguous", result.coverage.fetch("status"), name
    end
    mixed = @matcher.match("Naseljena mjesta: Zorice, Veliki Park")
    assert_equal ["mz-zorice"], mixed.slugs
    assert_equal "ambiguous", mixed.coverage.fetch("status")
  end

  def test_explicit_type_never_resolves_a_homonym_of_another_kind
    assert_equal :unknown, @matcher.resolve(area_query: "MZ Vrt", place_kind: "komsiluk").status
    assert_equal :unknown, @matcher.resolve(area_slug: "mz-vrt", place_kind: "komsiluk").status
    assert_equal :unknown, @matcher.resolve(area_query: "ulica Središte").status
    assert_equal :unknown, @matcher.resolve_place(query: "naselje Lugovi", kind: "mz").status
  end

  def test_unreviewed_explicit_area_retains_partial_coverage
    result = @matcher.match("MZ Vrt; MZ Nepostojeći naziv")
    assert_equal ["mz-vrt"], result.slugs
    assert_equal "partial", result.coverage.fetch("status")
    assert_equal "place_not_reviewed", result.coverage.fetch("unresolved_places").first.fetch("reason")
    assert_empty @matcher.match("Radovi u ulici Središte").slugs
    assert_equal "street", @matcher.match("Radovi u ulici Središte").coverage.fetch("unresolved_places").first.fetch("kind")
  end

  def test_substrings_and_provider_or_normal_service_text_do_not_claim_coverage
    ["otklanjanja novih kvarova", "Adresa preduzeća MZ Vrt, Bijeljina",
     "Na ostalim lokalitetima u gradu vodosnabdijevanje je uredno.",
     "Cijela Bijeljina ima normalno snabdijevanje.", "Vodovod Bijeljina"].each do |text|
      result = @matcher.match(text)
      assert_empty result.slugs, text
      assert_equal "unknown", result.targeting_level, text
      assert result.unknown?, text
    end
  end

  def test_explicit_citywide_and_affected_span_evidence
    result = @matcher.match("Bez vode je cijela Bijeljina.")
    assert_equal "citywide", result.targeting_level
    assert_equal "cijela bijeljina", result.coverage.fetch("citywide_evidence")
    refute result.unknown?
    scoped = @matcher.match("Vodovod Bijeljina", affected_text: "MZ Vrt. Na ostalim lokalitetima u gradu snabdijevanje je uredno.")
    assert_equal ["mz-vrt"], scoped.slugs
    assert_equal "mz", scoped.targeting_level
  end

  def test_city_name_is_valid_citizen_query_scope_but_not_source_outage_evidence
    ["Bijeljina", "struja Bijeljina", "da li su planirana isključenja struje u Bijeljini", "Има ли воде у Бијељини"].each do |query|
      resolved = @matcher.match_query(query)
      assert_equal "citywide", resolved.targeting_level, query
      assert_equal "citizen_query", resolved.coverage.fetch("scope_role"), query
      assert_empty resolved.slugs, query
      assert @matcher.match(query).unknown?, query
    end
    assert @matcher.match_query("struja u nepoznatom naselju, Bijeljina").unknown?
    assert @matcher.match_query("struja u MZ Nepoznata, Bijeljina").unknown?
    assert_equal "ambiguous", @matcher.match_query("struja u Vrtu, Bijeljina").coverage.fetch("status")
  end

  def test_normal_service_contrast_preserves_affected_clause_only
    result = @matcher.match("Bez vode je MZ Vrt, dok je u gradu snabdijevanje uredno.")
    assert_equal ["mz-vrt"], result.slugs
    assert_nil result.coverage.fetch("citywide_evidence")
  end

  def test_overlap_is_candidate_evidence_and_never_whole_affected_area
    result = @matcher.match("Cijela MZ Novi Lugovi i dio MZ Vrt")
    assert_equal %w(mz-novi-lugovi mz-vrt), result.slugs
    assert_equal "whole", result.coverage.fetch("affected_places").find { |row| row["slug"] == "mz-novi-lugovi" }.fetch("relation")
    assert_equal "part", result.coverage.fetch("affected_places").find { |row| row["slug"] == "mz-vrt" }.fetch("relation")
    candidates = result.coverage.fetch("notification_candidates")
    assert_includes candidates.map { |row| row.fetch("slug") }, "komsiluk-rub"
    assert(candidates.all? { |row| row.fetch("relation") == "possible_overlap" })
  end

  def test_feeder_street_and_settlement_names_have_no_invented_crosswalk
    ["Dalekovod Lugovi", "Далековод Дворови", "TS Vrt", "Ulica MZ Novi", "Naselje Lugovi", "Rejon 4"].each do |text|
      result = @matcher.match(text)
      assert_empty result.slugs, text
      assert result.unknown?, text
      assert_equal "geographic_crosswalk_not_reviewed", result.coverage.fetch("unresolved_places").first.fetch("reason"), text
    end
    result = @matcher.match("MZ Vrt; dalekovod nepoznati")
    assert_equal ["mz-vrt"], result.slugs
    assert_equal "partial", result.coverage.fetch("status")
  end

  def test_typed_domain_references_preserve_source_and_segment_or_coordinate_limits
    street = @matcher.resolve_place(query: "ul. Izmišljena", kind: "street_segment")
    assert_equal :ok, street.status
    assert_equal "street_segment", street.places.first.kind
    assert_equal "part", street.places.first.properties.fetch("relation")
    assert_empty street.places.first.properties.fetch("area_slugs")
    stop = @matcher.resolve_place(query: "Izmišljeno stajalište", kind: "facility")
    assert_equal :ok, stop.status
    assert_equal "assumed", stop.places.first.properties.fetch("accuracy")
    assert_equal "unknown", stop.places.first.properties.fetch("geographic_crosswalk")
    assert_equal :unknown, @matcher.resolve_place(query: "Dalekovod Lugovi", kind: "feeder").status
  end

  def test_invalid_location_accuracy_is_unknown_before_any_geometry_lookup
    [-1, "not a number", Float::INFINITY].each do |accuracy|
      result = @matcher.resolve(location: { latitude: 0.05, longitude: 0.0, accuracy: })
      assert_equal :unknown, result.status
      assert_equal "location_accuracy_invalid", result.warning
    end
  end

  def test_reported_accuracy_crossing_synthetic_polygon_edge_is_ambiguous
    area = @areas.find { |row| row.slug == "mz-vrt" }
    area.boundary = { "type" => "Polygon", "coordinates" => [[[0.0, 0.0], [0.1, 0.0], [0.1, 0.1], [0.0, 0.1], [0.0, 0.0]]] }
    locator = Object.new
    locator.define_singleton_method(:resolve) { |**| { mz: area, komsiluk: nil } }
    Decidim::Bih::Geo::AreaLocator.stub(:new, locator) do
      exact = @matcher.resolve(location: { latitude: 0.05, longitude: 0.0001, accuracy: 2 })
      assert_equal :ok, exact.status
      uncertain = @matcher.resolve(area_query: "MZ Vrt", location: { latitude: 0.05, longitude: 0.0001, accuracy: 20 })
      assert_equal :ambiguous, uncertain.status
      assert_equal "location_near_area_boundary", uncertain.warning
    end
  end
end

# rubocop:enable Rails/RefuteMethods
