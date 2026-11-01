# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/text")
require_relative "../../app/services/decidim_app/bijeljina/city_service_event_feed"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

# Pure real calendar composition, no Rails/DB/source calls. Models and catalog
# queries are intentionally not booted or mocked into a false live inventory.
class MilicaNeighborhoodActivityCalendarTest < Minitest::Test
  def setup
    @now = Time.utc(2026, 9, 10, 12)
    @context = Data.define(:now).new(@now)
    @port = DecidimApp::Bijeljina::Milica::ReadPort.allocate
    @port.instance_variable_set(:@organization, Data.define(:id).new(71))
    @port.instance_variable_set(:@area_matcher, Object.new)
  end

  def test_activity_weekend_uses_existing_sarajevo_catalog_bounds
    { "ovog vikenda" => ["2026-09-12T00:00:00+02:00", "2026-09-14T00:00:00+02:00"],
      "sljedećeg vikenda" => ["2026-09-19T00:00:00+02:00", "2026-09-21T00:00:00+02:00"],
      "next weekend" => ["2026-09-19T00:00:00+02:00", "2026-09-21T00:00:00+02:00"] }.each do |expression, expected|
      first, last, warning = window(expression)
      assert_nil warning
      assert_equal expected, [first.iso8601, last.iso8601]
    end
  end

  def test_conflicting_or_invalid_explicit_weekend_date_is_not_silently_replaced
    assert_equal [nil, nil, "unsupported_catalog_time"], window("sljedeceg vikenda", date: "2026-09-12")
    assert_equal [nil, nil, "invalid_catalog_date"], window("ovog vikenda", date: "not-a-date")
    assert_equal [nil, nil, "unsupported_catalog_time"], window("prvog vikenda")
  end

  def test_utility_report_weekday_soon_and_default_windows_are_unchanged
    %i(services reports).each do |mode|
      assert_equal [nil, nil, "unsupported_time_expression"], window("sljedeceg vikenda", mode:)
    end
    assert_equal [@now, @now + 7.days, nil], window("uskoro")
    assert_equal [@now, @now + 12.hours, nil], window(nil)
    weekday = window("u petak")
    assert_nil weekday.last
    assert_equal ["2026-09-11T00:00:00+02:00", "2026-09-12T00:00:00+02:00"], weekday.first(2).map(&:iso8601)
    assert_equal @port.send(:time_window, { "time_expression" => "u petak" }, @now), weekday
  end

  private

  def window(expression, mode: :activity, date: nil)
    entities = {}
    entities["time_expression"] = expression if expression
    entities["date"] = date if date
    @port.send(:neighborhood_time_window, mode:, entities:, context: @context)
  end
end
