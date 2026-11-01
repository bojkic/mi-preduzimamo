# frozen_string_literal: true

# Standalone contract: no Rails boot, database, cache or provider calls.
gem "minitest", "~> 5.0"
require "active_support"
require "minitest/autorun"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/hash/except"
require "active_support/core_ext/hash/slice"
milica_engine_root = ENV["MILICA_ENGINE_ROOT"] || Gem.loaded_specs.fetch("decidim-bih").full_gem_path
$LOAD_PATH.unshift(File.join(milica_engine_root, "lib"))
require File.join(milica_engine_root, "app/services/decidim/bih/text")
require_relative "../../app/services/decidim_app/bijeljina/city_service_settlement_coverage"
require_relative "../../app/services/decidim_app/bijeljina/city_service_water_settlement_coverage"
require_relative "../../app/services/decidim_app/bijeljina/city_service_street_coverage"
require_relative "../../app/services/decidim_app/bijeljina/city_service_area_preparation"
require_relative "../../app/services/decidim_app/bijeljina/city_service_place_context"

class MilicaWaterSettlementCoverageTest < Minitest::Test
  Area = Struct.new(:slug, :kind, :boundary)
  Event = Struct.new(:source_key, :source_url, :extraction_metadata, :affected_text, :content_version,
                     :decidim_organization_id, :state, :targeting_level, :affected_area_slugs, :reviewed_at, :reviewed_by_id,
                     :starts_at, :ends_at,
                     keyword_init: true) do
    def pending_review? = state == "pending_review"

    def area_slugs = affected_area_slugs

    def with_lock = yield

    def update!(changes) = changes.each { |key, value| public_send("#{key}=", value) }
  end

  URL = "https://www.bnvodovod.com/v2/vodosnabdijevanje-za-10-septembar-2026-god-2/"

  def setup
    @organization = Struct.new(:id).new(1)
    geometry = { "type" => "Polygon", "coordinates" => [[[0, 0], [2, 0], [2, 2], [0, 2], [0, 0]]] }
    @areas = [Area.new("komsiluk-one", "komsiluk", geometry), Area.new("mz-balatun", "mz", geometry)]
    @data = { "boundary_sha256" => @areas.to_h { |area| [area.slug, digest(area.boundary)] }, "features" => [] }
    %w(Balatun Trnjaci Međaši).each_with_index do |name, index|
      @data["features"] << { "geometry" => geometry, "properties" => {
        "name" => name, "place_type" => "settlement", "geometry_complete" => true,
        "geometry_sha256" => digest(geometry), "area_slugs" => @areas.map(&:slug),
        "source_url" => "https://gis.gradbijeljina.org/wms/", "source_settlement_id" => index.to_s,
        "source_snapshot_sha256" => "reviewed-public-GIS", "retrieved_at" => "2026-09-09"
      } }
    end
    @event = Event.new(source_key: "water_service", source_url: URL, content_version: "v1", decidim_organization_id: 1,
                       state: "pending_review", targeting_level: "unknown", affected_area_slugs: [],
                       starts_at: Time.utc(2026, 9, 10, 6), ends_at: Time.utc(2026, 9, 10, 12, 30),
                       affected_text: "Балатун (Балатун); Трњаци (Трњаци); Међаши (Међаши)",
                       extraction_metadata: { "source_snapshot_complete" => true, "canonical_article_url" => URL })
  end

  def test_official_repeated_settlement_bullets_map_independent_polygons_as_possible_overlap_only
    coverage = service.match(@event)
    assert coverage.fetch("complete")
    assert_equal "source_named_settlement_list", coverage.fetch("scope")
    assert_equal "possible_settlement_overlap", coverage.fetch("scope_precision")
    assert_equal "v1", coverage.fetch("source_content_version")
    places = coverage.fetch("affected_places")
    assert_equal 6, places.length
    assert_equal %w(komsiluk mz), places.map { |place| place.fetch("kind") }.uniq.sort
    assert_equal ["possible_overlap"], places.map { |place| place.fetch("relation") }.uniq
    assert_equal ["explicit_affected_location"], places.map { |place| place.fetch("evidence_role") }.uniq
    assert_equal [URL], places.map { |place| place.fetch("provider_source_url") }.uniq
    assert_equal ["reviewed-public-GIS"], places.map { |place| place.fetch("source_snapshot_sha256") }.uniq
    assert_empty coverage.fetch("notification_candidates")
    assert DecidimApp::Bijeljina::CityServicePlaceContext.partial_coverage?(coverage)
    assert DecidimApp::Bijeljina::CityServicePlaceContext.overlap_only?(coverage, ["komsiluk-one"])
    assert_equal "pending_review", @event.state
    assert_empty @event.affected_area_slugs
  end

  def test_unmapped_remainder_keeps_partial_coverage_and_never_claims_complete_area
    @event.affected_text = "Balatun (Balatun); Nepoznato (Nepoznato)"
    coverage = service.match(@event)
    assert_equal false, coverage.fetch("complete")
    assert_equal "partial", coverage.fetch("status")
    assert_equal 2, coverage.fetch("affected_places").size
    assert_equal(["Nepoznato (Nepoznato)"], coverage.fetch("unresolved_places").map { |place| place.fetch("evidence") })
  end

  def test_parenthetical_municipality_streets_equipment_worksites_and_mixed_lists_do_not_become_settlement_coverage
    ["Karađorđeva (Dvorovi)", "Ulica Balatun (Balatun)", "TS BALATUN (BALATUN)",
     "Balatun", "Balatun (Bijeljina)", "Dio Balatuna (Balatun)", "Balatun 12 (Balatun 12)",
     "Balatun (Balatun); Karađorđeva (Dvorovi)", "Radovi u Balatunu (Balatun)",
     "Na ostalim lokacijama u Balatunu uredno"].each do |text|
      @event.affected_text = text
      assert_nil service.match(@event), text
    end
  end

  def test_foreign_tenant_incomplete_unversioned_or_noncanonical_source_fails_closed
    @event.decidim_organization_id = 2
    assert_nil service.match(@event)
    @event.decidim_organization_id = 1
    @event.content_version = nil
    assert_nil service.match(@event)
    @event.content_version = "v1"
    @event.extraction_metadata["source_snapshot_complete"] = false
    assert_nil service.match(@event)
    @event.extraction_metadata["source_snapshot_complete"] = true
    @event.extraction_metadata.delete("canonical_article_url")
    assert_nil service.match(@event)
    [URL.sub("https", "http"), URL.sub(".com/", ".com:444/"), URL.sub("https://", "https://person@"),
     URL.sub("www.bnvodovod.com", "unrelated.example"), URL.sub("/v2/", "/other/")].each do |url|
      @event.source_url = url
      @event.extraction_metadata["canonical_article_url"] = url
      assert_nil service.match(@event), url
    end
  end

  def test_stale_boundary_incomplete_or_competing_polygons_are_not_consumed
    @data["boundary_sha256"][@areas.first.slug] = "stale"
    assert_nil service.match(@event)
    @data["boundary_sha256"][@areas.first.slug] = digest(@areas.first.boundary)
    @data["features"].each { |feature| feature["properties"]["geometry_complete"] = false }
    assert_nil service.match(@event)
    @data["features"].each { |feature| feature["properties"]["geometry_complete"] = true }
    @data["features"] += @data["features"].map(&:dup)
    assert_nil service.match(@event)
  end

  def test_same_named_settlement_is_not_resolved_as_a_street_and_mixed_list_keeps_unknown_clause
    street = DecidimApp::Bijeljina::CityServiceStreetCoverage.allocate
    street.define_singleton_method(:resolve_street) do |name, _settlement|
      raise "settlement sent to street resolver" if name == "balatun"

      [{ "slug" => "komsiluk-street", "kind" => "komsiluk", "geometry_complete" => true }]
    end
    places, unresolved = street.send(:collected_places, [%w(balatun balatun), %w(karadjordjeva dvorovi)], water: true)
    assert_equal(["komsiluk-street"], places.map { |place| place.fetch("slug") })
    assert_equal(["balatun, balatun"], unresolved.map { |place| place.fetch("evidence") })
  end

  def test_preparation_records_relevance_without_approval_and_revision_refresh_clears_stale_mapping
    preparer = preparation(service)
    assert preparer.send(:apply_water_settlement_coverage, @event)
    assert_equal "komsiluk", @event.targeting_level
    assert_equal ["komsiluk-one"], @event.affected_area_slugs
    assert_equal "municipal_settlement_geometry", @event.extraction_metadata.dig("confidence_by_field", "place")
    assert_equal "pending_review", @event.state
    assert_nil @event.reviewed_at
    assert_nil @event.reviewed_by_id
    assert_equal false, preparer.send(:refresh_water_settlement_mapping, @event)

    @data["features"] = []
    preparer = preparation(service)
    assert preparer.send(:refresh_water_settlement_mapping, @event)
    assert_equal "unknown", @event.targeting_level
    assert_empty @event.affected_area_slugs
    assert_equal false, @event.extraction_metadata.dig("coverage", "complete")
    assert_equal "settlement_or_boundary_revision_changed", @event.extraction_metadata.dig("coverage", "reason")
  end

  def test_preparation_entry_point_uses_settlements_before_streets_without_changing_source_or_time
    preparer = preparation(service)
    preparer.define_singleton_method(:apply_reviewed_mapping) { |_| false }
    preparer.define_singleton_method(:apply_street_coverage) { |_| raise "explicit settlement list reached street fallback" }
    original = @event.to_h.values_at(:source_url, :content_version, :affected_text, :starts_at, :ends_at)
    preparer.call(events: [@event])
    assert_equal "komsiluk", @event.targeting_level
    assert_equal "pending_review", @event.state
    assert_equal "source_named_settlement_list", @event.extraction_metadata.dig("coverage", "scope")
    assert_equal original, @event.to_h.values_at(:source_url, :content_version, :affected_text, :starts_at, :ends_at)
  end

  def test_partial_mapping_keeps_target_unknown_and_reviewed_dismissed_and_foreign_events_remain_untouched
    @event.affected_text = "Balatun (Balatun); Nepoznato (Nepoznato)"
    preparer = preparation(service)
    assert_equal false, preparer.send(:apply_water_settlement_coverage, @event)
    assert_equal "unknown", @event.targeting_level
    assert_equal "unknown", @event.extraction_metadata.dig("confidence_by_field", "place")
    assert_empty @event.affected_area_slugs

    @event.state = "dismissed"
    original = Marshal.dump(@event)
    assert_equal false, preparer.send(:apply_water_settlement_coverage, @event)
    preparer.call(events: [@event])
    assert_equal original, Marshal.dump(@event)
    @event.state = "pending_review"
    @event.reviewed_by_id = 23
    original = Marshal.dump(@event)
    preparer.define_singleton_method(:prepare_place_context) { |_| nil }
    preparer.call(events: [@event])
    assert_equal original, Marshal.dump(@event)
    @event.reviewed_by_id = nil
    @event.decidim_organization_id = 2
    original = Marshal.dump(@event)
    preparer.call(events: [@event])
    assert_equal original, Marshal.dump(@event)
  end

  private

  def service
    polygons = DecidimApp::Bijeljina::CityServiceSettlementCoverage.new(organization: @organization, data: @data, areas: @areas)
    DecidimApp::Bijeljina::CityServiceWaterSettlementCoverage.new(organization: @organization, settlement_coverage: polygons)
  end

  def preparation(coverage)
    DecidimApp::Bijeljina::CityServiceAreaPreparation.allocate.tap do |preparer|
      preparer.instance_variable_set(:@organization, @organization)
      preparer.instance_variable_set(:@water_settlement_coverage, coverage)
    end
  end

  def digest(geometry)
    Digest::SHA256.hexdigest("#{geometry.fetch("type")}|#{geometry.fetch("coordinates").to_json}")
  end
end
