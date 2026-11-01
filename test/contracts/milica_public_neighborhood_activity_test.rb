# frozen_string_literal: true

# Standalone Minitest does not provide ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "i18n"
require_relative "../../app/services/decidim_app/bijeljina/milica/public_neighborhood_activity"

engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine, "app/presenters/decidim/bih/report_service_request")
require File.join(engine, "app/presenters/decidim/bih/report_status_presenter")

class MilicaPublicNeighborhoodActivityTest < Minitest::Test
  Reader = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity
  Area = Data.define(:slug, :kind, :decidim_organization_id, :boundary)
  Report = Data.define(*Reader::COLUMNS) do
    def duplicate? = duplicate_of_report_id.present?
  end
  class Scope
    attr_reader :calls

    def initialize(records)
      @records = records
      @calls = []
    end

    [:where, :select, :order, :limit].each do |method|
      define_method(method) do |*arguments|
        @calls << [method, arguments]
        self
      end
    end

    def to_a = @records
  end

  def setup
    @old_backend = I18n.backend
    @old_locales = I18n.available_locales
    @old_locale = I18n.locale
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = [:sr]
    I18n.locale = :sr # rubocop:disable Rails/I18nLocaleAssignment -- test restores the caller locale in teardown
    I18n.backend.store_translations(:sr, decidim: { bih: { dialogue: {
                                      neighborhood_report_fact: "%{reference}: %{category} — %{status} (%{date})",
                                      neighborhood_reports_source: "MI javne prijave"
                                    } } })
    @temporary_report = !Decidim::Bih.const_defined?(:Report, false)
    Decidim::Bih.const_set(:Report, Class.new) if @temporary_report
    Decidim::Bih::Report.const_set(:STATUSES, %w(primljeno proslijedjeno u_obradi rijeseno odbijeno)) if @temporary_report
    Decidim::Bih::Report.const_set(:TERMINAL_STATUSES, %w(rijeseno odbijeno)) if @temporary_report
    @temporary_path = !Decidim::Bih.respond_to?(:public_path)
    Decidim::Bih.define_singleton_method(:public_path) { |suffix| "/biceriseno/#{suffix}" } if @temporary_path
    @now = Time.utc(2026, 9, 9, 12)
    @ring = [[19, 44], [20, 44], [20, 45], [19, 45], [19, 44]]
    @area = Area.new("komsiluk-12", "komsiluk", 71, { "type" => "Polygon", "coordinates" => [@ring] })
    @scope = Scope.new([])
  end

  def teardown
    Decidim::Bih.send(:remove_const, :Report) if @temporary_report
    Decidim::Bih.singleton_class.send(:remove_method, :public_path) if @temporary_path
    I18n.backend = @old_backend
    I18n.available_locales = @old_locales
    I18n.locale = @old_locale # rubocop:disable Rails/I18nLocaleAssignment -- restore the caller locale after the isolated backend
  end

  def test_all_tenant_lifecycle_time_and_geometry_predicates_precede_projection_and_limit
    result = read
    assert_equal "empty", result.status
    assert_includes result.warnings, "no_matching_public_reports"
    assert_equal [:where, :where, :where, :where, :select, :order, :limit], @scope.calls.map(&:first)
    assert_equal [{ decidim_organization_id: 71, status: Decidim::Bih::Report::STATUSES, removed_from_public_at: nil }], @scope.calls[0][1]
    assert_equal [{ created_at: (@now - 7.days)...@now }], @scope.calls[1][1]
    assert_includes @scope.calls[2][1].first, "latitude BETWEEN -90 AND 90"
    assert_includes @scope.calls[3][1].first, "point(longitude, latitude) <@ CAST(? AS polygon)"
    assert_equal Reader::COLUMNS, @scope.calls[4][1]
    assert_equal [4], @scope.calls.last[1]
    assert_equal true, result.coverage["located_only"]
    assert_equal "komsiluk-12", result.coverage["area_label"]
  end

  def test_projection_is_bounded_public_metadata_and_never_reports_citywide_totals
    @scope = Scope.new((1..4).map { |id| Report.new(id, "BR-2026-#{format("%04d", id)}", "putevi", "primljeno", nil, "pending", nil, nil, @now - id.hours) })
    result = read
    assert_equal "ok", result.status
    assert_equal 3, result.facts.length
    assert_equal true, result.coverage["truncated"]
    assert_includes result.warnings, "public_reports_truncated"
    assert_equal(%w(public_report:BR-2026-0001 public_report:BR-2026-0002 public_report:BR-2026-0003), result.facts.map { |fact| fact["id"] })
    assert(result.facts.all? { |fact| fact["kind"] == "area_public_report" && fact["destination"].match?(%r{\A/biceriseno/prijave/BR-2026-\d{4}\z}) })
    forbidden = %w(description address latitude longitude reporter_email reporter_phone decidim_user_id status_token status_note internal_note)
    assert_empty result.facts.flat_map(&:keys) & forbidden
    refute result.coverage.has_key?("total")
  end

  def test_current_location_uses_actual_komsiluk_polygon_not_its_independently_resolved_mz
    mz = Area.new("mz-ledinci", "mz", 71, @area.boundary)
    assert_equal "komsiluk-12", read(areas: [mz, @area]).coverage["area_slug"]
    assert_equal "mz", read(areas: [mz]).coverage["area_kind"]
  end

  def test_missing_cross_tenant_ambiguous_and_malformed_boundaries_fail_without_querying_reports
    bad = @area.with(decidim_organization_id: 72)
    [[], [bad], [@area, bad], [@area, @area.with(slug: "komsiluk-13")], [@area.with(boundary: nil)]].each do |areas|
      @scope = Scope.new([])
      result = read(areas:)
      assert_equal "unavailable", result.status
      assert_includes result.warnings, "public_reports_area_unavailable"
      assert_empty @scope.calls
    end
  end

  def test_explicit_date_limits_report_creation_to_requested_day_and_never_predicts_future_reports
    read(explicit_time: true, starts_at: @now - 2.days, ends_at: @now - 1.day)
    assert_equal [{ created_at: (@now - 2.days)...(@now - 1.day) }], @scope.calls[1][1]
    @scope = Scope.new([])
    result = read(explicit_time: true, starts_at: @now + 1.day, ends_at: @now + 2.days)
    assert_equal "empty", result.status
    assert_empty @scope.calls
  end

  def test_polygon_holes_multipolygons_and_invalid_geometry_are_handled_before_sql
    reader = Reader.new(organization: Data.define(:id).new(71))
    hole = [[19.2, 44.2], [19.4, 44.2], [19.4, 44.4], [19.2, 44.4], [19.2, 44.2]]
    geometry = { "type" => "MultiPolygon", "coordinates" => [[@ring, hole], [@ring]] }
    sql, *values = reader.geometry_predicate(geometry)
    assert_equal 3, values.length
    assert_equal 3, sql.count("?")
    assert_includes sql, "NOT (point(longitude, latitude)"
    assert_includes sql, " OR "
    assert_equal "((19,44),(20,44),(20,45),(19,45),(19,44))", values.first
    [nil, {}, { "type" => "Point", "coordinates" => [19, 44] },
     { "type" => "Polygon", "coordinates" => [@ring[0..2]] },
     { "type" => "Polygon", "coordinates" => [[[0, 0], [1, 1], [2, 2], [0, 0]]] },
     { "type" => "Polygon", "coordinates" => [[[Float::NAN, 0], *@ring]] },
     { "type" => "MultiPolygon", "coordinates" => Array.new(65) { [@ring] } }].each do |invalid|
      assert_nil reader.geometry_predicate(invalid)
    end
  end

  private

  def read(areas: [@area], explicit_time: false, starts_at: @now, ends_at: @now + 12.hours)
    Reader.new(organization: Data.define(:id).new(71), report_scope: @scope)
          .call(areas:, now: @now, starts_at:, ends_at:, explicit_time:, locale: :sr)
  end
end

# rubocop:enable Rails/RefuteMethods
