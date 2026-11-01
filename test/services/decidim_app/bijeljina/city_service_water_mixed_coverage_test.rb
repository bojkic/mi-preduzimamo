# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_water_geometry"

module DecidimApp
  module Bijeljina
    class CityServiceWaterMixedCoverageTest < ActiveSupport::TestCase
      include SyntheticWaterGeometry
      Event = Struct.new(:decidim_organization_id, :source_key, :source_url, :content_version, :extraction_metadata, keyword_init: true)
      URL = "https://www.bnvodovod.com/v2/vodosnabdijevanje-authored-notice/"
      CLAUSES = ["Izmišljeni jasen (Izmišljeni grad)", "Izmišljena vrba (Izmišljeni grad)", "Izmišljeni bagrem (Izmišljeni grad)",
                 "Neznani rub (Testna dolina)", "Gaj (Gaj)"].freeze

      setup do
        @organization = Struct.new(:id).new(23)
        @street = Object.new
        @street.define_singleton_method(:revision) { "street-v1" }
        @settlements = Object.new
        @settlements.define_singleton_method(:revision) { "settlement-v1" }
        @settlements.define_singleton_method(:match) do |clause:|
          next [] unless %w(gaj vrt lug).include?(Decidim::Bih::Text.fold(clause))

          [{ "kind" => "komsiluk", "slug" => "komsiluk-#{clause}", "source" => "municipal_settlement_geometry" }]
        end
      end

      test "every mixed clause has verified evidence before complete board mapping" do
        @street.define_singleton_method(:match) do |view|
          { "complete" => true, "affected_places" => [{ "kind" => "komsiluk", "slug" => "komsiluk-#{view.affected_text}",
                                                        "source" => "full_named_street_geometry" }] }
        end
        result = resolver.match(event)
        assert_equal true, result.fetch("complete")
        assert_equal 5, result.fetch("clause_count")
        assert_equal 5, result.fetch("resolved_clause_count")
        assert_equal 0, result.fetch("unresolved_clause_count")
        assert_equal 5, result.fetch("affected_places").size
        assert_equal "unspecified_street_segment", result.fetch("scope_precision")
        assert_equal "verified_full_geometry_intersection", result.fetch("board_placement")
        assert(result.fetch("clauses").all? { |row| row.fetch("board_slugs").one? })
      end

      test "a named city street can touch two boards without claiming the whole street is affected" do
        @street.define_singleton_method(:match) do |_view|
          { "complete" => true, "affected_places" => %w(left right).map do |side|
            { "kind" => "komsiluk", "slug" => "komsiluk-#{side}", "source" => "full_named_street_geometry" }
          end }
        end
        result = resolver.match(event(["Izmišljena lipa (Izmišljeni grad)"]))
        assert_equal "resolved", result.fetch("status")
        assert_equal %w(komsiluk-left komsiluk-right), result.fetch("clauses").sole.fetch("board_slugs")
        assert_equal "unspecified_street_segment", result.fetch("scope_precision")
      end

      test "unknown settlement part does not inherit the settlement footprint" do
        @street.define_singleton_method(:match) { |_view| nil }
        @settlements.define_singleton_method(:match) { |clause:| raise "must not widen #{clause}" }
        result = resolver.match(event(["Neznani rub (Testna dolina)"]))
        assert_equal false, result.fetch("complete")
        assert_empty result.fetch("affected_places")
        assert_equal "full_street_geometry_not_verified", result.fetch("unresolved_places").sole.fetch("reason")
        assert_equal "review_required", result.fetch("board_placement")
      end

      test "Nova Luka streets use street geometry without widening to Nova Luka settlement" do
        @street.define_singleton_method(:match) do |_view|
          { "complete" => true, "affected_places" => [{ "kind" => "komsiluk", "slug" => "komsiluk-c" }] }
        end
        @settlements.define_singleton_method(:match) { |clause:| raise "must not widen #{clause}" }
        result = resolver.match(event(["Измишљени јавор (Нова Лука)", "Измишљени храст (Нова Лука)"]))
        assert_equal true, result.fetch("complete")
        assert_equal ["komsiluk-c"], result.fetch("affected_places").pluck("slug")
        assert(result.fetch("clauses").all? { |row| row["kind"] == "street" })
      end

      test "explicit standalone settlements resolve alongside a street" do
        @street.define_singleton_method(:match) do |_view|
          { "complete" => true, "affected_places" => [{ "kind" => "komsiluk", "slug" => "komsiluk-c" }] }
        end
        result = resolver.match(event(["Измишљени јавор (Нова Лука)", "Врт", "Луг"]))
        assert_equal true, result.fetch("complete")
        assert_equal %w(street settlement settlement), result.fetch("clauses").pluck("kind")
      end

      test "qualified settlement part and malformed parentheses do not become whole settlements" do
        result = resolver.match(event(["dio Patkovače", "Nova Luka (", "nepoznato"]))
        assert_equal false, result.fetch("complete")
        assert_equal 3, result.fetch("unresolved_clause_count")
        assert_empty result.fetch("affected_places")
      end

      test "one unmapped city street retains all other evidence but blocks complete mapping" do
        @street.define_singleton_method(:match) do |view|
          next if view.affected_text.start_with?("Izmišljeni jasen")

          { "complete" => true, "affected_places" => [{ "kind" => "komsiluk", "slug" => "komsiluk-#{view.affected_text}",
                                                        "source" => "full_named_street_geometry" }] }
        end
        result = resolver.match(event)
        assert_equal false, result.fetch("complete")
        assert_equal "partial", result.fetch("status")
        assert_equal 4, result.fetch("resolved_clause_count")
        assert_equal "Izmišljeni jasen (Izmišljeni grad)", result.fetch("unresolved_places").sole.fetch("evidence")
        assert_equal "review_required", result.fetch("board_placement")
      end

      test "malformed clause remains unresolved even beside a mapped street" do
        @street.define_singleton_method(:match) do |_view|
          { "complete" => true, "affected_places" => [{ "kind" => "komsiluk", "slug" => "komsiluk-left" }] }
        end
        result = resolver.match(event(["Izmišljena lipa (Izmišljeni grad)", "nejasna lokacija"]))
        assert_equal 2, result.fetch("clause_count")
        assert_equal 1, result.fetch("unresolved_clause_count")
        assert_equal "review_required", result.fetch("board_placement")
      end

      test "authored mixed notices resolve against independent street and board geometry" do
        area_class = Struct.new(:slug, :kind, :boundary)
        areas = authored_water_areas(area_class)
        empty = { "features" => [], "boundary_sets" => {} }
        registry = LocalStreetRegistry.new(organization: @organization, data: empty, areas:, cache: ActiveSupport::Cache::MemoryStore.new)
        LocalStreetRegistry.stub(:dataset, empty) do
          LocalStreetRegistry.stub(:new, registry) do
            settlements = CityServiceSettlementCoverage.new(organization: @organization, data: authored_water_settlements(areas), areas:)
            matcher = CityServiceWaterMixedCoverage.new(organization: @organization,
              street_coverage: CityServiceStreetCoverage.new(organization: @organization, data: authored_water_streets, areas:, municipal_data: {}),
              settlement_coverage: settlements)

            # The parent settlement truly includes five extra boards; street
            # clauses must keep their narrow full-line intersections instead.
            parent = settlements.match(clause: "Nova Luka").select { |row| row["kind"] == "komsiluk" }.pluck("slug").sort
            assert_equal %w(komsiluk-b komsiluk-c komsiluk-d komsiluk-e komsiluk-f komsiluk-g komsiluk-h), parent
            current = matcher.match(event(["Измишљена липа (Измишљени град)", "Измишљена бреза (Нова Лука)", "Измишљени јавор (Нова Лука)", "Измишљени храст (Нова Лука)"]))
            assert_equal true, current.fetch("complete")
            assert_equal %w(komsiluk-a komsiluk-b komsiluk-c), board_slugs(current)
            assert_equal %w(komsiluk-b komsiluk-c), current.fetch("clauses")[1].fetch("board_slugs")
            assert_equal ["komsiluk-c"], current.fetch("clauses")[2].fetch("board_slugs")

            # A separately named whole settlement uses its own prepared polygon.
            first = matcher.match(event(["Измишљени бор (Измишљени град)", "Измишљена буква (Нова Лука)", "Врт"]))
            assert_equal true, first.fetch("complete")
            assert_equal "settlement", first.fetch("clauses").last.fetch("kind")

            # Unknown street geometry never borrows the larger parent polygon.
            second = matcher.match(event(["Непотврђена улица (Нова Лука)", "Измишљена буква (Нова Лука)", "Измишљени јавор (Нова Лука)", "Врт", "Луг"]))
            assert_equal false, second.fetch("complete")
            assert_equal ["Непотврђена улица (Нова Лука)"], second.fetch("unresolved_places").pluck("evidence")
            assert_equal "review_required", second.fetch("board_placement")

            # A named part remains unresolved beside an explicit whole settlement.
            part = matcher.match(event(["Незнани руб (Тестна долина)", "Гај (Гај)"]))
            assert_equal false, part.fetch("complete")
            assert_equal ["Незнани руб (Тестна долина)"], part.fetch("unresolved_places").pluck("evidence")
            assert_equal "settlement", part.fetch("clauses").last.fetch("kind")
          end
        end
      end

      private

      def board_slugs(coverage)
        coverage.fetch("affected_places").select { |place| place["kind"] == "komsiluk" }.pluck("slug").uniq.sort
      end

      def resolver
        CityServiceWaterMixedCoverage.new(organization: @organization, street_coverage: @street, settlement_coverage: @settlements)
      end

      def event(clauses = CLAUSES)
        Event.new(decidim_organization_id: @organization.id, source_key: "water_service", source_url: URL, content_version: "v1",
                  extraction_metadata: { "source_snapshot_complete" => true, "canonical_article_url" => URL,
                                         "coverage" => { "clauses" => clauses.map { |clause| { "evidence" => clause } } } })
      end
    end
  end
end
