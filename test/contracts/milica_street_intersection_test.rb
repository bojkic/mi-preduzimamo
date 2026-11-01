# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/core_ext/object/blank"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/geo/area_locator")
require_relative "../../app/services/decidim_app/bijeljina/city_service_street_intersection"

class MilicaStreetIntersectionTest < Minitest::Test
  def setup
    @intersection = DecidimApp::Bijeljina::CityServiceStreetIntersection.new
    @left = polygon(0, 0, 1, 1)
    @right = polygon(1, 0, 2, 1)
  end

  def test_named_street_across_two_areas_marks_both_even_when_vertices_are_outside
    street = line([-1, 0.5], [3, 0.5])
    assert @intersection.intersects?(street, @left)
    assert @intersection.intersects?(street, @right)
  end

  def test_shared_boundary_marks_both_sides_but_endpoint_only_does_not
    street = line([1, 0.2], [1, 0.8])
    assert @intersection.intersects?(street, @left)
    assert @intersection.intersects?(street, @right)
    assert_equal false, @intersection.intersects?(line([1, 1], [2, 2]), @left)
  end

  def test_all_components_are_used_and_a_narrowed_segment_stays_narrow
    street = { "type" => "MultiLineString", "coordinates" => [[[0.2, 0.5], [0.8, 0.5]], [[1.2, 0.5], [1.8, 0.5]]] }
    assert @intersection.intersects?(street, @left)
    assert @intersection.intersects?(street, @right)
    assert_equal false, @intersection.intersects?(line([0.2, 0.5], [0.8, 0.5]), @right)
  end

  def test_polygon_holes_do_not_count_as_covered_street
    area = polygon(0, 0, 3, 3)
    area["coordinates"] << polygon(1, 1, 2, 2).fetch("coordinates").first
    assert_equal false, @intersection.intersects?(line([1.2, 1.5], [1.8, 1.5]), area)
    assert @intersection.intersects?(line([0.5, 1.5], [2.5, 1.5]), area)
  end

  private

  def line(*points) = { "type" => "LineString", "coordinates" => points }

  def polygon(left, bottom, right, top)
    { "type" => "Polygon", "coordinates" => [[[left, bottom], [right, bottom], [right, top], [left, top], [left, bottom]]] }
  end
end
