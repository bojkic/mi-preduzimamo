# frozen_string_literal: true

# Standalone Minitest has refute helpers, without ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "i18n"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/contracts")
require_relative "../../app/services/decidim_app/bijeljina/city_service_area_matcher"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

# Real public ReadPort and global name resolver; only the public catalog and
# mount-path adapter are synthetic. No Rails boot, database or citizen records.
class MilicaPublicAreaReadTest < Minitest::Test
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  Area = Data.define(:id, :kind, :slug, :name, :decidim_organization_id, :boundary) do
    def translated_name
      Decidim::Bih::Transliterator.localize(name.fetch("sr"), locale: I18n.locale.to_s)
    end
  end
  Catalog = Data.define(:rows) do
    def order(*) = self

    def to_a = rows
  end

  def setup
    @prior_backend = I18n.backend
    @prior_locales = I18n.available_locales
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    I18n.backend.load_translations(File.expand_path("../../config/locales/milica_directory_answers.yml", __dir__))
    @temporary_catalog = !Decidim::Bih.const_defined?(:LocalArea, false)
    if @temporary_catalog
      Decidim::Bih.const_set(:LocalArea, Class.new do
        def self.where(*) = raise "Unconfigured public catalog"
      end)
    end
    @temporary_path = !Decidim::Bih.respond_to?(:public_path)
    Decidim::Bih.define_singleton_method(:public_path) { |_| raise "Unconfigured mount path" } if @temporary_path
  end

  def teardown
    Decidim::Bih.send(:remove_const, :LocalArea) if @temporary_catalog
    Decidim::Bih.singleton_class.send(:remove_method, :public_path) if @temporary_path
    I18n.backend = @prior_backend
    I18n.available_locales = @prior_locales
  end

  def test_unique_reviewed_alias_preserves_public_mz_map_script_and_provenance
    [["Ledinci", "sr"], ["Лединци", "sr-Cyrl"], ["mjesna zajednica Ledinci", "bs"]].each do |query, locale|
      result = read(rows: [area], entities: { "area_query" => query }, locale:)
      fact = result.facts.fetch(0)

      assert_equal "ok", result.status
      assert_equal "mz", fact.fetch("area_kind")
      assert_equal "local_area:12", fact.fetch("source_id")
      assert_equal "local_area_registry", result.source.fetch("id")
      assert_equal "/biceriseno/mjesne-zajednice/mz-ledinci", fact.fetch("destination")
      assert_equal "explicit_name", fact.fetch("coverage").fetch("resolution_source")
      assert_equal I18n.t("decidim_app.milica.directory_answers.public_mz_map", name: area.translated_name, locale:), fact.fetch("text") if locale != "sr-Cyrl"
      assert_includes fact.fetch("text"), "није избор твог комшилука" if locale == "sr-Cyrl"
      assert_includes result.warnings, "area_selection_grants_no_membership"
      assert_equal [{ decidim_organization_id: 71 }], @queries
    end
  end

  def test_no_match_or_ambiguous_mz_names_never_choose_a_candidate
    missing = read(rows: [area], entities: { "area_query" => "Unknown place" })
    assert_equal "empty", missing.status
    assert_empty missing.facts

    ambiguous = read(rows: [area, area(id: 13, slug: "mz-ledinci-drugi")], entities: { "area_query" => "Ledinci" })
    assert_equal "ambiguous", ambiguous.status
    assert_equal ["area_name_ambiguous"], ambiguous.warnings
    assert_empty ambiguous.facts
  end

  def test_explicit_mz_query_excludes_foreign_tenant_and_same_name_komsiluk
    excluded = [area(id: 13, organization_id: 72),
                area(id: 14, kind: "komsiluk", slug: "komsiluk-14", name: "Ledinci (prijedlog)")]
    result = read(rows: excluded, entities: { "area_query" => "MZ Ledinci" })
    assert_equal "empty", result.status
    assert_empty result.facts
    assert_equal [{ decidim_organization_id: 71 }, { decidim_organization_id: 71, kind: "mz" }], @queries

    result = read(rows: excluded + [area], entities: { "area_query" => "MZ Ledinci" })
    assert_equal "ok", result.status
    assert_equal(["local_area:12"], result.facts.map { |fact| fact.fetch("source_id") })
    assert_equal "mz", result.facts.fetch(0).fetch("area_kind")
    assert_equal 71, result.coverage.fetch("organization_id")
    assert_equal [{ decidim_organization_id: 71 }], @queries
    assert_includes result.warnings, "area_selection_grants_no_membership"
  end

  def test_bare_cross_kind_name_is_ambiguous_without_mz_fallback_or_membership
    komsiluk = area(id: 14, kind: "komsiluk", slug: "komsiluk-14", name: "Ledinci (prijedlog)")
    %w(Ledinci Лединци).each do |query|
      result = read(rows: [area, komsiluk, area(id: 15, organization_id: 72)], entities: { "area_query" => query })
      assert_equal "ambiguous", result.status
      assert_empty result.facts
      assert_equal ["area_name_ambiguous"], result.warnings
      assert_equal %w(komsiluk mz), result.candidates.map { |candidate| candidate.fetch("area_kind") }.sort
      assert_equal ["local_area:12", "local_area:14"], result.candidates.map { |candidate| candidate.fetch("source_id") }.sort
      assert_equal [{ decidim_organization_id: 71 }], @queries
    end
  end

  def test_direct_mz_match_gets_map_but_absent_boundary_or_unsafe_slug_never_does
    direct = read(rows: [area], entities: { "area_slug" => "mz-ledinci" })
    assert_equal "/biceriseno/mjesne-zajednice/mz-ledinci", direct.facts.fetch(0).fetch("destination")
    assert_equal [{ decidim_organization_id: 71 }], @queries

    [area(boundary: nil), area(boundary: {}), area(slug: "mz-ledinci/../private")].each do |record|
      result = read(rows: [record], entities: { "area_slug" => record.slug }, locale: "en")
      fact = result.facts.fetch(0)
      assert_equal "ok", result.status
      refute fact.has_key?("destination")
      assert_includes fact.fetch("text"), "no available public boundary map"
      assert_includes fact.fetch("text"), "does not select your komšiluk or grant access"
    end
  end

  def test_non_mz_and_explicit_unknown_slug_do_not_get_mz_fallback_or_map
    record = area(kind: "komsiluk", slug: "komsiluk-12", name: "Komšiluk 12")
    result = read(rows: [record], entities: { "area_slug" => record.slug })
    assert_equal "komsiluk", result.facts.fetch(0).fetch("area_kind")
    refute result.facts.fetch(0).has_key?("destination")

    result = read(rows: [area], entities: { "area_slug" => "mz-unknown", "area_query" => "Ledinci" })
    assert_equal "empty", result.status
    assert_equal [{ decidim_organization_id: 71 }], @queries
    assert_empty result.facts
  end

  def test_public_read_permission_and_private_board_remain_excluded_before_any_catalog_access
    [["choose_area", []], ["neighborhood_information", ["public_reads"]]].each do |action, capabilities|
      result = read(rows: [area], entities: { "area_query" => "Ledinci" }, action:, capabilities:)
      assert_equal "not_authorized", result.status
      assert_empty result.facts
      assert_empty @queries
    end
  end

  private

  def area(id: 12, kind: "mz", slug: "mz-ledinci", name: "MZ Ledinci", organization_id: 71, boundary: { "type" => "Polygon" }) # rubocop:disable Metrics/ParameterLists
    Area.new(id, kind, slug, { "sr" => name }, organization_id, boundary)
  end

  def read(rows:, entities:, action: "choose_area", locale: "sr", capabilities: ["public_reads"])
    organization = Data.define(:id).new(71)
    context = Contracts::TrustedContext.new(organization_id: organization.id, conversation_key: "c" * 64,
                                            capabilities:, now: Time.utc(2026, 9, 9, 12))
    @queries = []
    query = lambda do |**scope|
      @queries << scope
      Catalog.new(rows.select { |row| scope.all? { |key, value| row.public_send(key) == value } })
    end
    matcher = DecidimApp::Bijeljina::CityServiceAreaMatcher.new(organization:)
    unused = Object.new
    port = DecidimApp::Bijeljina::Milica::ReadPort.new(organization:, area_matcher: matcher, event_feed: unused,
                                                       source_checker: unused, timetable: unused, directory: unused,
                                                       duplicate_finder: unused, waste_schedule: unused)
    Decidim::Bih::LocalArea.stub(:where, query) do
      Decidim::Bih.stub(:public_path, ->(suffix) { "/biceriseno/#{suffix}" }) do
        port.call(action:, topic: "neighborhood", entities:, context:, locale:)
      end
    end
  end
end

# rubocop:enable Rails/RefuteMethods
