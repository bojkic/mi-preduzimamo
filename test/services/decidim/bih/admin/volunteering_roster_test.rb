# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Admin
      class VolunteeringRosterTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @applicant = FactoryBot.create(:user, :confirmed, organization: @organization)
          @started = VolunteerOpportunity.create!(
            organization: @organization, title: "Park programme", active: true,
            review_status: "approved", starts_at: 3.days.ago, ends_at: 3.days.from_now,
            series_key: "park-series", series_position: 1, series_total: 2,
            category: "environment"
          )
          @future = VolunteerOpportunity.create!(
            organization: @organization, title: "Park programme", active: true,
            review_status: "approved", starts_at: 4.days.from_now, ends_at: 5.days.from_now,
            series_key: "park-series", series_position: 2, series_total: 2,
            category: "environment"
          )
          @going = VolunteerSignup.create!(
            organization: @organization, opportunity: @started, user: @citizen,
            status: "going", review_status: "approved", review_source: "admin",
            reviewer: @admin, reviewed_at: Time.current
          )
          @pending_application = VolunteerSignup.create!(
            organization: @organization, opportunity: @future, user: @applicant,
            status: "pending", review_status: "pending", review_source: "application",
            first_session_at: @future.starts_at
          )
          zone = Time.find_zone!("Europe/Sarajevo")
          start = 1.day.ago.in_time_zone(zone).change(hour: 10, min: 0, sec: 0)
          @pending_log = VolunteerLog.create!(
            organization: @organization, opportunity: @started, user: @citizen,
            status: "pending", work_date: start.to_date, worked_from_at: start,
            worked_until_at: start + 2.hours, hours: 2
          )
        end

        test "one proposal row represents all terms while task badges keep their own units" do
          roster = VolunteeringRoster.new(@organization)

          assert_equal "opportunities", roster.tab
          assert_equal 1, roster.total_count
          assert_equal 1, roster.records.length
          assert_equal 2, roster.records.first[:term_count]
          assert_equal({ opportunities: 0, applications: 1, hours: 1 }, roster.counts)
        end

        test "application filters and displayed totals use the same scoped relation" do
          review = VolunteeringRoster.new(@organization, filters: { tab: "applications", task: "review" })
          register = VolunteeringRoster.new(@organization, filters: { tab: "applications", task: "attendance" })
          approved = VolunteeringRoster.new(@organization, filters: { tab: "applications", status: "approved" })

          assert_equal [@pending_application.id], review.records.map(&:id)
          assert_equal review.records.length, review.total_count
          assert_equal [@going.id], register.records.map(&:id)
          assert_equal [@going.id], approved.records.map(&:id)
        end

        test "pending work remains reviewable after the opportunity goes inactive" do
          @started.update!(active: false)
          queue = VolunteeringRoster.new(@organization, filters: { tab: "hours", status: "pending" })

          assert_equal [@pending_log.id], queue.records.map(&:id)
          assert_equal 1, queue.total_count
          assert_equal 1, queue.counts.fetch(:hours)
        end

        test "opportunity status and category filters stay active together" do
          VolunteerOpportunity.create!(
            organization: @organization, title: "Youth pending", active: false,
            review_status: "pending", category: "education_youth"
          )
          foreign = create_organization
          VolunteerOpportunity.create!(organization: foreign, title: "Foreign pending", active: false,
                                       review_status: "pending", category: "education_youth")

          roster = VolunteeringRoster.new(@organization, filters: {
                                             tab: "opportunities", status: "pending", category: "education_youth"
                                           })
          assert_equal ["Youth pending"], roster.records.map { |row| row[:opportunity].title }
          assert_equal 1, roster.total_count
        end

        test "pagination reaches all opportunities beyond the former forty-row limit" do
          45.times do |index|
            VolunteerOpportunity.create!(organization: @organization, title: "Shift #{index}",
                                         active: true, review_status: "approved", starts_at: (index + 6).days.from_now)
          end
          first = VolunteeringRoster.new(@organization, filters: { tab: "opportunities", page: 1 })
          second = VolunteeringRoster.new(@organization, filters: { tab: "opportunities", page: 2 })
          third = VolunteeringRoster.new(@organization, filters: { tab: "opportunities", page: 3 })

          assert_equal 46, first.total_count
          assert_equal 3, first.total_pages
          assert_equal [20, 20, 6], [first.records.length, second.records.length, third.records.length]
          ids = [first, second, third].flat_map { |roster| roster.records.map { |row| row[:opportunity].id } }
          assert_equal 46, ids.uniq.length
        end
      end
    end
  end
end
