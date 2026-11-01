# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class LocalStreetRegistryTest < ActiveSupport::TestCase
      Area = Struct.new(:slug, :kind, :boundary, keyword_init: true)

      setup do
        @areas = [area("komsiluk-1", 0, 1), area("komsiluk-2", 1, 2)]
        @feature = { "type" => "Feature", "properties" => { "name" => "Test ulica", "settlement" => "Bijeljina", "geometry_complete" => false },
                     "geometry" => { "type" => "LineString", "coordinates" => [[1.0, 0.2], [1.0, 0.8]] } }
        @data = { "features" => [@feature] }
      end

      test "shared boundary street offers both areas without inventing complete coverage or house precision" do
        registry = build_registry
        assert_equal %w(komsiluk-1 komsiluk-2), registry.search(query: "ul. Test ulica, Bijeljina").sole.fetch(:komsiluk_slugs)
        assert_equal false, registry.search(query: "Test ulica").sole.fetch(:complete)
        assert_empty registry.search(query: "Test ulica 12")
        assert_empty registry.search(query: "Test ulica, Janja")
        assert_equal(%w(komsiluk-1 komsiluk-2), registry.coverage(name: "Test ulica", settlement: "Bijeljina").map { |row| row.fetch("slug") })
      end

      test "known trailing country preserves local settlement and unknown qualifiers stay unresolved" do
        registry = build_registry
        expected = registry.search(query: "Test ulica, Bijeljina")
        ["BiH", "Bosna i Hercegovina", "Bosnia and Herzegovina", "Босна и Херцеговина"].each do |country|
          assert_equal expected, registry.search(query: "Test ulica, Bijeljina, #{country}")
        end
        assert_empty registry.search(query: "Test ulica, Bijeljina, Srbija")
        assert_empty registry.search(query: "Test ulica, Unknown place, BiH")
        assert_empty registry.search(query: "Test ulica 12, Bijeljina, BiH")

        second = Marshal.load(Marshal.dump(@feature))
        second["properties"]["settlement"] = "Janja"
        @data["features"] << second
        alternatives = build_registry.search(query: "Test ulica, BiH")
        assert_equal %w(Bijeljina Janja), alternatives.map { |row| row.fetch(:settlement) }.sort
        assert_equal 1, build_registry.search(query: "Test ulica, Janja, Bosnia and Herzegovina").length
      end

      test "precomputed intersections are invalidated when boundaries change" do
        @data["boundary_sha256"] = @areas.to_h do |area|
          [area.slug, Digest::SHA256.hexdigest("#{area.boundary.fetch("type")}|#{area.boundary.fetch("coordinates").to_json}")]
        end
        @feature["properties"]["area_slugs"] = ["komsiluk-1"]
        geometry = @feature.fetch("geometry")
        @feature["properties"]["geometry_sha256"] = Digest::SHA256.hexdigest("#{geometry.fetch("type")}|#{geometry.fetch("coordinates").to_json}")
        assert_equal ["komsiluk-1"], build_registry.search(query: "Test ulica").sole.fetch(:komsiluk_slugs)
        @areas[1].boundary = area("changed", 0.5, 2).boundary
        assert_equal %w(komsiluk-1 komsiluk-2), build_registry.search(query: "Test ulica").sole.fetch(:komsiluk_slugs)
      end

      test "another source refreshed boundary hashes cannot validate stale source intersections" do
        stale = @areas.to_h do |area|
          [area.slug, Digest::SHA256.hexdigest("#{area.boundary.fetch("type")}|#{area.boundary.fetch("coordinates").to_json}")]
        end
        @feature["properties"].merge!("area_slugs" => ["komsiluk-1"], "prepared_boundary_revision" => "older-source")
        geometry = @feature.fetch("geometry")
        @feature["properties"]["geometry_sha256"] = Digest::SHA256.hexdigest("#{geometry.fetch("type")}|#{geometry.fetch("coordinates").to_json}")
        @areas[1].boundary = area("changed", 0.5, 2).boundary
        fresh = @areas.to_h do |area|
          [area.slug, Digest::SHA256.hexdigest("#{area.boundary.fetch("type")}|#{area.boundary.fetch("coordinates").to_json}")]
        end
        @data["boundary_sets"] = { "older-source" => stale, "newer-source" => fresh }
        @data["boundary_sha256"] = fresh
        assert_equal %w(komsiluk-1 komsiluk-2), build_registry.search(query: "Test ulica").sole.fetch(:komsiluk_slugs)

        @data["boundary_sets"]["older-source"] = fresh
        assert_equal ["komsiluk-1"], build_registry.search(query: "Test ulica").sole.fetch(:komsiluk_slugs)
      end

      test "unqualified disconnected homonyms remain choices and do not create whole street notice coverage" do
        @feature["properties"]["settlement"] = nil
        second = Marshal.load(Marshal.dump(@feature))
        second["geometry"]["coordinates"] = [[0.2, 0.2], [0.8, 0.8]]
        @data["features"] << second
        registry = build_registry
        assert_equal 2, registry.search(query: "Test ulica").size
        assert_empty registry.coverage(name: "Test ulica", settlement: "Bijeljina")
      end

      test "complete GIS and verified streets retain distinct footprints while superseding point references in the same locality" do
        @feature["properties"].merge!("geometry_complete" => true, "verified_override" => true)
        @feature["geometry"]["coordinates"] = [[0.2, 0.2], [0.8, 0.8]]
        gis = Marshal.load(Marshal.dump(@feature))
        gis["properties"].delete("verified_override")
        gis["properties"]["municipal_geometry"] = true
        gis["geometry"]["coordinates"] = [[1.2, 0.2], [1.8, 0.8]]
        points = Marshal.load(Marshal.dump(@feature))
        points["properties"]["geometry_complete"] = false
        points["geometry"] = { "type" => "MultiPoint", "coordinates" => [[0.5, 0.5]] }
        @data["features"].push(gis, points)
        registry = build_registry
        assert_equal 2, registry.search(query: "Test ulica, Bijeljina").size
        coverage = registry.coverage(name: "Test ulica", settlement: "Bijeljina")
        assert_equal %w(komsiluk-1 komsiluk-2), coverage.map { |place| place.fetch("slug") }.sort
        assert(coverage.all? { |place| place.fetch("geometry_complete") && place.fetch("relation") == "possible_overlap" })

        gis["properties"]["settlement"] = "Janja"
        assert_empty build_registry.coverage(name: "Test ulica", settlement: nil)
        assert_equal(["komsiluk-1"], build_registry.coverage(name: "Test ulica", settlement: "Bijeljina").map { |place| place.fetch("slug") })
      end

      private

      def build_registry
        LocalStreetRegistry.new(organization: Struct.new(:id).new(42), data: @data, areas: @areas, cache: ActiveSupport::Cache::MemoryStore.new)
      end

      def area(slug, west, east)
        Area.new(slug:, kind: "komsiluk", boundary: { "type" => "Polygon", "coordinates" => [[[west, 0], [east, 0], [east, 1], [west, 1], [west, 0]]] })
      end
    end
  end
end
