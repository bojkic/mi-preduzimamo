# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require_relative "../support/synthetic_place_areas"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/text")
require_relative "../../app/services/decidim_app/bijeljina/city_service_area_matcher"
require_relative "../../app/services/decidim_app/bijeljina/milica/activity_question_context"

# Uses an independent authored-name registry and the real existing matcher.
# No Rails, database, inferred identity/crosswalk or citizen records.
class MilicaActivityQuestionContextTest < Minitest::Test
  Context = DecidimApp::Bijeljina::Milica::ActivityQuestionContext
  Area = Struct.new(:id, :kind, :slug, :name, :primary_mz_slug, :overlapping_mz_slugs, :boundary, keyword_init: true) do
    def translated_name = name.fetch("sr")
  end

  def setup
    areas = SyntheticPlaceAreas.areas(Area)
    registry = DecidimApp::Bijeljina::PlaceAliasRegistry.new(areas:, config: SyntheticPlaceAreas.aliases)
    @matcher = DecidimApp::Bijeljina::CityServiceAreaMatcher.new(organization: Struct.new(:id).new(1), alias_registry: registry)
    @matcher.instance_variable_set(:@local_areas, areas)
  end

  def test_inflected_supplied_place_uses_existing_two_identity_ambiguity
    ["Ima li uskoro javnih okupljanja u Vrtu?", "Има ли ускоро јавних окупљања у Врту?"].each do |query|
      candidate = extract(query)
      assert_equal "vrtu", candidate.query
      assert_nil candidate.warning
      assert_equal "citizen_activity_locative", candidate.coverage["area_query_source"]
      resolved = @matcher.resolve(area_query: candidate.query)
      assert_equal :ambiguous, resolved.status
      assert_equal %w(komsiluk mz), resolved.areas.map(&:kind).sort
    end
  end

  def test_explicit_kind_is_preserved_and_never_becomes_a_crosswalk
    { "Ima li okupljanja u MZ Vrt?" => "mz", "Ima li okupljanja u komšiluku Vrt?" => "komsiluk",
      "Ima li okupljanja u mjesnoj zajednici Vrt uskoro?" => "mz" }.each do |query, kind|
      candidate = extract(query)
      assert_nil candidate.warning
      resolved = @matcher.resolve(area_query: candidate.query)
      assert_equal :ok, resolved.status
      assert_equal [kind], resolved.areas.map(&:kind)
    end
    resolved = @matcher.resolve(area_query: extract("Ima li okupljanja u naselju Vrt?").query)
    assert_equal :unknown, resolved.status
    assert_empty resolved.areas
  end

  def test_relative_scope_and_existing_citizen_slots_are_not_replaced
    ["Šta ima u mom komšiluku?", "Ima li okupljanja u blizini?", "Ima li okupljanja u komšiluku?",
     "Ima li okupljanja u subotu?", "Ima li okupljanja u narednih 7 dana?"].each { |query| assert_nil extract(query) }
    %w(area_slug area_query street address).each do |key|
      assert_nil extract("Ima li okupljanja u Vrtu?", entities: { key => "Already supplied" })
    end
    assert_nil Context.call(action: "neighborhood_information", topic: "neighborhood", entities: { "query" => "Objave u Vrtu" })
    assert_nil Context.call(action: "report_problem", topic: "neighborhood", entities: { "query" => "Prijavi problem u Vrtu" })
  end

  def test_supported_next_weekend_suffix_is_not_mistaken_for_part_of_the_place_name
    ["sljedećeg vikenda", "sledećeg vikenda", "sljedeći vikend", "sledeći vikend",
     "narednog vikenda", "naredni vikend", "za sljedeći vikend", "next weekend"].each do |time|
      candidate = extract("Ima li okupljanja u MZ Vrt #{time}?")
      assert_nil candidate.warning
      assert_equal "mz vrt", candidate.query
      resolved = @matcher.resolve(area_query: candidate.query)
      assert_equal :ok, resolved.status
      assert_equal ["mz"], resolved.areas.map(&:kind)
    end
    candidate = extract("Има ли окупљања у комшилуку Врт сљедећег викенда?")
    assert_equal "komsiluk vrt", candidate.query
    assert_equal ["komsiluk"], @matcher.resolve(area_query: candidate.query).areas.map(&:kind)
  end

  def test_next_weekend_suffix_does_not_choose_ambiguous_scope_or_rewrite_unsupported_time
    candidate = extract("Ima li okupljanja u Vrtu sljedećeg vikenda?")
    assert_equal "vrtu", candidate.query
    assert_equal :ambiguous, @matcher.resolve(area_query: candidate.query).status
    unsupported = extract("Ima li okupljanja u MZ Vrt prvog vikenda?")
    assert_equal "mz vrt prvog vikenda", unsupported.query
    assert_equal "area_name_ambiguous", extract("Ima li okupljanja ne u MZ Vrt sljedećeg vikenda?").warning
  end

  def test_literal_citizen_qualifier_is_restored_only_to_the_same_unqualified_name
    question = "Koje volonterske akcije ima u komšiluku Vrt ovog vikenda?"
    candidate = extract(question, entities: { "area_query" => "Vrt" })
    assert_equal "komsiluk vrt", candidate.query
    assert_nil candidate.warning
    resolved = @matcher.resolve(area_query: candidate.query)
    assert_equal :ok, resolved.status
    assert_equal ["komsiluk"], resolved.areas.map(&:kind)
    candidate = extract("Ima li okupljanja u MZ Vrt sljedećeg vikenda?", entities: { "area_query" => "Vrt" })
    assert_equal "mz vrt", candidate.query
    assert_equal ["mz"], @matcher.resolve(area_query: candidate.query).areas.map(&:kind)

    ["MZ Vrt", "Komšiluk Vrt", "Brijeg"].each do |supplied|
      assert_nil extract(question, entities: { "area_query" => supplied })
    end
    assert_nil extract(question, entities: { "area_query" => "Vrt", "area_slug" => "mz-vrt" })
    assert_nil extract("Ima li okupljanja u Vrtu sljedećeg vikenda?", entities: { "area_query" => "Vrt" })
    assert_equal "area_name_ambiguous", extract("Ima li okupljanja ne u MZ Vrt sljedećeg vikenda?", entities: { "area_query" => "Vrt" }).warning
  end

  def test_unknown_or_complex_places_never_silently_become_a_known_area
    unknown = extract("Ima li okupljanja u Nepoznatom Mjestu?")
    assert_equal :unknown, @matcher.resolve(area_query: unknown.query).status
    ["Ima li okupljanja u MZ Vrt i Nepoznatom Mjestu?", "Ima li okupljanja ne u Vrtu?"].each do |query|
      assert_equal "area_name_ambiguous", extract(query).warning
    end
  end

  def test_soon_is_closed_bounded_expression_not_a_date_override
    assert Context.soon?({ "time_expression" => "uskoro" })
    assert Context.soon?({ "time_expression" => "soon" })
    assert_equal false, Context.soon?({ "time_expression" => "uskoro", "date" => "2026-09-12" })
    assert_equal false, Context.soon?({ "time_expression" => "sljedeceg mjeseca" })
  end

  private

  def extract(query, entities: {})
    Context.call(action: "ask_information", topic: "neighborhood", entities: { "query" => query }.merge(entities))
  end
end
