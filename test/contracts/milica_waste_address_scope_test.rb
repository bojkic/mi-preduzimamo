# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/access"
require "active_support/core_ext/enumerable"
require "i18n"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/city/matching")
require File.join(engine_root, "app/services/decidim/bih/city/waste_schedule")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/procedure_runner")
require File.join(engine_root, "lib/decidim/bih/transliterator")
require_relative "../../app/services/decidim_app/bijeljina/waste_schedule"
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/source_refresh_budget"
require_relative "../../app/services/decidim_app/bijeljina/city_service_source_check_store"
require_relative "../../app/services/decidim_app/bijeljina/milica/reference_read"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"
require_relative "../support/synthetic_waste_schedule"

# Actual parser and ReadPort, independently authored routes; no real GIS,
# source programme, Rails boot, database or network.
class MilicaWasteAddressScopeTest < Minitest::Test
  include SyntheticWasteSchedule

  def setup
    install_synthetic_waste_schedule
    owner = DecidimApp::Bijeljina::WasteSchedule
    specs = [
      ["authored-numbered", "Измишљена врба бр.41Р, 57", 6, 1, 14],
      ["authored-plain", "Измишљена врба", 8, 5, 15],
      ["authored-lipa", "Измишљена липа", 6, 1, 14],
      ["authored-village", "Измишљено село", 5, 1, 16],
      ["authored-oak", "Измишљени храст", 10, 2, 16],
      ["authored-date-a", "4. јануара", 9, 3, 17],
      ["authored-date-b", "12. маја", 9, 4, 17],
      ["authored-date-c", "16. јула", 5, 2, 17],
      ["authored-date-d", "22. августа", 4, 1, 17],
      ["authored-date-e", "6. октобра", 8, 3, 17],
      ["authored-same-a", "9. фебруара", 4, 3, 18],
      ["authored-same-b", "9. фебруара", 10, 4, 18],
      ["authored-unresolved-a", "Измишљени јоргован", 9, 2, 19],
      ["authored-unresolved-b", "Измишљени јоргован", 9, 4, 20]
    ]
    rows = specs.map do |id, place, district, weekday, page|
      { "id" => id, "place" => place, "district" => district, "weekday" => weekday,
        "scope" => "household", "route_kind" => "household", "aliases" => [], "source_pdf_page" => page }
    end
    registry = { "captured_on" => "2040-09-14", "valid_from" => "2040-01-01", "valid_until" => "2040-12-31",
      "timezone" => "Europe/Sarajevo", "provider" => "IZMIŠLJENA komunalna služba", "rows" => rows,
      "exceptions" => [], "unresolved_identity_groups" => [{ "row_ids" => %w(authored-unresolved-a authored-unresolved-b),
        "reason" => "Authored segments lack reviewed identity resolution" }] }
    File.write(owner::ROUTE_REGISTRY_PATH, JSON.generate(registry))
    sources = DecidimApp::Bijeljina::CityServiceSources
    @prior_waste_sources = sources::SOURCES
    source = sources::REFERENCE_SOURCES.find { |row| row.fetch(:key) == "waste_schedule" }.deep_dup.merge(
      enabled: true, provider: "IZMIŠLJENA komunalna služba", label: "Izmišljeni raspored",
      source_url: owner::DEFAULT_SCHEDULE_URL)
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, [source.freeze].freeze)
  end

  def teardown
    if defined?(@prior_waste_sources)
      sources = DecidimApp::Bijeljina::CityServiceSources
      sources.send(:remove_const, :SOURCES)
      sources.const_set(:SOURCES, @prior_waste_sources)
    end
    restore_synthetic_waste_schedule
  end

  def test_bare_street_preserves_both_reviewed_household_segments
    ["Izmišljena vrba", "Измишљена врба", "ulica Izmisljena vrba", "Izmišljena vrba, Bijeljina"].each do |query|
      result = lookup.resolution_for(query)
      assert_equal :ambiguous, result[:status], query
      assert_equal [6, 8], result[:candidates].map { |row| row[:district] }.sort
      assert_nil lookup.collection_days_for(query)
    end
  end

  def test_only_source_listed_individual_numbers_select_monday
    ["Izmišljena vrba 41R", "Измишљена врба бр.41Р", "ulica Izmišljena vrba broj 57", "Измишљена врба 57"].each do |query|
      result = lookup.resolution_for(query, on: Date.new(2040, 9, 15))
      assert_equal :ok, result[:status], query
      assert_equal ["ponedjeljak"], result[:days]
      assert_equal(["authored-numbered"], result[:rows].map { |row| row.fetch("id") })
      assert_equal([14], result[:rows].map { |row| row.fetch("source_pdf_page") })
    end
  end

  def test_unlisted_numbers_and_unreviewed_ranges_do_not_infer_friday
    ["Izmišljena vrba 41", "Izmišljena vrba 41A", "Izmišljena vrba 42", "Izmišljena vrba 41R-57", "Izmišljena vrba br.41R–57", "Izmišljena vrba 57 i Druga ulica"].each do |query|
      assert_equal :ambiguous, lookup.resolution_for(query)[:status], query
      assert_nil lookup.collection_days_for(query)
    end
  end

  def test_source_script_numbered_street_names_and_rural_schedules_remain_exact
    assert_equal ["ponedjeljak"], lookup.collection_days_for("Измишљена врба бр.41Р, 57")
    assert_equal ["petak"], lookup.collection_days_for("Rejon 8 Izmišljena vrba")
    assert_equal ["ponedjeljak"], lookup.collection_days_for("Rejon 6 Izmišljena lipa")
    assert_equal ["ponedjeljak"], lookup.collection_days_for("Измишљено село")
    assert_equal ["utorak"], lookup.collection_days_for("Rejon 10 Измишљени храст")
    ["4. јануара", "12.маја", "16.јула", "22.августа", "6.октобра"].each do |query|
      assert_equal :ok, lookup.resolution_for(query)[:status], query
    end
    same_named_street = lookup.resolution_for("9.фебруара")
    assert_equal :ambiguous, same_named_street[:status]
    assert_equal [4, 10], same_named_street.fetch(:candidates).map { |row| row.fetch(:district) }.sort
    assert_equal :ok, lookup.resolution_for("Rejon 4 9.фебруара")[:status]
    assert_equal :ok, lookup.resolution_for("Rejon 10 9.фебруара")[:status]
    assert_equal :unknown, lookup.resolution_for("nepostojeća ulica")[:status]
    assert_equal :unavailable, lookup.resolution_for("Izmišljena vrba 57", on: Date.new(2041, 1, 1))[:status]
  end

  def test_citizen_district_cannot_override_reviewed_house_number_scope
    ["Rejon 8 Izmišljena vrba 57", "Рејон 8 Измишљена врба бр.41Р", "Rejon 8 Izmišljena vrba 42",
     "Rejon 6 Izmišljena vrba br.41R–57", "Rejon 6 Izmišljena vrba 41"].each do |query|
      assert_equal :ambiguous, lookup.resolution_for(query)[:status], query
      assert_nil lookup.collection_days_for(query)
    end
    assert_equal ["ponedjeljak"], lookup.collection_days_for("Rejon 6 Izmišljena vrba 57")
    result = read("Rejon 8 Izmišljena vrba 57")
    assert_equal "ambiguous", result.status
    assert_empty result.facts
    assert_includes result.warnings, "waste_district_or_street_segment_required"
  end

  def test_reviewed_city_and_street_prefixes_cannot_hide_numbered_exceptions
    ["Bijeljina, Izmišljena vrba 57", "u Ulici Izmišljena vrba 57", "у улици Измишљена врба бр.41Р",
     "u Bijeljini u ulici Izmišljena vrba 57"].each do |query|
      assert_equal ["ponedjeljak"], lookup.collection_days_for(query), query
      assert_equal ["ponedjeljak"], read(query).facts.first.fetch("coverage").fetch("collection_days"), query
    end
    ["Rejon 8 Bijeljina, Izmišljena vrba 57", "Bijeljina, Izmišljena vrba 42", "u ulici Izmišljena vrba br.41R–57",
     "Bijelina, Izmišljena vrba 57", "Izmišljeno selo 2", "Rejon 6 Izmišljena lipa 7"].each do |query|
      assert_equal :ambiguous, lookup.resolution_for(query)[:status], query
      assert_nil lookup.collection_days_for(query)
      assert_empty read(query).facts, query
    end
  end

  def test_every_reviewed_exact_district_row_retains_its_day_provenance_and_unresolved_conflicts
    assert_operator lookup.registry.fetch("unresolved_identity_groups").size, :>, 0
    assert_equal "IZMIŠLJENA komunalna služba", lookup.source_provider
    lookup.registry.fetch("rows").each do |row|
      query = "Rejon #{row.fetch("district")} #{row.fetch("place")}"
      result = lookup.resolution_for(query)
      conflict = lookup.registry.fetch("unresolved_identity_groups", []).find { |group| group.fetch("row_ids").include?(row.fetch("id")) }
      assert_equal conflict ? :conflicting : :ok, result[:status], query
      if conflict
        assert_equal conflict.fetch("reason"), result[:identity_note], query
        assert_includes result[:warnings], "source_street_segments_unresolved", query
      end
      assert_includes result[:rows], row, query
      assert_includes result[:days], lookup.class::WEEK_ORDER.fetch(row.fetch("weekday") - 1), query
    end
  end

  def test_actual_reader_never_emits_an_unqualified_friday_fact
    result = read("Izmišljena vrba")
    assert_equal "ambiguous", result.status
    assert_empty result.facts
    assert_includes result.warnings, "waste_district_or_street_segment_required"
    assert_equal [6, 8], result.coverage.fetch("matching_districts").sort
    result = read("Izmišljena vrba 57")
    assert_equal "ok", result.status
    fact = result.facts.fetch(0)
    assert_equal ["ponedjeljak"], fact.fetch("coverage").fetch("collection_days")
    assert_includes fact.fetch("text"), "ponedjeljak"
    assert_match(%r{\Ahttps://community\.example\.invalid/}, fact.fetch("source_url"))
    assert_equal lookup.source_url, fact.fetch("source_url")
    assert_equal fact.fetch("source_url"), result.source.fetch("url")
    assert_equal false, result.validity.fetch("holiday_exceptions")
    registry = lookup.registry
    configured = registry.delete("provider")
    assert_equal "Odvoz otpada zajednice", lookup.source_provider
    registry["provider"] = "  "
    assert_equal "Odvoz otpada zajednice", lookup.source_provider
    registry["provider"] = configured
  end

  private

  def lookup = DecidimApp::Bijeljina::WasteSchedule.default

  def read(query)
    prior_backend = I18n.backend
    prior_locales = I18n.available_locales
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
    I18n.backend.load_translations(*Dir[File.join(root, "config/locales/*.yml")])
    unused = Object.new
    reader = DecidimApp::Bijeljina::Milica::ReadPort.new(organization: Struct.new(:id).new(71), event_feed: unused,
                                                         source_checker: unused, timetable: unused, area_matcher: unused,
                                                         directory: unused, duplicate_finder: unused, waste_schedule: lookup)
    reader.define_singleton_method(:log_failure) { |error, _action| raise error }
    context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(organization_id: 71,
                                                                               conversation_key: "c" * 64, capabilities: ["public_reads"], now: Time.utc(2040, 9, 15))
    reader.call(action: "ask_information", topic: "waste", entities: { "area_query" => query, "query" => "Kada je redovan odvoz?" }, context:)
  ensure
    I18n.backend = prior_backend
    I18n.available_locales = prior_locales
  end
end
