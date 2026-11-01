# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_preparation_geography"

module DecidimApp
  module Bijeljina
    class CityServiceStationPlaceTest < ActiveSupport::TestCase
      include SyntheticPreparationGeography
      setup do
        install_synthetic_preparation_geography
        @organization = create_organization
        @areas = {
          "Jasen" => "komsiluk-jasen",
          "Gaj Donje" => "komsiluk-gaj-donje",
          "Gaj Gornje" => "komsiluk-gaj-gornje",
          "Veliki Park" => "komsiluk-veliki-park",
          "Lipa" => "komsiluk-lipa",
          "Breza" => "komsiluk-breza"
        }
        @areas.each do |name, slug|
          Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug:, name: { "sr" => name })
        end
        @resolver = CityServiceStationPlace.new(organization: @organization)
      end

      teardown do
        restore_synthetic_preparation_geography
      end

      test "a unique station locality places a generic output without claiming a household footprint" do
        resolved = @resolver.resolve(event("TS 10/0,4 kV G. Jasen 2"))
        assert resolved.resolved?
        assert_equal "komsiluk-jasen", resolved.slug
        assert_equal "Jasen", resolved.name
        assert_equal "TS 10/0,4 kV G. Jasen 2", resolved.station_label
        assert resolved.boundary_hash.present?
      end

      test "reviewed abbreviation variants resolve only one qualified locality" do
        assert_equal "komsiluk-gaj-donje", @resolver.resolve(event("TS D.GAJ 2")).slug
        assert_equal "komsiluk-gaj-donje", @resolver.resolve(event("TS D.GAJ 2 CENTAR")).slug
        assert_equal "komsiluk-gaj-gornje", @resolver.resolve(event("TS G. GAJ 2")).slug
        assert_equal "komsiluk-veliki-park", @resolver.resolve(event("TS V. PARK RUB 2")).slug
      end

      test "competing localities and unknown city station stay unresolved" do
        conflict = @resolver.resolve(event("TS JASEN BREZA 3"))
        assert_equal "ambiguous", conflict.status
        assert_equal %w(komsiluk-breza komsiluk-jasen), conflict.candidate_slugs
        assert_equal "unknown", @resolver.resolve(event("TS SP 3")).status
      end

      test "an unreviewed suffix cannot borrow an exact station place" do
        assert_equal "unknown", @resolver.resolve(event("TS JASEN NEPOZNATA 2")).status
        assert_equal "unknown", @resolver.resolve(event("TS V. PARK NOVA ZONA 2")).status
        assert_equal "unknown", @resolver.resolve(event("TS JASEN CENTAR 2")).status
      end

      test "a named street or a district feeder cannot borrow station placement" do
        assert_equal "not_applicable", @resolver.resolve(event("TS G. JASEN 2", affected: "1 NN izlaz za ul. Izmišljene lipe")).status
        assert_equal "unknown", @resolver.resolve(event("DV 10KV JASEN")).status
      end

      test "station suffix data has no inherited default and missing configured files fail" do
        assert_empty CityServiceStationPlace.load_reviewed_station_labels("")
        assert_raises(Errno::ENOENT) do
          CityServiceStationPlace.load_reviewed_station_labels(File.join(@authored_prep_root, "missing.yml"))
        end
      end

      test "station label loader rejects malformed ambiguous and unbounded mappings" do
        invalid = [ { "labels" => [] }, { "labels" => { "key" => 12 } },
          { "labels" => { "V. Park" => "Veliki Park", "v park" => "Drugi Park" } },
          { "labels" => { "  " => "Veliki Park" } }, { "labels" => { "valid" => "!" } } ]
        invalid.each_with_index do |data, index|
          path = File.join(@authored_prep_root, "invalid-#{index}.yml")
          File.write(path, YAML.dump(data))
          assert_raises(ArgumentError) { CityServiceStationPlace.load_reviewed_station_labels(path) }
        end
      end

      test "station label loader bounds the file before parsing" do
        path = File.join(@authored_prep_root, "oversized.yml")
        File.write(path, "x" * 1_048_577)
        assert_raises(ArgumentError) { CityServiceStationPlace.load_reviewed_station_labels(path) }
      end

      test "reviewed mapping changes invalidate the rule revision independent of key order" do
        first = { "v park rub" => "veliki park", "j lipa" => "lipa" }
        second = first.to_a.reverse.to_h
        assert_equal CityServiceStationPlace.reviewed_labels_version(first), CityServiceStationPlace.reviewed_labels_version(second)
        second["v park rub"] = "drugi park"
        assert_not_equal CityServiceStationPlace.reviewed_labels_version(first), CityServiceStationPlace.reviewed_labels_version(second)
      end

      private

      def event(feeder, affected: "1 NN izlaz")
        CityServiceEvent.new(organization: @organization, source_key: "electricity_outages", targeting_level: "unknown",
                             affected_area_slugs: [], affected_text: affected,
                             extraction_metadata: { "feeder" => feeder,
                                                    "coverage" => { "status" => "unknown", "affected_places" => [],
                                                                    "ambiguous_places" => [], "unresolved_places" => [] } })
      end
    end
  end
end
