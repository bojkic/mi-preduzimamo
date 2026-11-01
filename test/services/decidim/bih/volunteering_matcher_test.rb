# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class VolunteeringMatcherTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-centar",
          name: { "sr" => "Centar" }
        )
        @komsiluk = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-centar",
          name: { "sr" => "Centar" },
          primary_mz_slug: @mz.slug,
          overlapping_mz_slugs: [@mz.slug]
        )
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "scores by area, time, interests, skills and capabilities" do
        availability = VolunteerAvailability.create!(
          organization: @organization,
          user: @user,
          area_scope: "mz",
          local_area: @mz,
          day_keys: [weekday_key(2.days.from_now)],
          month_keys: [Decidim::Bih::VolunteeringTaxonomy::MONTHS[2.days.from_now.month - 1]],
          time_slot_keys: %w(day afternoon),
          interest_keys: %w(environment),
          skill_keys: %w(field_work),
          capability_keys: %w(outdoor_work)
        )
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Akcija",
          active: true,
          review_status: "approved",
          starts_at: 2.days.from_now.change(hour: 10, min: 0),
          ends_at: 2.days.from_now.change(hour: 12, min: 0),
          komsiluk: @komsiluk,
          category: "environment",
          skill_keys: %w(field_work),
          capability_keys: %w(outdoor_work)
        )

        score = VolunteeringMatcher.new(opportunity, availability).score

        assert_operator score, :>=, 100
      end

      test "matches availability interests directly against opportunity categories" do
        availability = VolunteerAvailability.create!(
          organization: @organization,
          user: FactoryBot.create(:user, :confirmed, organization: @organization),
          interest_keys: %w(community_care)
        )
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Pomoć komšijama",
          active: true,
          review_status: "approved",
          category: "community_care"
        )

        assert_equal 70, VolunteeringMatcher.new(opportunity, availability).score
      end

      test "legacy stored interest keys still match equivalent categories" do
        availability = VolunteerAvailability.create!(
          organization: @organization,
          user: FactoryBot.create(:user, :confirmed, organization: @organization)
        )
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Humanitarna akcija",
          active: true,
          review_status: "approved",
          category: "humanitarian"
        )
        availability.interest_keys = ["people_support"]

        assert_equal 70, VolunteeringMatcher.new(opportunity, availability).score
      end

      test "legacy opportunity categories keep matching old interest aliases" do
        availability = VolunteerAvailability.create!(
          organization: @organization,
          user: FactoryBot.create(:user, :confirmed, organization: @organization)
        )
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Stara logistika",
          active: true,
          review_status: "approved",
          category: "environment"
        )
        availability.interest_keys = ["neighborhood_help"]
        opportunity.category = "admin_logistics"

        assert_equal 70, VolunteeringMatcher.new(opportunity, availability).score
      end

      test "does not match a different komsiluk when area scope is exact" do
        other_komsiluk = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-drugi",
          name: { "sr" => "Drugi" }
        )
        availability = VolunteerAvailability.create!(
          organization: @organization,
          user: @user,
          area_scope: "komsiluk",
          local_area: @komsiluk
        )
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Druga akcija",
          active: true,
          review_status: "approved",
          komsiluk: other_komsiluk
        )

        assert_not VolunteeringMatcher.new(opportunity, availability).match?
      end

      private

      def weekday_key(time)
        Decidim::Bih::VolunteeringTaxonomy::WEEKDAYS[time.wday.zero? ? 6 : time.wday - 1]
      end
    end
  end
end
