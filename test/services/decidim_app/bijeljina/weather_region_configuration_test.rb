# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../../../../app/services/decidim_app/bijeljina/weather_region_configuration"

module DecidimApp
  module Bijeljina
    class WeatherRegionConfigurationTest < Minitest::Test
      DAY = Date.new(2040, 9, 16)

      def authored_review
        { "version" => 1, "organization_host" => "community.example.invalid",
          "source_url" => "https://weather.example.invalid/feed", "provider_area_code" => "TEST-REGION-A",
          "region_label" => "Izmišljeni testni region", "community_label" => "Izmišljena zajednica",
          "evidence_url" => "https://review.example.invalid/authored-coverage#feature-a",
          "reviewed_on" => "2040-09-14", "valid_until" => "2041-09-14", "review_state" => "reviewed" }
      end

      def review(data = authored_review, day: DAY) = WeatherRegionConfiguration.new(data, day:)

      def with_authored_acquisition_review
        prior = ENV["MI_WEATHER_REGION_CONFIG_PATH"]
        Tempfile.create("authored-acquisition-review") do |file|
          file.write(JSON.generate(authored_review))
          file.flush
          ENV["MI_WEATHER_REGION_CONFIG_PATH"] = file.path
          yield file
        end
      ensure
        prior.nil? ? ENV.delete("MI_WEATHER_REGION_CONFIG_PATH") : ENV["MI_WEATHER_REGION_CONFIG_PATH"] = prior
      end

      def test_acquired_review_is_immutable_and_cannot_be_relabelled_by_a_changed_file
        with_authored_acquisition_review do |file|
          captured = WeatherRegionConfiguration.for_source(source_url: authored_review.fetch("source_url"), day: DAY)
          assert_same captured, WeatherRegionConfiguration.assert_current!(captured, source_url: captured.source_url, day: DAY)
          File.write(file.path, JSON.generate(authored_review.merge("region_label" => "Drugi autorski region")))
          assert_raises(WeatherRegionConfiguration::InvalidConfiguration) do
            WeatherRegionConfiguration.assert_current!(captured, source_url: captured.source_url, day: DAY)
          end
          assert_equal "Izmišljeni testni region", captured.region_label
        end
      end

      def test_acquisition_cannot_cross_expiry_source_organization_or_missing_review
        with_authored_acquisition_review do |_file|
          captured = WeatherRegionConfiguration.for_source(source_url: authored_review.fetch("source_url"), day: DAY)
          [{ day: Date.new(2041, 9, 15) }, { organization_host: "other.example.invalid" },
           { source_url: "https://other.example.invalid/feed" }].each do |changes|
            assert_raises(WeatherRegionConfiguration::InvalidConfiguration) do
              WeatherRegionConfiguration.assert_current!(captured, **{ source_url: captured.source_url, day: DAY }.merge(changes))
            end
          end
          ENV.delete("MI_WEATHER_REGION_CONFIG_PATH")
          assert_raises(WeatherRegionConfiguration::InvalidConfiguration) do
            WeatherRegionConfiguration.assert_current!(captured, source_url: captured.source_url, day: DAY)
          end
        end
      end

      def test_missing_path_has_no_inherited_region_city_or_evidence
        assert_nil WeatherRegionConfiguration.load(day: DAY, path: "")
      end

      def test_explicit_review_preserves_metadata_and_matches_only_its_organization_and_source
        config = review
        assert_predicate config, :frozen?
        assert_equal "TEST-REGION-A", config.provider_area_code
        assert_equal "operator_reviewed_region_coverage", config.metadata.fetch("coverage_status")
        assert_equal "Izmišljena zajednica", config.metadata.fetch("relevant_city")
        assert_equal "https://review.example.invalid/authored-coverage#feature-a", config.evidence_url
        assert config.matches_metadata?(config.metadata, organization_host: "COMMUNITY.EXAMPLE.INVALID",
                                        source_url: "https://WEATHER.EXAMPLE.INVALID:443/feed#cap-example", day: DAY)
        refute config.bound_to?(organization_host: "other.example.invalid", source_url: config.source_url)
        refute config.bound_to?(organization_host: config.organization_host, source_url: "https://weather.example.invalid/other-feed")
      end

      def test_every_field_is_explicit_and_unknown_or_private_fields_are_rejected_without_payload
        authored_review.each_key do |key|
          assert_raises(WeatherRegionConfiguration::InvalidConfiguration) { review(authored_review.reject { |field, _| field == key }) }
        end
        error = assert_raises(WeatherRegionConfiguration::InvalidConfiguration) { review(authored_review.merge("api_token" => "SYNTHETIC_PRIVATE_MARKER")) }
        assert_equal WeatherRegionConfiguration::ERROR, error.message
        assert_nil error.cause
        refute_includes error.message, "SYNTHETIC_PRIVATE_MARKER"
      end

      def test_review_dates_require_current_inclusive_bounded_validity_and_approved_state
        config = review
        assert config.valid_on?(Date.new(2040, 9, 14))
        assert config.valid_on?(Date.new(2041, 9, 14))
        refute config.valid_on?(Date.new(2041, 9, 15))
        [{ "reviewed_on" => "2040-09-17" }, { "valid_until" => "2040-09-15" },
         { "valid_until" => "2040-09-13" }, { "valid_until" => "2042-09-14" },
         { "reviewed_on" => "2040-02-31" }, { "review_state" => "pending" }, { "version" => 1.0 }].each do |changes|
          assert_raises(WeatherRegionConfiguration::InvalidConfiguration) { review(authored_review.merge(changes)) }
        end
        refute config.matches_metadata?(config.metadata, organization_host: config.organization_host, source_url: config.source_url,
                                        day: Date.new(2041, 9, 15))
      end

      def test_changed_review_region_source_or_evidence_cannot_reuse_prior_metadata
        original = review
        [{ "provider_area_code" => "TEST-REGION-B" }, { "region_label" => "Drugi autorski region" },
         { "community_label" => "Druga autorska zajednica" }, { "organization_host" => "other.example.invalid" },
         { "source_url" => "https://other-weather.example.invalid/feed" },
         { "evidence_url" => "https://review.example.invalid/authored-coverage#feature-b" },
         { "reviewed_on" => "2040-09-15" }, { "valid_until" => "2040-12-31" }].each do |changes|
          changed = review(authored_review.merge(changes))
          refute_equal original.identity, changed.identity
          refute changed.matches_metadata?(original.metadata, organization_host: changed.organization_host,
                                           source_url: changed.source_url, day: DAY)
        end
      end

      def test_source_fragments_do_not_change_feed_identity_but_query_and_path_do
        config = review
        same = review(authored_review.merge("source_url" => "https://WEATHER.EXAMPLE.INVALID:443/feed#warning-a"))
        assert_equal config.identity, same.identity
        ["https://weather.example.invalid/feed?community=other", "https://weather.example.invalid/other"].each do |url|
          refute config.bound_to?(organization_host: config.organization_host, source_url: url)
        end
      end

      def test_inherited_coverage_flags_or_partial_metadata_are_never_an_operator_review
        config = review
        [config.metadata.reject { |key, _| key == "weather_region_review_id" },
         config.metadata.merge("coverage_status" => "official_region_geometry_matched"),
         config.metadata.merge("provider_area_code" => "OTHER"), {}].each do |metadata|
          refute config.matches_metadata?(metadata, organization_host: config.organization_host, source_url: config.source_url, day: DAY)
        end
      end

      def test_urls_hosts_labels_and_region_identifiers_are_bounded_and_credential_free
        ["http://weather.example.invalid/feed", "https://reader:example@weather.example.invalid/feed",
         "https://weather.example.invalid:8443/feed", "not a url"].each do |url|
          %w(source_url evidence_url).each do |field|
            assert_raises(WeatherRegionConfiguration::InvalidConfiguration) { review(authored_review.merge(field => url)) }
          end
        end
        ["", "https://community.example.invalid", "community.example.invalid:443", "a..example.invalid", "-bad.example.invalid"].each do |host|
          assert_raises(WeatherRegionConfiguration::InvalidConfiguration) { review(authored_review.merge("organization_host" => host)) }
        end
        [{ "region_label" => "a" * 201 }, { "community_label" => "unsafe\nlabel" }, { "provider_area_code" => "unsafe code" },
         { "region_label" => "\xFF".dup.force_encoding("UTF-8") }].each do |changes|
          assert_raises(WeatherRegionConfiguration::InvalidConfiguration) { review(authored_review.merge(changes)) }
        end
      end

      def test_source_parser_contract_requires_a_review_even_when_the_feed_is_quiet
        assert_raises(WeatherRegionConfiguration::InvalidConfiguration) do
          WeatherRegionConfiguration.for_source(day: DAY, source_url: "https://weather.example.invalid/feed", path: "")
        end
        Tempfile.create(["authored-weather-source-", ".json"]) do |file|
          file.write(JSON.generate(authored_review))
          file.flush
          config = WeatherRegionConfiguration.for_source(day: DAY, source_url: "https://weather.example.invalid/feed", path: file.path)
          assert_equal "TEST-REGION-A", config.provider_area_code
          assert_raises(WeatherRegionConfiguration::InvalidConfiguration) do
            WeatherRegionConfiguration.for_source(day: DAY, source_url: "https://other-weather.example.invalid/feed", path: file.path)
          end
        end
      end

      def test_file_reload_observes_changed_review_without_reusing_cached_identity
        Tempfile.create(["authored-weather-review-", ".json"]) do |file|
          file.write(JSON.generate(authored_review))
          file.flush
          first = WeatherRegionConfiguration.load(day: DAY, path: file.path)
          file.rewind
          file.truncate(0)
          file.write(JSON.generate(authored_review.merge("region_label" => "Drugi autorski region")))
          file.flush
          second = WeatherRegionConfiguration.load(day: DAY, path: file.path)
          refute_equal first.identity, second.identity
          refute second.matches_metadata?(first.metadata, organization_host: second.organization_host, source_url: second.source_url, day: DAY)
        end
      end

      def test_missing_malformed_oversized_or_invalid_encoding_file_has_payload_free_error
        Tempfile.create(["authored-weather-invalid-", ".json"]) do |file|
          ["{SYNTHETIC_PRIVATE_MARKER", "a" * (WeatherRegionConfiguration::MAX_BYTES + 1), "\xFF".b].each do |body|
            file.rewind
            file.truncate(0)
            file.binmode
            file.write(body)
            file.flush
            error = assert_raises(WeatherRegionConfiguration::InvalidConfiguration) { WeatherRegionConfiguration.load(day: DAY, path: file.path) }
            assert_equal WeatherRegionConfiguration::ERROR, error.message
            assert_nil error.cause
            refute_includes error.message, "SYNTHETIC_PRIVATE_MARKER"
          end
          missing = "#{file.path}.missing"
          error = assert_raises(WeatherRegionConfiguration::InvalidConfiguration) { WeatherRegionConfiguration.load(day: DAY, path: missing) }
          refute_includes error.message, missing
        end
      end
    end
  end
end
