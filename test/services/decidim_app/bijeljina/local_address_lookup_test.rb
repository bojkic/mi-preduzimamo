# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module DecidimApp
  module Bijeljina
    class LocalAddressLookupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @mz = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-dvorovi", name: { "sr" => "Dvorovi" })
        @areas = %w(left right).map do |side|
          Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-#{side}", name: { "sr" => side }, overlapping_mz_slugs: [@mz.slug])
        end
      end

      test "typed MZ names offer every verified overlapping komsiluk without home coordinates" do
        result = LocalAddressLookup.new(organization: @organization).call(query: "MZ Dvorovi")
        assert_equal @areas.map(&:id).sort, result.map { |row| row.fetch(:komsiluk_id) }.sort
        assert(result.all? { |row| row.fetch(:source) == "local_area" && !row.has_key?(:lat) })
      end

      test "area substring in a numbered street is not treated as an exact local area" do
        registry = Object.new
        registry.define_singleton_method(:search) do |query:|
          raise unless query == "Dvorovi 12"

          []
        end
        registry.define_singleton_method(:place_search) { |**| [] }
        LocalStreetRegistry.stub(:new, registry) do
          assert_empty LocalAddressLookup.new(organization: @organization).call(query: "Dvorovi 12")
        end
      end

      test "partial street geometry and local place points require a map choice" do
        @areas.first.update!(boundary: { "type" => "Polygon", "coordinates" => [[[19.21, 44.75], [19.22, 44.75], [19.22, 44.76], [19.21, 44.76], [19.21, 44.75]]] })
        registry = Object.new
        registry.define_singleton_method(:search) do |query:|
          query == "Glavna" ? [{ name: "Glavna", complete: false, lat: 44.758, lon: 19.215 }] : []
        end
        registry.define_singleton_method(:place_search) do |**|
          [{ label: "Hamlet", lat: 44.758, lon: 19.215, precision: "place", source: "local_place" },
           { label: "Outside", lat: 0, lon: 0, precision: "place", source: "local_place" }]
        end
        LocalStreetRegistry.stub(:new, registry) do
          lookup = LocalAddressLookup.new(organization: @organization)
          street = lookup.call(query: "Glavna")
          assert_equal "street_segment", street.first.fetch(:precision)
          assert street.first.fetch(:requires_map_confirmation)
          places = lookup.call(query: "Hamlet")
          assert_equal 1, places.length
          assert_equal "place", places.first.fetch(:precision)
          assert places.first.fetch(:requires_map_confirmation)
        end
      end

      test "verified street offers all current tenant komsiluci and ignores foreign slugs" do
        registry = Object.new
        registry.define_singleton_method(:search) do |query:|
          [{ name: query, settlement: "Bijeljina", complete: true, komsiluk_slugs: %w(komsiluk-left komsiluk-right komsiluk-foreign) }]
        end
        LocalStreetRegistry.stub(:new, registry) do
          result = LocalAddressLookup.new(organization: @organization).call(query: "Glavna")
          assert_equal @areas.map(&:id).sort, result.map { |row| row.fetch(:komsiluk_id) }.sort
          assert(result.all? { |row| row.fetch(:source) == "local_street" && !row.has_key?(:lat) })
        end
      end
    end
  end
end
