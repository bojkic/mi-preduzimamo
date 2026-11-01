# frozen_string_literal: true

require "bundler/setup"
require "tmpdir"
require "fileutils"
require_relative "../support/synthetic_place_areas"
require "minitest/autorun"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/text")
require_relative "../../app/services/decidim_app/bijeljina/city_service_settlement_coverage"
require_relative "../../app/services/decidim_app/bijeljina/city_service_area_crosswalk"

class MilicaSettlementCoverageTest < Minitest::Test
  Area = Struct.new(:slug, :kind, :boundary)
  Event = Struct.new(:source_key, :source_url, :extraction_metadata, :affected_text, :content_version, keyword_init: true)

  def setup
    owner = DecidimApp::Bijeljina::CityServiceSettlementCoverage
    @prior_alias_path = owner::ALIASES_PATH
    @authored_alias_root = Dir.mktmpdir("authored-settlement-aliases-")
    path = File.join(@authored_alias_root, "aliases.yml")
    File.write(path, YAML.dump(SyntheticPlaceAreas.aliases))
    owner.send(:remove_const, :ALIASES_PATH)
    owner.const_set(:ALIASES_PATH, path)
    @geometry = { "type" => "Polygon", "coordinates" => [[[0, 0], [2, 0], [2, 2], [0, 2], [0, 0]]] }
    @areas = [Area.new("komsiluk-one", "komsiluk", @geometry), Area.new("komsiluk-two", "komsiluk", @geometry), Area.new("mz-vrt", "mz", @geometry)]
    @feature = { "type" => "Feature", "geometry" => @geometry, "properties" => {
      "name" => "Врт", "aliases" => ["Vrt"], "place_type" => "settlement", "geometry_complete" => true,
      "geometry_sha256" => digest(@geometry), "area_slugs" => @areas.map(&:slug), "source_url" => "https://community.example.invalid/authored-settlement",
      "source_settlement_id" => "test-source", "source_snapshot_sha256" => "public-snapshot"
    } }
    @data = { "features" => [@feature], "boundary_sha256" => @areas.to_h { |area| [area.slug, digest(area.boundary)] } }
    @event = Event.new(source_key: "electricity_outages", source_url: "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=41",
                       extraction_metadata: { "tj" => "Bijeljina", "source_snapshot_complete" => true }, affected_text: "Naseljeno mjesto: Vrt", content_version: "v1")
  end

  def teardown
    owner = DecidimApp::Bijeljina::CityServiceSettlementCoverage
    owner.send(:remove_const, :ALIASES_PATH)
    owner.const_set(:ALIASES_PATH, @prior_alias_path)
    FileUtils.remove_entry_secure(@authored_alias_root) if @authored_alias_root && File.directory?(@authored_alias_root)
  end

  def test_exact_settlement_returns_all_independent_area_kinds_with_possible_overlap
    result = service.match(clause: "vrt")
    assert_equal(%w(komsiluk-one komsiluk-two mz-vrt), result.map { |row| row.fetch("slug") })
    assert_equal ["possible_overlap"], result.map { |row| row.fetch("relation") }.uniq
    assert_equal ["municipal_settlement_geometry"], result.map { |row| row.fetch("source") }.uniq
    assert_equal "public-snapshot", result.first.fetch("source_snapshot_sha256")
    assert_equal(result.map { |row| row.fetch("slug") }, service.match(clause: "Врт").map { |row| row.fetch("slug") })
  end

  def test_reviewed_word_order_and_inflections_match_the_same_settlement_identity
    @feature["properties"].merge!("name" => "Гај Доњи", "aliases" => ["Gaj Donji"])
    assert_equal 3, service.match(clause: "donji gaj").length
    @feature["properties"].merge!("name" => "Гај Горњи", "aliases" => ["Gaj Gornji"])
    assert_equal 3, service.match(clause: "gornjeg gaja").length
  end

  def test_revision_changes_with_source_dataset_or_current_boundary
    initial = service.revision
    @feature["properties"]["source_snapshot_sha256"] = "new-source"
    assert_operator initial, :!=, service.revision
    source_revision = service.revision
    @areas.first.boundary = { "type" => "Polygon", "coordinates" => [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]] }
    assert_operator source_revision, :!=, service.revision
  end

  def test_stale_geometry_or_boundary_fingerprints_are_not_consumed
    @feature["properties"]["geometry_sha256"] = "stale"
    assert_empty service.match(clause: "vrt")
    @feature["properties"]["geometry_sha256"] = digest(@geometry)
    @data["boundary_sha256"]["komsiluk-one"] = "stale"
    assert_empty service.match(clause: "vrt")
  end

  def test_points_incomplete_and_ambiguous_polygons_are_not_settlement_coverage
    @feature["properties"]["geometry_complete"] = false
    assert_empty service.match(clause: "vrt")
    @feature["properties"]["geometry_complete"] = true
    @data["features"] << @feature.dup
    assert_empty service.match(clause: "vrt")
    @data["features"].pop
    @feature["geometry"] = { "type" => "Point", "coordinates" => [1, 1] }
    assert_empty service.match(clause: "vrt")
  end

  def test_precomputed_foreign_slug_is_never_imported_into_current_tenant
    @feature["properties"]["area_slugs"] << "komsiluk-foreign"
    assert_equal(%w(komsiluk-one komsiluk-two mz-vrt), service.match(clause: "vrt").map { |row| row.fetch("slug") })
  end

  def test_crosswalk_source_span_guards_and_unknown_remainder_are_preserved
    matcher = Object.new
    matcher.define_singleton_method(:resolve) { |**| Struct.new(:status).new(:ok) }
    crosswalk = DecidimApp::Bijeljina::CityServiceAreaCrosswalk.new(organization: nil, matcher:, settlement_coverage: service)
    complete = crosswalk.match(@event)
    assert complete.fetch("complete")
    assert_equal "independent_geometry", complete.fetch("komsiluk_status")
    @event.affected_text = "Naseljena mjesta: Vrt, Nepoznato"
    partial = crosswalk.match(@event)
    assert_equal false, partial.fetch("complete")
    assert_equal 3, partial.fetch("affected_places").length
    assert_equal(["nepoznato"], partial.fetch("unresolved_places").map { |row| row.fetch("evidence") })
    ["TS VRT", "1 NN izlaz", "Ulica Vrt", "Vrt"].each do |text|
      @event.affected_text = text
      assert_nil crosswalk.match(@event)
    end
    @event.affected_text = "Naseljeno mjesto: Vrt"
    @event.content_version = nil
    assert_nil crosswalk.match(@event)
    @event.content_version = "v1"
    @event.source_url = @event.source_url.sub("https", "http")
    assert_nil crosswalk.match(@event)
  end

  private

  def service
    DecidimApp::Bijeljina::CityServiceSettlementCoverage.new(organization: nil, data: @data, areas: @areas)
  end

  def digest(geometry)
    Digest::SHA256.hexdigest("#{geometry.fetch("type")}|#{geometry.fetch("coordinates").to_json}")
  end
end
