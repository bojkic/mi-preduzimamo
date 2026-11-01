# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Positive-length line/polygon intersection, including a line shared by
    # two polygon boundaries. End-point-only contact is not street coverage.
    # Uses the existing point-in-geometry implementation for polygon holes.
    class CityServiceStreetIntersection
      EPSILON = 1e-12

      def initialize
        @locator = Decidim::Bih::Geo::AreaLocator.new
      end

      def intersects?(street, boundary)
        lines = street["type"] == "LineString" ? [street["coordinates"]] : Array(street["coordinates"])
        return false unless %w(LineString MultiLineString).include?(street["type"])

        rings = polygon_rings(boundary)
        return false if rings.empty? || !overlapping_bounds?(lines.flatten(1), rings.flatten(1))

        edges = rings.flat_map { |ring| ring.each_cons(2).to_a }
        lines.any? { |line| line.each_cons(2).any? { |left, right| segment_inside?(left, right, edges, boundary) } }
      end

      private

      def polygon_rings(boundary)
        case boundary["type"]
        when "Polygon" then Array(boundary["coordinates"])
        when "MultiPolygon" then Array(boundary["coordinates"]).flatten(1)
        else []
        end
      end

      def overlapping_bounds?(left, right)
        return false if left.empty? || right.empty?

        a = bounds(left)
        b = bounds(right)
        a[0] <= b[2] && a[2] >= b[0] && a[1] <= b[3] && a[3] >= b[1]
      end

      def bounds(points)
        xs, ys = points.transpose
        [xs.min, ys.min, xs.max, ys.max]
      end

      def segment_inside?(left, right, edges, boundary)
        direction = subtract(right, left)
        return false if dot(direction, direction) <= EPSILON**2

        fractions = ([0.0, 1.0] + edges.flat_map { |a, b| intersection_fractions(left, direction, a, b) }).uniq.sort
        fractions.each_cons(2).any? do |start, finish|
          next false if finish - start <= EPSILON

          fraction = (start + finish) / 2.0
          midpoint = [left[0] + (direction[0] * fraction), left[1] + (direction[1] * fraction)]
          @locator.point_in_geom?(*midpoint, boundary) || edges.any? { |a, b| point_on_segment?(midpoint, a, b) }
        end
      end

      def intersection_fractions(origin, direction, left, right)
        edge = subtract(right, left)
        offset = subtract(left, origin)
        denominator = cross(direction, edge)
        return collinear_fractions(offset, direction, edge) if denominator.abs <= EPSILON

        fraction = cross(offset, edge) / denominator
        other_fraction = cross(offset, direction) / denominator
        fraction.between?(0, 1) && other_fraction.between?(0, 1) ? [fraction] : []
      end

      def collinear_fractions(offset, direction, edge)
        return [] unless cross(offset, direction).abs <= EPSILON

        length = dot(direction, direction)
        [dot(offset, direction) / length, dot([offset[0] + edge[0], offset[1] + edge[1]], direction) / length]
          .select { |fraction| fraction.between?(0, 1) }
      end

      def point_on_segment?(point, left, right)
        edge = subtract(right, left)
        return false if dot(edge, edge) <= EPSILON**2

        offset = subtract(point, left)
        cross(offset, edge).abs <= EPSILON && dot(offset, edge).between?(0, dot(edge, edge))
      end

      def subtract(left, right) = [left[0] - right[0], left[1] - right[1]]

      def cross(left, right) = (left[0] * right[1]) - (left[1] * right[0])

      def dot(left, right) = (left[0] * right[0]) + (left[1] * right[1])
    end
  end
end
