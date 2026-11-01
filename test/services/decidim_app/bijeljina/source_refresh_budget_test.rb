# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_source_documents"
require "yaml"
require "nokogiri"

module DecidimApp
  module Bijeljina
    class SourceRefreshBudgetTest < ActiveSupport::TestCase
      test "background child deadline never extends parent or relaxes citizen turn cap" do
        monotonic = 100.0
        parent = SourceRefreshBudget.new(timeout: 120, clock: -> { monotonic })
        child = parent.within(8)
        assert_equal 8, child.remaining_seconds
        monotonic += 9
        assert child.expired?
        assert_equal 111, parent.remaining_seconds
        assert_raises(ArgumentError) { Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 120) }
        assert_raises(ArgumentError) { SourceRefreshBudget.new(timeout: Float::INFINITY) }
      end

      test "water and safety feeds refresh hourly while electricity remains daily" do
        assert_equal "hourly", SyntheticSourceDocuments.source("water_service").fetch(:scrape_cadence)
        assert_equal "daily", SyntheticSourceDocuments.source("electricity_outages").fetch(:scrape_cadence)
        assert_equal(%w(water_service road_conditions civil_protection weather_warnings), CityServiceSources::REFERENCE_SOURCES.select { |row| row.fetch(:scrape_cadence) == "hourly" }.map { |row| row.fetch(:key) })
        zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
        assert_equal "08:15", Time.utc(2026, 9, 9, 6, 15).in_time_zone(zone).strftime("%H:%M")
        assert_equal "08:15", Time.utc(2026, 12, 9, 7, 15).in_time_zone(zone).strftime("%H:%M")
      end
      test "invented water publication delay is separate from the next hourly collection opportunity" do
        html = SyntheticSourceDocuments.water_page
        document = Nokogiri::HTML(html)
        published_at = Time.iso8601(document.at_css('meta[property="article:published_time"]')["content"])
        starts_at = Time.iso8601("2026-09-08T06:00:00+02:00")
        assert_includes document.text, "06:00"
        assert_equal "2026-09-08T07:53:03+02:00", published_at.iso8601

        poll_at = next_hourly_poll(published_at)
        assert_equal Time.utc(2026, 9, 8, 6, 15), poll_at
        assert_equal "08:15", poll_at.in_time_zone("Europe/Sarajevo").strftime("%H:%M")
        assert_equal 113.minutes + 3, published_at - starts_at, "provider published after the interruption began"
        assert_equal 21.minutes + 57, poll_at - published_at, "additional delay to the next scheduled poll"
        assert_equal 135.minutes, poll_at - starts_at
        assert_operator poll_at, :>=, published_at, "polling cannot recover information before publication"
      end

      test "summer and winter early and late publications use equivalent local hourly opportunities" do
        # All publication and interruption times here are authored scenarios.
        [[9, 2], [12, 1]].each do |month, utc_offset|
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          starts_at = zone.local(2026, month, 8, 6)
          early_publication = zone.local(2026, month, 8, 5, 10)
          early_poll = next_hourly_poll(early_publication)
          assert_equal Time.utc(2026, month, 8, 5 - utc_offset, 15), early_poll
          assert_equal 50.minutes, starts_at - early_publication, "provider lead time"
          assert_equal 5.minutes, early_poll - early_publication, "collection delay"
          assert_equal 45.minutes, starts_at - early_poll, "scheduled opportunity before service starts"

          late_publication = zone.local(2026, month, 8, 7, 53, 3)
          late_poll = next_hourly_poll(late_publication)
          assert_equal Time.utc(2026, month, 8, 8 - utc_offset, 15), late_poll
          assert_equal 113.minutes + 3, late_publication - starts_at, "provider publication delay"
          assert_equal 21.minutes + 57, late_poll - late_publication, "collection delay remains distinct"
          assert_equal 135.minutes, late_poll - starts_at
        end
      end

      test "late posts immediately before and after the hourly boundary expose the full poll delay" do
        [[9, 2], [12, 1]].each do |month, utc_offset|
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          starts_at = zone.local(2026, month, 8, 6)
          [[14, 59, 8, 1], [15, 1, 9, 3_599]].each do |minute, second, poll_hour, collection_seconds|
            publication = zone.local(2026, month, 8, 8, minute, second)
            poll_at = next_hourly_poll(publication)
            assert_equal Time.utc(2026, month, 8, poll_hour - utc_offset, 15), poll_at
            assert_equal collection_seconds, poll_at - publication
            assert_operator publication - starts_at, :>, 2.hours, "the provider was already late before collection"
            assert_equal publication - starts_at + collection_seconds, poll_at - starts_at
            assert_operator poll_at - publication, :<, 1.hour
          end
        end
      end

      private

      # Synthetic schedule models poll opportunity, not an installed scheduler,
      # completed ingestion or provider delivery. Private manifest tests remain private.
      def next_hourly_poll(published_at)
        job = { "id" => "synthetic-hourly-source", "cadence" => "15 * * * *" }
        assert_equal "15 * * * *", job.fetch("cadence")
        minute = Integer(job.fetch("cadence").split.first, 10)
        beginning_of_hour = Time.at(published_at.to_i - (published_at.to_i % 3_600)).utc
        candidate = beginning_of_hour + minute.minutes
        candidate < published_at ? candidate + 1.hour : candidate
      end
    end
  end
end
