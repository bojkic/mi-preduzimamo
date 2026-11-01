# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # R8 — enriched volunteer opportunities. The model accepts the new
    # scheduling/logistics fields (all nullable) and guards capacity.
    class VolunteerOpportunityTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-centar",
          name: { "sr" => "Centar" }
        )
      end

      test "accepts structured scheduling, komsiluk, category, skills and capacity" do
        when_at = 3.days.from_now.change(usec: 0)
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Čišćenje obale",
          starts_at: when_at,
          ends_at: when_at + 2.hours,
          komsiluk: @komsiluk,
          meeting_point: "Kod česme",
          category: "environment",
          day_keys: %w(saturday sunday),
          month_keys: %w(june july),
          time_slot_keys: %w(day afternoon),
          skill_keys: %w(field_work organization),
          capability_keys: %w(outdoor_work),
          capacity: 25,
          partner_name: "Partneri Bijeljina",
          series_key: "series-abc",
          series_position: 1,
          series_total: 3
        )

        opportunity.reload
        assert_equal when_at.to_i, opportunity.starts_at.to_i
        assert_equal "Centar · Kod česme", opportunity.location_label
        assert_equal "environment", opportunity.category
        assert_equal "Ekologija i čišćenje", opportunity.category_label
        assert_includes opportunity.skill_labels, "Rad na terenu"
        assert_includes opportunity.day_labels, "Subota"
        assert_includes opportunity.month_labels, "Jun"
        assert_includes opportunity.time_slot_labels, "Popodne/Veče"
        assert_equal 25, opportunity.capacity
        assert_equal "Partneri Bijeljina", opportunity.partner_name
        assert opportunity.series?
      end

      test "the new detail fields remain optional" do
        opportunity = VolunteerOpportunity.new(organization: @organization, title: "Samo naziv")

        assert opportunity.valid?
        assert_nil opportunity.starts_at
        assert_nil opportunity.location
        assert_nil opportunity.komsiluk
        assert_nil opportunity.category
        assert_nil opportunity.capacity
        assert_nil opportunity.partner_name
        assert_not opportunity.series?
        assert_not opportunity.partner_confirmed?
      end

      test "rejects a non-positive capacity" do
        opportunity = VolunteerOpportunity.new(
          organization: @organization, title: "X", capacity: 0
        )

        assert_not opportunity.valid?
        assert_includes opportunity.errors.attribute_names, :capacity
      end

      test "rejects an over-long description, location or category" do
        opportunity = VolunteerOpportunity.new(
          organization: @organization,
          title: "X",
          description: "a" * 5_001,
          location: "b" * 501,
          meeting_point: "b" * 501,
          requirements: "e" * 2_001,
          category: "c" * 201,
          partner_name: "d" * 201
        )

        assert_not opportunity.valid?
        assert_includes opportunity.errors.attribute_names, :description
        assert_includes opportunity.errors.attribute_names, :location
        assert_includes opportunity.errors.attribute_names, :meeting_point
        assert_includes opportunity.errors.attribute_names, :requirements
        assert_includes opportunity.errors.attribute_names, :category
        assert_includes opportunity.errors.attribute_names, :partner_name
      end

      test "rejects a komsiluk from another organization or a reversed time frame" do
        other = create_organization
        foreign_komsiluk = Decidim::Bih::LocalArea.create!(
          organization: other,
          kind: "komsiluk",
          slug: "foreign",
          name: { "sr" => "Tuđi" }
        )
        opportunity = VolunteerOpportunity.new(
          organization: @organization,
          title: "X",
          komsiluk: foreign_komsiluk,
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now - 1.hour
        )

        assert_not opportunity.valid?
        assert_includes opportunity.errors.attribute_names, :komsiluk
        assert_includes opportunity.errors.attribute_names, :ends_at
      end

      test "citizen pending proposals require canonical category and a location when area data exists" do
        author = FactoryBot.create(:user, :confirmed, organization: @organization)
        profile = verified_partner_profile
        opportunity = VolunteerOpportunity.new(
          organization: @organization,
          author:,
          title: "Prijedlog",
          active: false,
          review_status: "pending",
          category: "slobodan tekst",
          partner_profile: profile,
          partner_name: profile.display_name
        )

        assert_not opportunity.valid?
        assert_includes opportunity.errors.attribute_names, :category
        assert_includes opportunity.errors.attribute_names, :location
      end

      test "citizen pending proposals require a verified organization profile" do
        author = FactoryBot.create(:user, :confirmed, organization: @organization)
        opportunity = VolunteerOpportunity.new(
          organization: @organization,
          author:,
          title: "Prijedlog bez organizacije",
          active: false,
          review_status: "pending",
          category: "environment",
          location: "Centar"
        )

        assert_not opportunity.valid?
        assert_includes opportunity.errors.attribute_names, :partner_profile
      end

      test "citizen pending proposals reject ineligible organization kinds" do
        author = FactoryBot.create(:user, :confirmed, organization: @organization)
        profile = verified_partner_profile(kind: "other")
        opportunity = VolunteerOpportunity.new(
          organization: @organization,
          author:,
          title: "Prijedlog drugog tipa",
          active: false,
          review_status: "pending",
          category: "environment",
          location: "Centar",
          partner_profile: profile,
          partner_name: profile.display_name
        )

        assert_not opportunity.valid?
        assert_includes opportunity.errors.attribute_names, :partner_profile
      end

      test "citizen pending proposals can use a text location without komsiluk" do
        author = FactoryBot.create(:user, :confirmed, organization: @organization)
        profile = verified_partner_profile
        opportunity = VolunteerOpportunity.new(
          organization: @organization,
          author:,
          title: "Prijedlog za MZ",
          active: false,
          review_status: "pending",
          category: "environment",
          location: "Centar",
          partner_profile: profile,
          partner_name: profile.display_name
        )

        assert opportunity.valid?
        assert_nil opportunity.komsiluk
        assert_equal "Centar", opportunity.location_label
      end

      test "rejects a series position beyond its total" do
        opportunity = VolunteerOpportunity.new(
          organization: @organization,
          title: "X",
          series_key: "series-abc",
          series_position: 4,
          series_total: 3
        )

        assert_not opportunity.valid?
        assert_includes opportunity.errors.attribute_names, :series_position
      end

      test "upcoming scope returns future opportunities ordered by start" do
        past = VolunteerOpportunity.create!(organization: @organization, title: "Prošla", starts_at: 2.days.ago)
        soon = VolunteerOpportunity.create!(organization: @organization, title: "Uskoro", starts_at: 1.day.from_now)
        later = VolunteerOpportunity.create!(organization: @organization, title: "Kasnije", starts_at: 5.days.from_now)

        upcoming = VolunteerOpportunity.where(organization: @organization).upcoming.to_a

        assert_equal [soon.id, later.id], upcoming.map(&:id)
        assert_not_includes upcoming.map(&:id), past.id
      end

      test "active scope only returns approved opportunities" do
        approved = VolunteerOpportunity.create!(
          organization: @organization, title: "Odobrena", active: true, review_status: "approved"
        )
        VolunteerOpportunity.create!(
          organization: @organization, title: "Aktivna ali čeka", active: true, review_status: "pending"
        )
        pending = VolunteerOpportunity.create!(
          organization: @organization, title: "Čeka", active: false, review_status: "pending"
        )
        VolunteerOpportunity.create!(
          organization: @organization, title: "Odbijena", active: false, review_status: "rejected"
        )

        assert_equal [approved.id], VolunteerOpportunity.where(organization: @organization).active.pluck(:id)
        assert_equal [pending.id], VolunteerOpportunity.where(organization: @organization).pending_review.pluck(:id)
      end

      private

      def verified_partner_profile(kind: "association")
        Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name: "Udruženje model",
          slug: "udruzenje-model-#{kind}",
          kind:,
          verification_status: "verified",
          verified_at: Time.current
        )
      end
    end
  end
end
