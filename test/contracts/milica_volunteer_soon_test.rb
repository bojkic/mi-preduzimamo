# frozen_string_literal: true

# Standalone Minitest has refute helpers, without ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "i18n"
require "json"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/json"
require "active_record"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require_relative "../../app/services/decidim_app/bijeljina/milica/platform_catalog_read"

# Actual parsing, validity and recurring Arel predicate construction only.
# No Rails application, database connection, source fetches or model records.
class MilicaVolunteerSoonTest < Minitest::Test
  Reader = DecidimApp::Bijeljina::Milica::PlatformCatalogRead
  NOW = Time.utc(2026, 9, 9, 22, 30) # September 10 locally, still September 9 in UTC.

  def setup
    @reader = Reader.allocate
  end

  def test_exact_aliases_are_seven_local_calendar_days_with_explicit_validity
    %w(uskoro ускоро soon).each do |expression|
      range = requested(expression)
      assert_equal Date.new(2026, 9, 10)..Date.new(2026, 9, 16), range
      assert_equal 7, range.to_a.length
      validity = @reader.send(:requested_validity, range, NOW)
      assert_equal "next_seven_days", validity.fetch("range_kind")
      assert_equal({ "from" => "2026-09-10", "through" => "2026-09-16" }, validity.fetch("requested_dates"))
      assert_equal "Europe/Sarajevo", validity.fetch("timezone")
      assert validity.fetch("known_past_occurrences_excluded")
    end
  end

  def test_other_topics_and_longer_expressions_do_not_get_the_alias
    %w(transport participation community neighborhood rewards facilities).each do |topic|
      assert_equal "unsupported_catalog_time", assert_raises(ArgumentError) { requested("soon", topic:) }.message
    end
    ["za uskoro", "uskoro ili sutra", "very soon", "not soon"].each do |expression|
      assert_equal "unsupported_catalog_time", assert_raises(ArgumentError) { requested(expression) }.message
    end
  end

  def test_explicit_date_must_agree_with_the_bounded_range
    %w(2026-09-09 2026-09-17).each do |date|
      assert_equal "unsupported_catalog_time", assert_raises(ArgumentError) { requested("uskoro", date:) }.message
    end
    assert_equal "invalid_catalog_date", assert_raises(ArgumentError) { requested("soon", date: "invalid") }.message
    assert_equal 7, requested("uskoro", date: "2026-09-16").to_a.length
  end

  def test_existing_weekend_and_single_day_keep_their_validity
    weekend = requested("ovog vikenda")
    assert_equal Date.new(2026, 9, 12)..Date.new(2026, 9, 13), weekend
    assert_equal "weekend", @reader.send(:requested_validity, weekend, NOW).fetch("range_kind")
    tomorrow = requested("sutra")
    assert_equal "2026-09-11", @reader.send(:requested_validity, tomorrow, NOW).fetch("requested_date")
    refute @reader.send(:requested_validity, tomorrow, NOW).has_key?("range_kind")
  end

  def test_calendar_window_keeps_local_midnight_across_dst_and_excludes_elapsed_time
    now = Time.utc(2026, 10, 23, 22, 30) # October 24 00:30 locally, before fall clock change.
    range = requested("soon", now:)
    first, last = @reader.send(:requested_clock_bounds, range, now)
    assert_equal now, first
    assert_equal "2026-10-31T00:00:00+01:00", last.iso8601
    assert_equal Date.new(2026, 10, 24)..Date.new(2026, 10, 30), range
  end

  def test_existing_recurring_filter_pairs_each_day_with_its_month_across_boundary
    now = Time.utc(2026, 10, 29, 12)
    range = requested("uskoro", now:)
    model = Data.define(:arel_table).new(Arel::Table.new(:opportunities))
    scope = Struct.new(:klass, :predicate) do
      def where(value)
        self.predicate = value
        self
      end
    end.new(model)
    assert_same scope, @reader.send(:volunteer_time_filter, scope, now, range)
    pairs = nodes(scope.predicate).filter_map do |node|
      next unless node.is_a?(Arel::Nodes::And) && node.children.length == 2

      day, month = node.children
      next unless [day, month].all? { |child| child.is_a?(Arel::Nodes::InfixOperation) && child.operator == "@>" }

      [day.left.name, JSON.parse(day.right.expr), month.left.name, JSON.parse(month.right.expr)]
    end
    expected = range.map { |day| ["day_keys", [day.strftime("%A").downcase], "month_keys", [day.strftime("%B").downcase]] }
    assert_equal expected, pairs
    assert_equal 7, pairs.length
  end

  private

  def requested(expression, date: nil, topic: "volunteer", now: NOW)
    @reader.send(:requested_date, { "time_expression" => expression, "date" => date }, now, topic:)
  end

  def nodes(node)
    children = case node
               when Arel::Nodes::Nary
                 node.children
               when Arel::Nodes::Binary
                 [node.left, node.right]
               when Arel::Nodes::Unary
                 [node.expr]
               else
                 []
               end
    [node] + children.flat_map { |child| nodes(child) }
  end
end

# rubocop:enable Rails/RefuteMethods
