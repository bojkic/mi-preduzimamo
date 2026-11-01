# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Unit coverage for the GeoJSON builder behind the public reports map.
    # The engine's services currently live under the app test suite (known tech
    # debt mirrored from the existing reporting tests).
    class ReportMapFeaturesTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @url_builder = ->(reference) { "/biceriseno/prijave/#{reference}" }
      end

      def build(**attrs)
        Decidim::Bih::Report.create!(organization: @organization, description: "Problem", **attrs)
      end

      def features(organization: @organization, **)
        Decidim::Bih::ReportMapFeatures.new(organization, url_builder: @url_builder, **).call
      end

      test "returns a GeoJSON FeatureCollection" do
        build(latitude: 44.75, longitude: 19.21)

        result = features

        assert_equal "FeatureCollection", result[:type]
        assert_equal 1, result[:features].size
        feature = result[:features].first
        assert_equal "Feature", feature[:type]
        assert_equal "Point", feature[:geometry][:type]
        # GeoJSON coordinate order is [longitude, latitude].
        assert_in_delta 19.21, feature[:geometry][:coordinates][0]
        assert_in_delta 44.75, feature[:geometry][:coordinates][1]
      end

      test "emits non-rounded exact coordinates for both legacy publication flags" do
        false_flag = build(
          reference: "BR-2026-1001", latitude: 44.756123, longitude: 19.214987,
          public_location_exact: false
        )
        true_flag = build(
          reference: "BR-2026-1002", latitude: 44.756789, longitude: 19.214321,
          public_location_exact: true
        )

        by_reference = features[:features].index_by { |feature| feature[:properties][:reference] }
        [false_flag, true_flag].each do |report|
          feature = by_reference.fetch(report.reference)
          assert_in_delta report.longitude.to_f, feature[:geometry][:coordinates][0], 0.0000001
          assert_in_delta report.latitude.to_f, feature[:geometry][:coordinates][1], 0.0000001
          assert_in_delta report.latitude.to_f, feature[:properties][:latitude], 0.0000001
          assert_in_delta report.longitude.to_f, feature[:properties][:longitude], 0.0000001
          assert_equal "exact", feature[:properties][:location_precision]
        end
      end

      test "does not reuse an old approximate-location cache entry for the same row" do
        report = build(latitude: 44.756123, longitude: 19.214987, public_location_exact: false)
        builder = Decidim::Bih::ReportMapFeatures.new(@organization, url_builder: @url_builder)
        new_key = builder.cache_key
        old_key = new_key.sub("/#{Decidim::Bih::ReportMapFeatures::SCHEMA_VERSION}/", "/v4-approximate-location/")
        approximate = {
          type: "FeatureCollection",
          features: [{ geometry: { type: "Point", coordinates: [19.214, 44.756] }, properties: {
            reference: report.reference, latitude: 44.756, longitude: 19.214, location_precision: "approximate"
          } }]
        }

        feature = nil
        memory = ActiveSupport::Cache::MemoryStore.new
        Rails.stub(:cache, memory) do
          memory.write(old_key, approximate)
          assert_equal approximate, memory.read(old_key)
          assert_not_equal old_key, new_key
          feature = builder.call[:features].first
        end

        assert_in_delta report.longitude.to_f, feature[:geometry][:coordinates][0], 0.0000001
        assert_in_delta report.latitude.to_f, feature[:geometry][:coordinates][1], 0.0000001
        assert_in_delta report.latitude.to_f, feature[:properties][:latitude], 0.0000001
        assert_in_delta report.longitude.to_f, feature[:properties][:longitude], 0.0000001
        assert_equal "exact", feature[:properties][:location_precision]
      end

      test "includes only reports that carry both coordinates" do
        located = build(latitude: 44.75, longitude: 19.21)
        build(latitude: nil, longitude: nil)
        build(latitude: 44.80, longitude: nil)
        build(latitude: nil, longitude: 19.30)

        refs = features[:features].map { |f| f[:properties][:reference] }

        assert_equal [located.reference], refs
      end

      test "never exposes reporter PII" do
        build(
          latitude: 44.75,
          longitude: 19.21,
          reporter_email: "tajni@example.org",
          reporter_phone: "065123456",
          anonymous: false
        )

        payload = features.to_json

        assert_not_includes payload, "tajni@example.org"
        assert_not_includes payload, "065123456"
        props = features[:features].first[:properties]
        assert_not_includes props.keys, :reporter_email
        assert_not_includes props.keys, :reporter_phone
        # The exposed projection is exactly the safe field set — note `description`
        # is deliberately NOT here (unmoderated reporter free text).
        assert_equal(
          [:reference, :category, :severity, :status, :created_at, :latitude,
           :longitude, :location_precision, :status_url, :resolved_recently, :public_status, :public_status_label].sort,
          props.keys.sort
        )
      end

      test "is scoped to the given organization" do
        # References are per-org sequential, so pin distinct ones to tell the two
        # organizations' first reports apart in the assertions below.
        mine = build(latitude: 44.75, longitude: 19.21, reference: "BR-2026-0001")
        other = create_organization
        theirs = Decidim::Bih::Report.create!(
          organization: other, description: "Tudja prijava", latitude: 45.0, longitude: 18.0, reference: "BR-2026-9001"
        )

        refs = features[:features].map { |f| f[:properties][:reference] }

        assert_includes refs, mine.reference
        assert_equal 1, refs.size

        other_refs = features(organization: other)[:features].map { |f| f[:properties][:reference] }
        assert_includes other_refs, theirs.reference
        assert_not_includes other_refs, mine.reference
      end

      test "respects the result cap, returning the most recent first" do
        build(latitude: 44.70, longitude: 19.20, created_at: 2.days.ago)
        recent = build(latitude: 44.71, longitude: 19.21, created_at: 1.minute.ago)

        result = features(limit: 1)

        assert_equal 1, result[:features].size
        assert_equal recent.reference, result[:features].first[:properties][:reference]
      end

      test "default cap is bounded" do
        assert_equal 500, Decidim::Bih::ReportMapFeatures::DEFAULT_LIMIT
      end

      test "never exposes the reporter-entered description" do
        # The description is unmoderated free text a citizen could put PII into,
        # so the public bulk map endpoint must not serialize it at all.
        build(latitude: 44.75, longitude: 19.21, description: "Zovem se Pera, broj 065123456")

        props = features[:features].first[:properties]

        assert_not_includes props.keys, :description
        assert_not_includes features.to_json, "065123456"
      end

      test "carries the AI-computed severity into each feature so the map can style markers by it" do
        build(latitude: 44.75, longitude: 19.21, severity: "hitan")

        props = features[:features].first[:properties]

        assert_equal "hitan", props[:severity]
      end

      test "builds the status URL from the injected builder" do
        report = build(latitude: 44.75, longitude: 19.21)

        url = features[:features].first[:properties][:status_url]

        assert_equal "/biceriseno/prijave/#{report.reference}", url
      end

      # --- recently-resolved map layer ---

      test "flags a recently resolved located report so the map can style it as a distinct layer" do
        r = build(latitude: 44.75, longitude: 19.21)
        r.update!(status: "rijeseno")

        props = features[:features].first[:properties]

        assert_equal "rijeseno", props[:status]
        assert_equal true, props[:resolved_recently]
      end

      test "an older resolved report is not flagged as recently resolved" do
        r = build(latitude: 44.75, longitude: 19.21)
        r.update!(status: "rijeseno")
        # Push the resolution timestamp outside the recent window.
        old = (Decidim::Bih::ReportMapFeatures::RESOLVED_RECENT_DAYS + 5).days.ago
        r.update_columns( # rubocop:disable Rails/SkipsModelValidations
          status_history: [
            { "status" => "primljeno", "at" => (old - 1.day).utc.iso8601 },
            { "status" => "rijeseno", "at" => old.utc.iso8601 }
          ],
          updated_at: old
        )

        props = features[:features].first[:properties]

        assert_equal "rijeseno", props[:status]
        assert_equal false, props[:resolved_recently]
      end

      test "a non-resolved located report is not flagged as recently resolved" do
        build(latitude: 44.75, longitude: 19.21, status: "proslijedjeno")

        props = features[:features].first[:properties]

        assert_equal false, props[:resolved_recently]
      end

      test "the recently-resolved flag carries no PII" do
        r = build(
          latitude: 44.75,
          longitude: 19.21,
          reporter_email: "tajni@example.org",
          reporter_phone: "065123456"
        )
        r.update!(status: "rijeseno")

        props = features[:features].first[:properties]

        # The projection is still exactly the safe field set plus the new flag.
        assert_equal(
          [:reference, :category, :severity, :status, :created_at,
           :latitude, :longitude, :location_precision, :status_url, :resolved_recently, :public_status, :public_status_label].sort,
          props.keys.sort
        )
        assert_not_includes features.to_json, "tajni@example.org"
        assert_not_includes features.to_json, "065123456"
      end
    end
  end
end
