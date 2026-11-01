# frozen_string_literal: true

require "test_helper"
require "json"

module DecidimApp
  module Bijeljina
    class LocalAreaGeojsonTest < ActiveSupport::TestCase
      GEOJSON_PATH = Rails.root.join("test/fixtures/files/synthetic/local_areas.geojson")

      test "authored MZ GeoJSON has complete unique MZ feature coverage" do
        features = mz_features

        assert_equal 3, features.size
        assert_equal 3, features.map { |feature| feature.dig("properties", "slug") }.uniq.size
        assert_equal 3, features.map { |feature| feature.dig("properties", "name", "bs") }.uniq.size
      end

      test "authored MZ contact completeness preserves the explicit missing-contact row" do
        features = mz_features

        assert_equal ["mz-primjer-rub"], missing_president_slugs(features)
        assert_equal ["mz-primjer-rub"], missing_phone_slugs(features)
        assert_equal ["mz-primjer-rub"], missing_contact_slugs(features)

        centar = feature_by_slug(features, "mz-primjer-centar")
        assert_equal "IZMIŠLJENA OSOBA A", centar.dig("properties", "predsjednik")
        assert_equal "TEST-NOT-A-PHONE-A", centar.dig("properties", "telefon")

        filip = feature_by_slug(features, "mz-primjer-park")
        assert_equal "IZMIŠLJENA OSOBA B", filip.dig("properties", "predsjednik")
        assert_equal "TEST-NOT-A-PHONE-B", filip.dig("properties", "telefon")
      end

      private

      def mz_features
        JSON.parse(File.read(GEOJSON_PATH)).fetch("features")
            .select { |feature| feature.dig("properties", "kind") == "mz" }
      end

      def missing_president_slugs(features)
        features.select { |feature| feature.dig("properties", "predsjednik").to_s.strip.empty? }
                .map { |feature| feature.dig("properties", "slug") }
                .sort
      end

      def missing_phone_slugs(features)
        features.select { |feature| feature.dig("properties", "telefon").to_s.strip.empty? }
                .map { |feature| feature.dig("properties", "slug") }
                .sort
      end

      def missing_contact_slugs(features)
        missing = features.select do |feature|
          feature.dig("properties", "predsjednik").to_s.strip.empty? &&
            feature.dig("properties", "telefon").to_s.strip.empty?
        end

        missing.map { |feature| feature.dig("properties", "slug") }.sort
      end

      def feature_by_slug(features, slug)
        features.find { |feature| feature.dig("properties", "slug") == slug }
      end
    end
  end
end
