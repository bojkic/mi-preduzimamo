# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_preparation_geography"

module DecidimApp
  module Bijeljina
    class CityServiceAreaPreparationTest < ActiveSupport::TestCase
      include SyntheticPreparationGeography
      setup do
        install_synthetic_preparation_geography
        @organization = create_organization
        %w(mz komsiluk).each do |kind|
          Decidim::Bih::LocalArea.create!(organization: @organization, kind:, slug: "#{kind}-lugovi", name: { "sr" => "Lugovi" })
        end
        @event = CityServiceEvent.create!(organization: @organization, source_key: "electricity_outages", source_fingerprint: "place-preparation",
                                          content_version: "v1", parser_version: "test", event_type: "planned_outage", severity: "service_outage",
                                          title: "Test", summary: "Public test notice", affected_text: "Lugovi", targeting_level: "unknown")
        @cache = ActiveSupport::Cache::MemoryStore.new
        @preparer = CityServiceAreaPreparation.new(organization: @organization, cache: @cache)
      end

      teardown do
        restore_synthetic_preparation_geography
      end

      test "a unique station places a generic output on one board with partial-area copy" do
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-gaj",
                                       name: { "sr" => "Gaj" })
        @event.update!(affected_text: "1 NN izlaz", starts_at: 2.hours.from_now, ends_at: 5.hours.from_now,
                       extraction_metadata: { "feeder" => "TS G. GAJ 2", "source_snapshot_complete" => true,
                                              "coverage" => { "status" => "unknown", "affected_places" => [],
                                                              "unresolved_places" => [], "ambiguous_places" => [] } })

        @preparer.call(events: [@event])
        @event.reload

        assert_equal ["komsiluk-gaj"], @event.area_slugs
        assert_equal ["komsiluk-gaj"], CityServiceEventPreview.new(@event).call.target_komsiluk_slugs
        assert_equal "part_of_area", @event.extraction_metadata.dig("coverage", "scope_precision")
        assert_equal "provider_station_name", @event.extraction_metadata.dig("confidence_by_field", "place")
        assert_includes @event.summary, "dio komšiluka Gaj"
        assert_includes @event.viber_text, "dio komšiluka Gaj"
        refute_includes CityServiceAutomation.new(organization: @organization).blockers(@event), "coverage_requires_review"
      end

      test "mixed water list cannot be promoted by a resolver that ignores unresolved clauses" do
        @event.update!(source_key: "water_service", source_url: "https://www.bnvodovod.com/v2/vodosnabdijevanje-authored-notice/",
                       affected_text: "Izmišljeni javor (Bijeljina); Neznani rub (Testna dolina)",
                       extraction_metadata: { "source_snapshot_complete" => true,
                                              "coverage" => { "status" => "partial", "clause_count" => 2, "unresolved_clause_count" => 1 } })
        @preparer.call(events: [@event])
        @event.reload
        assert_equal "unknown", @event.targeting_level
        assert_empty @event.affected_area_slugs
        assert_equal 1, @event.extraction_metadata.dig("coverage", "unresolved_clause_count")
      end

      test "fully resolved water clauses can promote one combined board destination" do
        @event.update!(source_key: "water_service", source_url: "https://www.bnvodovod.com/v2/vodosnabdijevanje-authored-notice/",
                       affected_text: "Lugovi (Lugovi); Lugovi (Lugovi)",
                       extraction_metadata: { "source_snapshot_complete" => true, "coverage" => { "status" => "resolved",
                                              "clauses" => [{ "evidence" => "Lugovi (Lugovi)" }, { "evidence" => "Lugovi (Lugovi)" }] } })
        mixed = Object.new
        mixed.define_singleton_method(:revision) { "mixed-v1" }
        mixed.define_singleton_method(:match) do |event|
          { "complete" => true, "status" => "resolved", "source_content_version" => event.content_version,
            "water_mixed_coverage_revision" => "mixed-v1", "scope_precision" => "named_settlement_overlap",
            "affected_places" => [{ "slug" => "mz-lugovi", "kind" => "mz", "relation" => "possible_overlap",
                                      "source" => "municipal_settlement_geometry" }],
            "unresolved_places" => [], "ambiguous_places" => [] }
        end
        @preparer.instance_variable_set(:@water_mixed_coverage, mixed)
        @preparer.call(events: [@event])
        @event.reload
        assert_equal "mz", @event.targeting_level
        assert_equal ["mz-lugovi"], @event.area_slugs
        assert_equal "municipal_settlement_geometry", @event.extraction_metadata.dig("confidence_by_field", "place")
      end

      test "mapped mixed water clauses qualify board copy without widening phone scope" do
        url = "https://www.bnvodovod.com/v2/vodosnabdijevanje-authored-notice/"
        original = { "title" => "Prekid vode: Komitska", "summary" => "Komitska (Bijeljina); Neznani rub (Testna dolina)",
                     "viber_text" => "Komitska (Bijeljina); Neznani rub (Testna dolina)" }
        @event.update!(source_key: "water_service", source_url: url, affected_text: original.fetch("summary"),
                       title: original.fetch("title"), summary: original.fetch("summary"), viber_text: original.fetch("viber_text"),
                       extraction_metadata: { "source_snapshot_complete" => true, "canonical_article_url" => url,
                                              "coverage" => { "clauses" => original.fetch("summary").split("; ").map { |text| { "evidence" => text } } } })
        revision = CityServiceWaterMixedCoverage.new(organization: @organization).revision
        mixed = Object.new
        mixed.define_singleton_method(:revision) { revision }
        mixed.define_singleton_method(:match) do |event|
          clauses = event.affected_text.split("; ")
          { "complete" => true, "status" => "resolved", "source_content_version" => event.content_version,
            "water_mixed_coverage_revision" => revision, "scope" => "source_named_water_locations",
            "scope_precision" => "unspecified_street_segment", "board_placement" => "verified_full_geometry_intersection",
            "clause_count" => 2, "resolved_clause_count" => 2, "unresolved_clause_count" => 0,
            "clauses" => clauses.map { |text| { "evidence" => text, "kind" => text.end_with?("(Bijeljina)") ? "street" : "settlement_part",
                                                   "status" => "resolved", "board_slugs" => ["komsiluk-lugovi"] } },
            "affected_places" => [{ "slug" => "komsiluk-lugovi", "kind" => "komsiluk", "source" => "municipal_settlement_geometry" }],
            "unresolved_places" => [], "ambiguous_places" => [] }
        end
        @preparer.instance_variable_set(:@water_mixed_coverage, mixed)

        @preparer.call(events: [@event])
        @event.reload
        assert_equal ["komsiluk-lugovi"], @event.area_slugs
        assert_equal "verified_water_location_geometry", @event.extraction_metadata.dig("confidence_by_field", "place")
        assert_equal "unspecified_street_segment", @event.extraction_metadata.dig("coverage", "scope_precision")
        assert_equal original, @event.extraction_metadata.dig("water_board_copy", "original")
        assert [@event.title, @event.summary, @event.viber_text].all? { |copy| copy.include?("dio komšiluka") }
        refute_includes CityServiceAutomation.new(organization: @organization).blockers(@event), "coverage_requires_review"
        unchanged = @event.attributes
        @preparer.call(events: [@event])
        assert_equal unchanged, @event.reload.attributes
      end

      test "full street union persists primary komsiluci and independent MZ evidence without approval" do
        @event.update!(source_url: "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=41", affected_text: "1 NN izlaz dio ulice Izmišljena lipa",
                       extraction_metadata: { "tj" => "Bijeljina", "source_snapshot_complete" => true, "coverage" => { "status" => "unresolved" } })
        %w(left right).each do |side|
          Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-#{side}", name: { "sr" => side })
        end
        street = Object.new
        street.define_singleton_method(:revision) { "test" }
        street.define_singleton_method(:match) do |event|
          { "complete" => true, "status" => "resolved", "source_content_version" => event.content_version, "street_coverage_revision" => "test",
            "affected_places" => %w(komsiluk-left komsiluk-right mz-lugovi).map do |slug|
              { "slug" => slug, "kind" => slug.split("-").first, "relation" => "possible_overlap", "source" => "full_named_street_geometry" }
            end }
        end
        @preparer.instance_variable_set(:@street_coverage, street)
        @preparer.call(events: [@event])
        @event.reload
        assert_equal "komsiluk", @event.targeting_level
        assert_equal %w(komsiluk-left komsiluk-right), @event.area_slugs.sort
        assert_equal(%w(komsiluk komsiluk mz), @event.extraction_metadata.dig("coverage", "affected_places").map { |row| row.fetch("kind") })
        assert_equal "unresolved", @event.extraction_metadata.dig("coverage", "original_extraction", "status")
        assert @event.pending_review?
        assert_nil @event.reviewed_content_version
        original = @event.extraction_metadata.deep_dup
        @preparer.call(events: [@event])
        assert_equal original, @event.reload.extraction_metadata
      end

      test "changed street boundary revision refreshes automatic targets while preserving original extraction" do
        old_coverage = { "status" => "resolved", "complete" => true, "street_coverage_revision" => "old-boundary", "source_content_version" => @event.content_version,
                         "original_extraction" => { "status" => "unknown" }, "affected_places" => [{ "slug" => "komsiluk-old", "kind" => "komsiluk" }] }
        @event.update!(targeting_level: "komsiluk", affected_area_slugs: ["komsiluk-old"], extraction_metadata: { "coverage" => old_coverage })
        street = Object.new
        street.define_singleton_method(:revision) { "new-boundary" }
        street.define_singleton_method(:match) do |event|
          { "status" => "resolved", "complete" => true, "street_coverage_revision" => "new-boundary", "source_content_version" => event.content_version,
            "affected_places" => [{ "slug" => "komsiluk-lugovi", "kind" => "komsiluk", "relation" => "possible_overlap", "source" => "full_named_street_geometry" }] }
        end
        @preparer.instance_variable_set(:@street_coverage, street)
        @preparer.call(events: [@event])
        assert_equal ["komsiluk-lugovi"], @event.reload.area_slugs
        assert_equal "new-boundary", @event.extraction_metadata.dig("coverage", "street_coverage_revision")
        assert_equal({ "status" => "unknown" }, @event.extraction_metadata.dig("coverage", "original_extraction"))
        assert_equal ["komsiluk-old"], @event.extraction_metadata.dig("coverage", "previous_mapping", "affected_area_slugs")
        assert @event.pending_review?
        assert_nil @event.reviewed_at
        unchanged = @event.attributes
        @preparer.call(events: [@event])
        assert_equal unchanged, @event.reload.attributes
      end

      test "removed street evidence clears only automatic targets and retains source uncertainty" do
        coverage = { "status" => "resolved", "complete" => true, "street_coverage_revision" => "old-boundary", "source_content_version" => @event.content_version,
                     "original_extraction" => { "status" => "unknown" }, "affected_places" => [{ "slug" => "komsiluk-old", "kind" => "komsiluk" }] }
        @event.update!(targeting_level: "komsiluk", affected_area_slugs: ["komsiluk-old"], extraction_metadata: { "coverage" => coverage })
        street = Object.new
        street.define_singleton_method(:revision) { "removed-street" }
        street.define_singleton_method(:match) { |_| nil }
        @preparer.instance_variable_set(:@street_coverage, street)
        @preparer.call(events: [@event])
        assert_equal "unknown", @event.reload.targeting_level
        assert_empty @event.area_slugs
        assert_empty @event.extraction_metadata.dig("coverage", "affected_places")
        assert_equal "removed-street", @event.extraction_metadata.dig("coverage", "street_coverage_revision")
        assert_equal "street_or_boundary_revision_changed", @event.extraction_metadata.dig("coverage", "reason")
        assert CityServiceEvent.milica_available.exists?(@event.id)
        assert_nil @event.reviewed_at
      end

      test "settlement revision refresh updates prior automatic MZ and clears removed evidence without approval" do
        old = { "crosswalk_revision" => "old-source", "source_content_version" => @event.content_version,
                "affected_places" => [{ "slug" => "mz-lugovi", "kind" => "mz", "source_snapshot_sha256" => "old-snapshot" }],
                "original_extraction" => { "status" => "unknown" } }
        @event.update!(targeting_level: "mz", affected_area_slugs: ["mz-lugovi"], extraction_metadata: { "coverage" => old })
        revision = "new-GIS"
        available = true
        crosswalk = Object.new
        crosswalk.define_singleton_method(:revision) { revision }
        crosswalk.define_singleton_method(:match) do |event|
          next unless available

          { "status" => "resolved", "complete" => true, "crosswalk_revision" => revision, "source_content_version" => event.content_version,
            "affected_places" => [{ "slug" => "komsiluk-lugovi", "kind" => "komsiluk", "relation" => "possible_overlap", "source_snapshot_sha256" => "new-snapshot" },
                                  { "slug" => "mz-lugovi", "kind" => "mz", "relation" => "possible_overlap" }] }
        end
        @preparer.instance_variable_set(:@source_crosswalk, crosswalk)
        @preparer.call(events: [@event])
        assert_equal "komsiluk", @event.reload.targeting_level
        assert_equal ["komsiluk-lugovi"], @event.area_slugs
        assert_equal "old-snapshot", @event.extraction_metadata.dig("coverage", "previous_mapping", "coverage", "affected_places", 0, "source_snapshot_sha256")
        assert_equal "new-snapshot", @event.extraction_metadata.dig("coverage", "affected_places", 0, "source_snapshot_sha256")
        assert_equal "unknown", @event.extraction_metadata.dig("coverage", "original_extraction", "status")
        assert @event.pending_review?
        assert_nil @event.reviewed_at
        original = @event.attributes
        @preparer.call(events: [@event])
        assert_equal original, @event.reload.attributes

        revision = "removed-GIS"
        available = false
        @preparer.call(events: [@event])
        assert_equal "unknown", @event.reload.targeting_level
        assert_empty @event.area_slugs
        assert_equal "removed-GIS", @event.extraction_metadata.dig("coverage", "crosswalk_revision")
        assert_equal "new-snapshot", @event.extraction_metadata.dig("coverage", "previous_mapping", "coverage", "affected_places", 0, "source_snapshot_sha256")
        assert_nil @event.reviewed_at

        @event.update!(targeting_level: "mz", affected_area_slugs: ["mz-lugovi"], extraction_metadata: { "coverage" => old, "operator_review" => { "source" => "operator" } })
        original = @event.attributes
        @preparer.call(events: [@event])
        assert_equal original, @event.reload.attributes
      end

      test "geometry revision refresh never overwrites an operator correction or review receipt" do
        coverage = { "street_coverage_revision" => "old-boundary", "source_content_version" => @event.content_version }
        @event.update!(targeting_level: "mz", affected_area_slugs: ["mz-lugovi"],
                       extraction_metadata: { "coverage" => coverage, "operator_review" => { "provenance" => "operator_correction" } })
        street = Object.new
        street.define_singleton_method(:revision) { raise "Reviewed mapping must not be recomputed" }
        @preparer.instance_variable_set(:@street_coverage, street)
        original = @event.attributes
        @preparer.call(events: [@event])
        assert_equal original, @event.reload.attributes

        @event.update!(reviewed_at: Time.current, extraction_metadata: { "coverage" => coverage })
        original = @event.attributes
        @preparer.call(events: [@event])
        assert_equal original, @event.reload.attributes
      end

      test "unknown area operator decisions survive automatic preparation" do
        street = Object.new
        street.define_singleton_method(:match) { |_| raise "Reviewed source area must not be remapped" }
        @preparer.instance_variable_set(:@street_coverage, street)
        [{ extraction_metadata: { "operator_review" => { "provenance" => "operator_correction" } } },
         { extraction_metadata: {}, reviewed_at: Time.current }].each do |attributes|
          @event.update!(attributes)
          original = @event.attributes
          @preparer.call(events: [@event])
          assert_equal original, @event.reload.attributes
        end
      end

      test "partial local street geometry remains possible evidence without full geometry confidence" do
        street = Object.new
        street.define_singleton_method(:match) do |event|
          { "complete" => false, "status" => "partial", "source_content_version" => event.content_version, "street_coverage_revision" => "partial-test",
            "affected_places" => [{ "slug" => "komsiluk-lugovi", "kind" => "komsiluk", "relation" => "possible_overlap", "evidence" => "Lugovi",
                                    "source" => "local_street_geometry", "geometry_complete" => false }] }
        end
        @preparer.instance_variable_set(:@street_coverage, street)
        @preparer.call(events: [@event])
        assert_equal "unknown", @event.reload.targeting_level
        assert_empty @event.area_slugs
        assert_equal "partial_street_geometry", @event.extraction_metadata.dig("confidence_by_field", "place")
        assert_equal false, @event.extraction_metadata.dig("coverage", "complete")
        assert_nil @event.reviewed_at
      end

      test "shared names produce both typed suggestions without assigning or approving" do
        @preparer.call(events: [@event])
        suggestions = @event.reload.extraction_metadata.fetch("area_review_suggestions")
        assert_equal %w(komsiluk-lugovi mz-lugovi), suggestions.fetch("candidates").map { |c| c["slug"] }.sort
        assert suggestions["requires_coverage_review"]
        assert_empty @event.area_slugs
        assert_equal "unknown", @event.targeting_level
        assert @event.pending_review?
        assert_nil @event.reviewed_content_version
      end

      test "street preparation reuses geocoder and guarded point resolver and caches coordinates" do
        @event.update!(affected_text: "Ulica Izmišljena lipa")
        calls = []
        geocoder = Object.new
        geocoder.define_singleton_method(:coordinates) do |query|
          calls << query
          { lat: 0.512345, lon: 0.756789 }
        end
        preparer = CityServiceAreaPreparation.new(organization: @organization, cache: @cache, geocoder:)
        area = Decidim::Bih::LocalArea.find_by!(organization: @organization, kind: "komsiluk")
        matcher = Object.new
        matcher.define_singleton_method(:contextual_places) { |**| [] }
        matcher.define_singleton_method(:maintenance_contextual_places) { |**| [] }
        matcher.define_singleton_method(:match) do |_text|
          Struct.new(:coverage).new({ "ambiguous_places" => [], "unresolved_places" => [{ "kind" => "street", "evidence" => "ulica izmisljena lipa" }] })
        end
        matcher.define_singleton_method(:resolve) do |location:|
          raise unless location == { latitude: 0.512345, longitude: 0.756789 }

          Struct.new(:status, :areas).new(:ok, [area])
        end
        preparer.instance_variable_set(:@matcher, matcher)
        2.times { preparer.call(events: [@event], geocode: true) }
        assert_equal 1, calls.size
        assert_equal "izmisljena lipa, Bijeljina, Bosna i Hercegovina", calls.first
        assert_equal "geocoder_point_in_polygon", @event.reload.extraction_metadata.dig("area_review_suggestions", "candidates", 0, "method")
        assert_empty @event.area_slugs
        assert_no_match(/0\.512345|0\.756789/, @event.extraction_metadata.to_json)
      end

      test "multiple street clauses become separate address queries" do
        coverage = { "unresolved_places" => [
          { "kind" => "street", "evidence" => "ulice izmisljeni jasen i dio ulice izmisljena bukva" },
          { "kind" => "feeder", "evidence" => "DV Lugovi" }
        ] }
        assert_equal ["izmisljeni jasen", "izmisljena bukva"], @preparer.send(:public_address_queries, coverage)
      end

      test "NN exit text retains a bare street name while feeder-only text is not an address" do
        @event.update!(affected_text: "1 NN izlaz Izmišljena lipa", extraction_metadata: { "feeder" => "TS CENTAR 5" })
        coverage = { "unresolved_places" => [] }
        assert_equal ["izmisljena lipa"], @preparer.send(:public_address_queries, coverage, event: @event)
        @event.update!(affected_text: "1 NN izlaz")
        assert_empty @preparer.send(:public_address_queries, coverage, event: @event)
      end

      test "provider settlement lists and contextual water street names become public queries" do
        @event.update!(affected_text: "Naseljena mjesta: Izmišljeni prilaz, Jasen, Testni rub, Nepoznata", extraction_metadata: { "feeder" => "DV 10KV IZMIŠLJENI PRILAZ" })
        coverage = { "unresolved_places" => [] }
        assert_equal ["izmisljeni prilaz", "jasen", "testni rub", "nepoznata"], @preparer.send(:public_address_queries, coverage, event: @event)
        @event.update!(affected_text: "Testno polje, Testni prelaz i Testni vrt")
        assert_equal ["testno polje", "testni prelaz", "testni vrt"], @preparer.send(:public_address_queries, coverage, event: @event)
        @event.update!(source_key: "water_service", affected_text: "Измишљена бреза (Бијељина); Измишљени јавор (Лугови)")
        assert_equal ["izmisljena breza, bijeljina", "izmisljeni javor, lugovi"], @preparer.send(:public_address_queries, coverage, event: @event)
      end

      test "a unique named station retains place context and uses partial-area board placement" do
        @event.update!(affected_text: "1 NN izlaz", extraction_metadata: { "feeder" => "TS LUGOVI CENTAR" })
        geocoder = Object.new
        geocoder.define_singleton_method(:coordinates) { |_| raise "feeder must not be geocoded" }
        preparer = CityServiceAreaPreparation.new(organization: @organization, cache: @cache, geocoder:)
        preparer.call(events: [@event], geocode: true)
        @event.reload
        assert_equal ["komsiluk-lugovi"], @event.area_slugs
        assert_equal "komsiluk", @event.targeting_level
        assert_equal "part_of_area", @event.extraction_metadata.dig("coverage", "scope_precision")
        assert_includes @event.summary, "dio komšiluka"
        assert @event.pending_review?
        assert_equal "provider_station_name", @event.extraction_metadata.dig("confidence_by_field", "place")
      end

      test "Javorice transformer label keeps context beside a partial-area board placement" do
        %w(mz komsiluk).each do |kind|
          Decidim::Bih::LocalArea.create!(organization: @organization, kind:, slug: "#{kind}-javorice", name: { "sr" => "Javorice" })
        end
        @event.update!(affected_text: "1 NN izlaz", extraction_metadata: { "feeder" => "TS JAVORICE CENTAR" })
        geocoder = Object.new
        geocoder.define_singleton_method(:coordinates) { |_| raise "An asset label is not a street address" }
        preparer = CityServiceAreaPreparation.new(organization: @organization, cache: @cache, geocoder:)
        preparer.call(events: [@event], geocode: true)
        context = @event.reload.extraction_metadata.fetch("place_context")
        assert_equal @event.content_version, context.fetch("source_content_version")
        assert_equal %w(komsiluk-javorice mz-javorice), context.fetch("places").map { |place| place.fetch("slug") }.sort
        assert(context.fetch("places").all? { |place| place["name"] == "Javorice" && place["relation"] == "context_only" && place["evidence"] == "TS JAVORICE CENTAR" })
        assert_equal "komsiluk", @event.targeting_level
        assert_equal ["komsiluk-javorice"], @event.area_slugs
        assert_nil @event.reviewed_at
        assert @event.pending_review?
        metadata = @event.extraction_metadata.deep_dup
        updated_at = @event.updated_at
        preparer.call(events: [@event])
        assert_equal metadata, @event.reload.extraction_metadata
        assert_equal updated_at, @event.updated_at
      end

      test "maintenance reason recognizes Vrbovo context without broadening the affected places" do
        %w(mz komsiluk).each do |kind|
          Decidim::Bih::LocalArea.create!(organization: @organization, kind:, slug: "#{kind}-vrbovo", name: { "sr" => "Vrbovo" })
        end
        reason = "Remont ČTS 35/10 kV Vrbovo"
        @event.update!(affected_text: "Testno polje, Testni prelaz i Testni vrt", extraction_metadata: { "feeder" => "DV 10KV TESTNO POLJE", "reason" => reason })
        @preparer.call(events: [@event])
        places = @event.reload.extraction_metadata.fetch("place_context").fetch("places")
        assert_equal %w(komsiluk-vrbovo mz-vrbovo), places.map { |place| place.fetch("slug") }.sort
        assert(places.all? { |place| place["relation"] == "context_only" && place["source"] == "provider_maintenance_reason" && place["evidence"] == reason })
        assert_empty @event.area_slugs
        assert_equal "unknown", @event.targeting_level
        assert @event.pending_review?
        assert_nil @event.reviewed_at
        @event.update!(extraction_metadata: @event.extraction_metadata.merge("reason" => "Sanacija NN mreže"))
        @preparer.call(events: [@event])
        assert_nil @event.reload.extraction_metadata["place_context"]
      end

      test "maintenance context supports Cyrillic and reason-only assets while excluding background names" do
        matcher = CityServiceAreaMatcher.new(organization: @organization)
        assert_equal %w(komsiluk-lugovi mz-lugovi), matcher.maintenance_contextual_places(reason: "Ремонт ЧТС 35/10 кВ Лугови").map { |place| place.fetch("slug") }.sort
        assert_empty matcher.maintenance_contextual_places(reason: "Poslovnica Lugovi")
        assert_empty matcher.maintenance_contextual_places(reason: "Kontakt: TS Lugovi")
        assert_empty matcher.maintenance_contextual_places(reason: "Sastanak u Lugovima")
        @event.update!(affected_text: "1 NN izlaz", extraction_metadata: { "reason" => "Remont TS Lugovi" })
        @preparer.call(events: [@event])
        assert_equal %w(komsiluk-lugovi mz-lugovi), CityServicePlaceContext.slugs(@event.reload).sort
        assert_empty @event.area_slugs
      end

      test "context is retained beside resolved geography and removed when changed source no longer names a place" do
        @event.update!(targeting_level: "mz", affected_area_slugs: ["mz-lugovi"], affected_text: "A named street",
                       extraction_metadata: { "feeder" => "TS LUGOVI CENTAR" })
        @preparer.call(events: [@event])
        assert_equal %w(komsiluk-lugovi mz-lugovi), @event.reload.extraction_metadata.fetch("place_context").fetch("places").map { |place| place.fetch("slug") }.sort
        assert_equal ["mz-lugovi"], @event.area_slugs
        @event.update!(content_version: "v2", extraction_metadata: @event.extraction_metadata.merge("feeder" => "TS CENTAR 5"))
        @preparer.call(events: [@event])
        assert_nil @event.reload.extraction_metadata["place_context"]
        assert_equal ["mz-lugovi"], @event.area_slugs
      end

      test "asset context recognizes Cyrillic and abbreviations without widening ordinary coverage or accepting background names" do
        matcher = CityServiceAreaMatcher.new(organization: @organization)
        places = matcher.contextual_places(asset_label: "ТС ЛУГОВИ ЦЕНТАР")
        assert_equal %w(komsiluk-lugovi mz-lugovi), places.map { |place| place.fetch("slug") }.sort
        assert_empty matcher.match("TS LUGOVI CENTAR").slugs
        assert_empty matcher.contextual_places(asset_label: "Poslovnica Lugovi")
        assert_empty matcher.contextual_places(asset_label: "TS CENTAR 5")
        foreign = create_organization
        assert_empty CityServiceAreaMatcher.new(organization: foreign).contextual_places(asset_label: "TS LUGOVI CENTAR")
      end

      test "provider abbreviation places Veliki Park without querying an asset" do
        %w(mz komsiluk).each do |kind|
          Decidim::Bih::LocalArea.create!(organization: @organization, kind:, slug: "#{kind}-veliki-park", name: { "sr" => "Veliki Park" })
        end
        @event.update!(affected_text: "1 NN izlaz", extraction_metadata: { "feeder" => "TS V. PARK RUB 2" })
        @preparer.call(events: [@event])
        assert_equal ["komsiluk-veliki-park"], @event.reload.area_slugs
        assert_equal "part_of_area", @event.extraction_metadata.dig("coverage", "scope_precision")
      end

      test "municipal containment assigns complete named MZ relevance without approval or komsiluk inference" do
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-vrt", name: { "sr" => "Vrt" })
        @event.update!(source_url: "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=41", affected_text: "Naseljeno mjesto: Vrt",
                       extraction_metadata: { "tj" => "Bijeljina", "source_snapshot_complete" => true, "coverage" => { "status" => "ambiguous" } })
        @preparer.call(events: [@event])
        assert_equal "mz", @event.reload.targeting_level
        assert_equal ["mz-vrt"], @event.area_slugs
        assert @event.pending_review?
        assert_nil @event.reviewed_content_version
        assert_nil @event.reviewed_by_id
        coverage = @event.extraction_metadata.fetch("coverage")
        assert coverage.fetch("complete")
        assert_equal "part", coverage.fetch("affected_places").first.fetch("relation")
        assert_equal "not_inferred", coverage.fetch("komsiluk_status")
        assert_equal "ambiguous", coverage.dig("original_extraction", "status")
        before = @event.updated_at
        @preparer.call(events: [@event])
        assert_equal before, @event.reload.updated_at
      end

      test "partial source containment records proved relevance and unverified remainder without assigning a full target" do
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-gaj", name: { "sr" => "Gaj" })
        @event.update!(source_url: "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=41", affected_text: "Naseljena mjesta: Jasen, Nepoznata",
                       extraction_metadata: { "tj" => "Bijeljina", "source_snapshot_complete" => true })
        @preparer.call(events: [@event])
        assert_equal "unknown", @event.reload.targeting_level
        assert_empty @event.area_slugs
        coverage = @event.extraction_metadata.fetch("coverage")
        assert_equal "partial", coverage.fetch("status")
        assert_includes @event.extraction_metadata.dig("area_review_suggestions", "candidates"),
                        { "slug" => "mz-gaj", "evidence" => "jasen", "method" => "municipal_place_containment" }
        assert_equal false, coverage.fetch("complete")
        assert_equal(["mz-gaj"], coverage.fetch("affected_places").map { |row| row.fetch("slug") })
        assert_equal(["nepoznata"], coverage.fetch("unresolved_places").map { |row| row.fetch("evidence") })
        before = @event.updated_at
        @preparer.call(events: [@event])
        assert_equal before, @event.reload.updated_at
        assert @event.pending_review?
      end

      test "geocoder failure leaves collection and unresolved evidence intact" do
        @event.update!(affected_text: "Ulica Izmišljena lipa")
        geocoder = Object.new
        geocoder.define_singleton_method(:coordinates) { |_| raise Timeout::Error, "upstream unavailable" }
        preparer = CityServiceAreaPreparation.new(organization: @organization, cache: @cache, geocoder:)
        assert_nothing_raised { preparer.call(events: [@event], geocode: true) }
        assert_equal "provider_location_evidence_needed", @event.reload.extraction_metadata.dig("area_review_suggestions", "reason")
        assert_empty @event.area_slugs
      end

      test "skips other organizations and never geocodes an electricity feeder" do
        @event.update!(affected_text: "DV Lugovi")
        geocoder = Object.new
        geocoder.define_singleton_method(:coordinates) { |_| raise "feeder is not an address" }
        preparer = CityServiceAreaPreparation.new(organization: @organization, cache: @cache, geocoder:)
        preparer.call(events: [@event], geocode: true)
        assert_empty @event.reload.extraction_metadata.dig("area_review_suggestions", "candidates")
        other = CityServiceAreaPreparation.new(organization: create_organization, cache: @cache, geocoder:)
        before = @event.updated_at
        other.call(events: [@event], geocode: true)
        assert_equal before, @event.reload.updated_at
      end

      test "explicit unexpired operator mapping is reused only for the same provider location" do
        @event.update!(source_url: "https://provider.example/document", ends_at: 1.day.from_now)
        previous = @event.dup
        area = Decidim::Bih::LocalArea.find_by!(organization: @organization, kind: "mz")
        actor = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        previous.update!(source_fingerprint: "prior-mapping", targeting_level: "mz", affected_area_slugs: [area.slug], reviewer: actor, reviewed_at: Time.current,
                         content_version: "reviewed-source-v1", reviewed_content_version: "reviewed-source-v1",
                         extraction_metadata: { "operator_review" => { "reuse_coverage" => true, "coverage_valid_until" => (Date.current + 30).iso8601 } })
        @preparer.call(events: [@event])
        assert_equal [area.slug], @event.reload.area_slugs
        assert @event.pending_review?
        assert_nil @event.reviewed_content_version
        assert_equal previous.id, @event.extraction_metadata.dig("coverage", "mapping_event_id")
        @event.update!(targeting_level: "unknown", affected_area_slugs: [], extraction_metadata: { "feeder" => "different feeder" })
        @preparer.call(events: [@event])
        assert_empty @event.reload.area_slugs
        @event.update!(extraction_metadata: {})
        previous.update!(extraction_metadata: { "operator_review" => { "reuse_coverage" => true, "coverage_valid_until" => Date.yesterday.iso8601 } })
        @preparer.call(events: [@event])
        assert_empty @event.reload.area_slugs
      end

      test "new versions do not inherit old suggestions" do
        @preparer.call(events: [@event])
        @event.update!(content_version: "v2", affected_text: "DV Nepoznato")
        @preparer.call(events: [@event])
        assert_empty @event.reload.extraction_metadata.dig("area_review_suggestions", "candidates")
      end
    end
  end
end
