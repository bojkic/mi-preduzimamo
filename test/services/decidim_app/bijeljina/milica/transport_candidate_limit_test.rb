# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class TransportCandidateLimitTest < ActiveSupport::TestCase
        Snapshot = Struct.new(:stops, :nearby, keyword_init: true) do
          def point_ids_for(id)
            stops.key?(id) ? [id] : []
          end
        end

        test "named origin expands within 200 metres and includes boarding margin" do
          stops = [
            { id: "anchor", label: "Central", latitude: 44.75, longitude: 19.21 },
            { id: "near", label: "Near", latitude: 44.7509, longitude: 19.21 },
            { id: "far", label: "Far", latitude: 44.7530, longitude: 19.21 }
          ]
          snapshot = Snapshot.new(stops: stops.to_h { |row| [row.fetch(:id), row] },
                                  nearby: Decidim::Bih::Transport::NearbyStops.new(stops))
          timetable = PublicTransportTimetable.allocate
          starts = timetable.send(:planner_candidates, snapshot, ["anchor"], nil, access: true, pinned: false)
          assert_equal %w(anchor near), starts.map { |row| row.fetch(:stop_id) }.sort
          assert starts.all? { |row| row.fetch(:boarding_margin_seconds) == Decidim::Bih::Transport::WalkingEstimate::BOARDING_MARGIN_SECONDS }
          assert_operator starts.find { |row| row.fetch(:stop_id) == "near" }.fetch(:walk_seconds), :>, 0

          finishes = timetable.send(:planner_candidates, snapshot, ["anchor"], nil, access: false, pinned: false)
          assert_equal %w(anchor near), finishes.map { |row| row.fetch(:stop_id) }.sort
          assert finishes.all? { |row| row.fetch(:boarding_margin_seconds).zero? }

          pinned = timetable.send(:planner_candidates, snapshot, ["anchor"], nil, access: true, pinned: true)
          assert_equal ["anchor"], pinned.map { |row| row.fetch(:stop_id) }
          assert_equal Decidim::Bih::Transport::WalkingEstimate::BOARDING_MARGIN_SECONDS,
                       pinned.sole.fetch(:boarding_margin_seconds)
        end
      end
    end
  end
end
