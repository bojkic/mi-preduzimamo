# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "minitest/autorun"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/text")
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/geo/area_locator")
require_relative "../../app/services/decidim_app/bijeljina/city_service_area_crosswalk"
require_relative "../../app/services/decidim_app/bijeljina/city_service_street_intersection"
require_relative "../../app/services/decidim_app/bijeljina/city_service_street_coverage"

class MilicaStreetCoverageTest < Minitest::Test
  Event = Struct.new(:source_key, :source_url, :extraction_metadata, :affected_text, :content_version, keyword_init: true)
  Area = Struct.new(:slug, :kind, :boundary)

  def setup
    @event = Event.new(source_key: "electricity_outages", source_url: "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=41",
                       extraction_metadata: { "tj" => "Bijeljina", "source_snapshot_complete" => true }, content_version: "v1",
                       affected_text: "1 NN izlaz dio ulice Izmišljena lipa")
    @feature = { "properties" => { "name" => "Izmišljena lipa", "settlement" => "Bijeljina", "geometry_complete" => true,
                                   "source_url" => "https://community.example.invalid/authored-line", "source_object_ids" => ["authored-line-1"], "retrieved_at" => "2026-09-09" },
                 "geometry" => { "type" => "LineString", "coordinates" => [[0.2, 0.5], [1.8, 0.5]] } }
    @areas = [Area.new("komsiluk-left", "komsiluk", polygon(0, 1)), Area.new("komsiluk-right", "komsiluk", polygon(1, 2)),
              Area.new("mz-left", "mz", polygon(0, 1))]
  end

  def test_unspecified_part_maps_every_intersected_typed_area_without_full_area_claim
    result = service.match(@event)
    assert result.fetch("complete")
    assert_equal %w(komsiluk-left komsiluk-right mz-left), result.fetch("affected_places").map { |row| row.fetch("slug") }.sort
    assert_equal ["possible_overlap"], result.fetch("affected_places").map { |row| row.fetch("relation") }.uniq
    assert_equal "v1", result.fetch("source_content_version")
    assert_equal "unspecified_street_segment", result.fetch("scope_precision")
  end

  def test_explicit_number_side_or_segment_is_never_broadened_to_full_street
    ["Ulica Izmišljena lipa 12", "Lijeva strana ulice Izmišljena lipa", "Ulica Izmišljena lipa od raskrsnice do mosta", "1 NN izlaz"].each do |text|
      @event.affected_text = text
      assert_nil service.match(@event)
    end
  end

  def test_incomplete_or_competing_street_geometry_is_not_used
    @feature["properties"]["geometry_complete"] = false
    assert_nil service.match(@event)
    @feature["properties"]["geometry_complete"] = true
    assert_nil service(data: { "features" => [@feature, @feature.dup] }).match(@event)
  end

  def test_unknown_second_street_and_unparsed_water_clause_preserve_partial_scope
    @event.affected_text = "Svi NN izlazi ulica Izmišljena lipa i dio ulice Nepoznata"
    result = service.match(@event)
    assert_equal false, result.fetch("complete")
    assert_equal 1, result.fetch("unresolved_places").length
    @event.source_key = "water_service"
    @event.source_url = "https://bnvodovod.com/v2/obavjestenje/"
    @event.affected_text = "Izmišljena lipa (Bijeljina); nepoznato naselje"
    result = service.match(@event)
    assert_equal "partial", result.fetch("status")
    assert_match(/nepoznato naselje/, result.fetch("unresolved_places").first.fetch("evidence"))
  end

  def test_version_snapshot_and_provider_context_guards
    original_url = @event.source_url
    [original_url.sub("https", "http"), original_url.sub("rj=41", "rj=42"), original_url.sub(".com/", ".com:444/"),
     original_url.sub("https://", "https://user@")].each do |url|
      @event.source_url = url
      assert_nil service.match(@event)
    end
    @event.source_url = original_url
    @event.content_version = nil
    assert_nil service.match(@event)
    @event.content_version = "v1"
    @event.extraction_metadata["source_snapshot_complete"] = false
    assert_nil service.match(@event)
  end

  def test_municipal_sides_supplement_offset_centerline_but_never_create_missing_area_identity
    @areas << Area.new("mz-izmisljeni-rub", "mz", nil)
    result = service(municipal_data: {
      "sources" => { "authored_street_decision" => "https://community.example.invalid/authored-decision" },
      "street_sides" => %w(mz-izmisljeni-rub mz-missing-identity).map do |slug|
        { "name" => "izmisljena lipa", "settlement" => "bijeljina", "mz_slug" => slug, "side" => "right",
          "citations" => [{ "source" => "authored_street_decision", "item" => "17" }] }
      end
    }).match(@event)
    legal = result.fetch("affected_places").select { |row| row["source"] == "municipal_street_side" }
    assert_equal(["mz-izmisljeni-rub"], legal.map { |row| row.fetch("slug") })
    assert_equal "17", legal.first.fetch("citations").first.fetch("item")
    assert_equal "right", legal.first.fetch("side")
  end

  private

  def service(data: { "features" => [@feature] }, municipal_data: {})
    # This contract covers the supplied verified geometry and municipal sides;
    # the independently tested local registry must not read production datasets.
    registry = Object.new
    registry.define_singleton_method(:coverage) { |**| [] }
    DecidimApp::Bijeljina::LocalStreetRegistry.stub(:new, registry) do
      DecidimApp::Bijeljina::CityServiceStreetCoverage.new(organization: nil, data:, areas: @areas, municipal_data:)
    end
  end

  def polygon(left, right)
    { "type" => "Polygon", "coordinates" => [[[left, 0], [right, 0], [right, 1], [left, 1], [left, 0]]] }
  end
end
