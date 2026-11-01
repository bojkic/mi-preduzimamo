# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module DecidimApp
  module Bijeljina
    class GeocoderScopeTest < ActiveSupport::TestCase
      SYNTHETIC_VIEWBOX = "0.05,0.35,0.25,0.05"

      setup do
        @previous_scope = { VIEWBOX: GeocoderScope::VIEWBOX, COUNTRY_CODES: GeocoderScope::COUNTRY_CODES }
        replace_scope(VIEWBOX: SYNTHETIC_VIEWBOX, COUNTRY_CODES: "ba")
        @previous_agent = Decidim::Bih.geocoder_user_agent
        Decidim::Bih.geocoder_user_agent = "AuthoredCommunityTests support@example.invalid"
      end

      teardown do
        replace_scope(@previous_scope)
        Decidim::Bih.geocoder_user_agent = @previous_agent
      end

      test "actual geocoder requests retain user text and restrict search to host geography" do
        stubs = Faraday::Adapter::Test::Stubs.new do |stub|
          stub.get("/search") do |request|
            query = Faraday::Utils.parse_query(request.url.query)
            assert_equal "Izmišljena ulica", query.fetch("q")
            assert_equal "ba", query.fetch("countrycodes")
            assert_equal "address", query.fetch("layer")
            assert_equal GeocoderScope::VIEWBOX, query.fetch("viewbox")
            assert_equal "1", query.fetch("bounded")
            assert_equal "1", query.fetch("limit")
            [200, { "Content-Type" => "application/json" }, '[{"lat":"0.25","lon":"0.15"}]']
          end
        end
        connection = Faraday.new { |builder| builder.adapter :test, stubs }
        Faraday.stub(:new, ->(*) { connection }) do
          assert_equal({ lat: 0.25, lon: 0.15 }, Decidim::Bih::Geo::Geocoder.coordinates("Izmišljena ulica"))
        end
        stubs.verify_stubbed_calls
      end

      test "bounded search encloses all authored MZ and komsiluk vertices" do
        west, north, east, south = GeocoderScope::VIEWBOX.split(",").map(&:to_f)
        outside = %w(postal_areas.geojson postal_komsiluci.geojson).flat_map do |file|
          JSON.parse(Rails.root.join("test/fixtures/files/synthetic", file).read).fetch("features").filter_map do |feature|
            geometry = feature.fetch("geometry")
            points = geometry.fetch("coordinates").flatten(geometry.fetch("type") == "Polygon" ? 1 : 2)
            feature.fetch("properties") unless points.all? { |lon, lat| lon.between?(west, east) && lat.between?(south, north) }
          end
        end
        assert_empty outside
      end
      test "unconfigured scope does not inherit a municipality box or country filter" do
        replace_scope(VIEWBOX: "", COUNTRY_CODES: "ba")
        assert_empty GeocoderScope.query_params
        stubs = Faraday::Adapter::Test::Stubs.new do |stub|
          stub.get("/search") do |request|
            query = Faraday::Utils.parse_query(request.url.query)
            %w(countrycodes viewbox bounded layer).each { |key| assert_not query.key?(key) }
            assert_equal "Izmišljena ulica", query.fetch("q")
            [200, { "Content-Type" => "application/json" }, '[]']
          end
        end
        connection = Faraday.new { |builder| builder.adapter :test, stubs }
        Faraday.stub(:new, ->(*) { connection }) { assert_nil Decidim::Bih::Geo::Geocoder.coordinates("Izmišljena ulica") }
        stubs.verify_stubbed_calls
      end

      test "malformed nonfinite reversed and out-of-range scope fails before provider access" do
        ["0,1,2", "west,north,east,south", "0,Infinity,1,0", "0,1,200,0", "0,91,1,0", "2,1,1,0", "0,0,1,1"].each do |value|
          replace_scope(VIEWBOX: value, COUNTRY_CODES: "ba")
          Faraday.stub(:new, ->(*) { flunk "Invalid scope must not contact provider" }) do
            assert_raises(ArgumentError) { Decidim::Bih::Geo::Geocoder.coordinates("Izmišljena ulica") }
          end
        end
      end

      test "configured scope rejects malformed country filters before provider access" do
        replace_scope(VIEWBOX: SYNTHETIC_VIEWBOX, COUNTRY_CODES: "ba,private-input")
        Faraday.stub(:new, ->(*) { flunk "Invalid countries must not contact provider" }) do
          assert_raises(ArgumentError) { Decidim::Bih::Geo::Geocoder.coordinates("Izmišljena ulica") }
        end
      end

      private

      def replace_scope(values)
        values.each do |key, value|
          GeocoderScope.send(:remove_const, key)
          GeocoderScope.const_set(key, value)
        end
      end
    end
  end
end
