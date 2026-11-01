# frozen_string_literal: true

# Standalone Minitest has refute helpers, without ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "i18n"
require_relative "../support/isolated_i18n_backend"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/enumerable"
require "action_controller"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "lib/decidim/bih/transliterator")
require_relative "../../app/services/decidim_app/bijeljina/city_service_source_check_store"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/source_measurement"
require_relative "../../app/services/decidim_app/bijeljina/milica/source_read"

# Actual prepared-source selection and shaping with synthetic public readings.
# No Rails boot, database, source HTTP, Redis, model, or citizen records.
class MilicaWaterLevelAnswerTest < Minitest::Test
  SourceRead = DecidimApp::Bijeljina::Milica::SourceRead
  Collector = DecidimApp::Bijeljina::CityServiceNoticeCollector
  Context = Data.define(:now, :organization_id, :deadline, :public_reads) do
    def allows?(capability) = capability == "public_reads" && public_reads
  end
  NOW = Time.utc(2026, 9, 9, 12)
  OBSERVED = "2026-09-09T12:00:00+02:00"
  SOURCE_URL = "https://water.example.invalid/readings"

  def setup
    sources = DecidimApp::Bijeljina::CityServiceSources
    @prior_water_sources = sources::SOURCES
    # Explicit authored adapter descriptors: production defaults stay disabled.
    rows = sources::REFERENCE_SOURCES.map do |row|
      url = case row.fetch(:key)
            when "water_levels" then SOURCE_URL
            when "air_quality_realtime" then "https://air.example.invalid/readings"
            else "https://#{row.fetch(:key).tr('_', '-')}.example.invalid/readings"
            end
      row.deep_dup.merge(enabled: row.fetch(:enabled, true),
        label: "Izmišljeni izvor", provider: "Izmišljeni pružalac", source_url: url).freeze
    end
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, rows.freeze)
    assert_equal SOURCE_URL, sources.fetch("water_levels").fetch(:source_url)
    @previous_backend = I18n.backend
    @previous_locales = I18n.available_locales
    I18n.backend = MiTestSupport::IsolatedI18nBackend.new
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    # Fixture messages keep the test independent of the lead-owned locale patch.
    # Production translation coverage is verified at integration by that owner.
    I18n.available_locales.each do |locale|
      I18n.backend.store_translations(locale, decidim: { bih: { dialogue: {
                                        water_level_value: "%{station}: %{value} %{unit}.",
                                        water_level_trend_unavailable: "TREND_NOT_SUPPORTED_BY_SNAPSHOT.",
                                        water_level_aggregator_limit: "SECONDARY_SOURCE_NOT_FLOOD_RISK_ASSESSMENT.",
                                        water_level_observation_time_unknown: "MEASUREMENT_TIME_UNKNOWN."
                                      } } }, decidim_app: { city_service_events: { bot: { unconfirmed_facts: "UNCONFIRMED." } } })
    end
    @checks = []
    @calls = []
    @context = Context.new(NOW, 71, nil, true)
  end

  def teardown
    sources = DecidimApp::Bijeljina::CityServiceSources
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, @prior_water_sources)
    I18n.backend = @previous_backend
    I18n.available_locales = @previous_locales
  end

  def test_named_river_inflections_filter_before_limit_without_inventing_trend
    rows = 9.times.map { |index| reading("Rijeka Sava (Stanica #{index})") } + [reading("Rijeka Drina (Testni most)")]
    prepare(rows)
    ["Da li voda raste u Drini?", "Расте ли вода у Дрини?", "Kakav je vodostaj Drine?"].each do |query|
      result = read(query:)
      assert_equal "ok", result[:status]
      assert_equal(["Rijeka Drina (Testni most)"], result[:facts].map { |fact| fact["station"] })
      assert_equal "water_level_v1", result[:validity]["answer_shape"]
      fact = result[:facts].first
      assert_equal 32, fact["value"]
      assert_equal "cm", fact["unit"]
      assert_equal OBSERVED, fact["observed_at"]
      assert_equal SOURCE_URL, fact["source_url"]
      assert_equal "secondary_aggregator", fact["authority"]
      assert_includes fact["text"], "TREND_NOT_SUPPORTED" if query.include?("raste") || query.include?("Расте")
      assert_includes fact["text"], "NOT_FLOOD_RISK"
      assert_equal 30, @calls.last.fetch(:max_items)
    end
  end

  def test_explicit_station_and_two_river_request_preserve_the_requested_identity
    prepare([reading("Rijeka Sava (Izmišljena brana)"), reading("Rijeka Drina (Testni most)"), reading("Rijeka Drina (Testni rukavac)")])
    station = read(query: "Vodostaj Drine, stanica Testni most")
    assert_equal(["Rijeka Drina (Testni most)"], station[:facts].map { |fact| fact["station"] })
    assert_equal 3, read(query: "Vodostaji na Savi i Drini")[:facts].size
    assert_equal 2, read(query: "Vodostaj", area: "Drini")[:facts].size
    assert_equal 2, read(query: "Vodostaj", area: "u rijeci Drini")[:facts].size
    assert_equal 1, read(query: "Vodostaj", area: "Testni most")[:facts].size
    assert_equal 1, read(query: "Vodostaj Drine", area: "Testni most")[:facts].size
  end

  def test_neighborhood_qualifier_or_missing_river_does_not_return_an_unrelated_station
    prepare([reading("Rijeka Sava (Izmišljena brana)")])
    [read(query: "Da li Drina raste?"), read(query: "Vodostaj Save u Izmišljenom polju", area: "Izmišljeno polje")].each do |result|
      assert_equal "ambiguous", result[:status]
      assert_empty result[:facts]
      assert_includes result[:warnings], "requested_area_not_supported_by_source"
    end
  end

  def test_unknown_time_and_unconfirmed_source_remain_explicit_and_raw_change_text_is_not_evidence
    prepare([reading("Rijeka Drina (Testni most)", observed_at: nil)], status: :unreviewed)
    result = read(query: "Da li Drina raste?")
    fact = result[:facts].first
    assert_nil fact["observed_at"]
    assert_includes fact["text"], "MEASUREMENT_TIME_UNKNOWN"
    assert_includes fact["text"], "UNCONFIRMED"
    assert_includes fact["text"], "TREND_NOT_SUPPORTED"
    refute_includes fact["text"], "+30"
    assert_includes result[:warnings], "measurement_time_unknown"
    assert_includes result[:warnings], "source_facts_unconfirmed"
    assert_equal NOW.iso8601, result[:checked_at]
  end

  def test_stale_future_and_conflicting_measurements_keep_existing_guards
    prepare([reading("Rijeka Drina (Testni most)", observed_at: "2026-09-01T12:00:00+02:00")])
    stale = read(query: "Da li Drina raste?")
    assert_equal "stale", stale[:status]
    assert_empty stale[:facts]
    assert_includes stale[:warnings], "measurement_stale"

    prepare([reading("Rijeka Drina (Testni most)", observed_at: "2026-09-10T12:00:00+02:00")])
    future = read(query: "Da li Drina raste?")
    assert_empty future[:facts]
    assert_includes future[:warnings], "measurement_time_in_future"

    prepare([reading("Rijeka Drina (Testni most)", value: 32), reading("Rijeka Drina (Testni most)", value: 33)])
    conflict = read(query: "Da li Drina raste?")
    assert_equal "unreviewed", conflict[:status]
    assert_equal([32, 33], conflict[:facts].map { |fact| fact["value"] })
    assert_includes conflict[:warnings], "conflicting_current_facts"
    assert_includes conflict[:facts].first["text"], "TREND_NOT_SUPPORTED"
  end

  def test_generic_water_question_keeps_both_rivers_but_only_one_scope_caveat
    prepare([reading("Rijeka Drina (Testni most)"), reading("Rijeka Sava (Izmišljena brana)")])
    result = read(query: "Kakvi su vodostaji?")
    assert_equal 2, result[:facts].size
    combined = result[:facts].map { |fact| fact["text"] }.join(" ")
    assert_equal 1, combined.scan("NOT_FLOOD_RISK").length
    refute_includes combined, "TREND_NOT_SUPPORTED"
    assert_equal([OBSERVED, OBSERVED], result[:facts].map { |fact| fact["observed_at"] })
  end

  def test_no_read_authority_means_no_source_lookup
    @context = Context.new(NOW, 71, nil, false)
    result = read(query: "Da li Drina raste?")
    assert_equal "not_authorized", result[:status]
    assert_empty @calls
  end

  def test_non_water_observation_path_is_not_shaped_or_filtered_by_river_text
    notice = Collector::Notice.new(source_key: "air_quality_realtime", title: "Public air reading", body: "Public air data",
                                   url: "https://air.example.invalid/readings", fingerprint: "synthetic-public-air", fetched_at: NOW,
                                   metadata: { "kind" => "air_quality_observation", "pollutant" => "PM2.5", "value" => 13,
                                               "unit" => "µg/m³", "observed_at" => OBSERVED })
    @checks = [Collector::SourceCheckResult.new(source_key: "air_quality_realtime", status: :ok, notices: [notice], checked_at: NOW)]
    result = read(query: "Kakav je vazduh kod Drine?", topic: "air_quality")
    assert_equal "ok", result[:status]
    assert_equal "air_quality_observation", result[:facts].first["kind"]
    assert_includes result[:facts].first["text"], "nije službeno mjerenje"
    assert_equal OBSERVED, result[:facts].first["observed_at"]
    assert_nil result[:validity]["answer_shape"]
  end

  private

  def reading(station, observed_at: OBSERVED, value: 32)
    { "station" => station, "value" => value, "unit" => "cm", "observed_at" => observed_at }
  end

  def prepare(rows, status: :ok)
    notice = Collector::Notice.new(source_key: "water_levels", title: "Public river readings", body: "Source says change +30 cm; not a verified series",
                                   url: SOURCE_URL, fingerprint: "synthetic-public-reading", fetched_at: NOW,
                                   metadata: { "readings" => rows })
    @checks = [Collector::SourceCheckResult.new(source_key: "water_levels", status:, notices: [notice], checked_at: NOW)]
  end

  def read(query:, area: nil, topic: "water_levels")
    receiver = self
    checker = Object.new
    checker.define_singleton_method(:check) do |**options|
      receiver.instance_variable_get(:@calls) << options
      receiver.instance_variable_get(:@checks)
    end
    SourceRead.new(source_checker: checker).call(topic:, context: @context, locale: "sr",
                                                 entities: { "query" => query, "area_query" => area })
  end
end

# rubocop:enable Rails/RefuteMethods
