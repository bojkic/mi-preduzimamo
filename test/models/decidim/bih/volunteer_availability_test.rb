# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Free-text availability/interests carry PII under a 3-year retention window,
    # so they must be length-bounded.
    class VolunteerAvailabilityTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @mz = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-centar",
          name: { "sr" => "Centar" }
        )
        @komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-centar",
          name: { "sr" => "Centar" },
          primary_mz_slug: @mz.slug,
          overlapping_mz_slugs: [@mz.slug]
        )
      end

      test "accepts reasonable free text" do
        availability = VolunteerAvailability.new(
          organization: @organization, user: @user,
          availability: "Subotom", interests: "Parkovi",
          area_scope: "komsiluk",
          local_area: @komsiluk,
          day_keys: %w(saturday sunday),
          month_keys: %w(june july),
          time_slot_keys: %w(day afternoon),
          interest_keys: %w(environment neighborhood_infrastructure),
          skill_keys: %w(field_work organization),
          capability_keys: %w(outdoor_work)
        )

        assert availability.valid?
        assert_includes availability.day_labels, "Subota"
        assert_includes availability.month_labels, "Jun"
        assert_includes availability.time_slot_labels, "Popodne/Veče"
        assert_includes availability.skill_labels, "Rad na terenu"
      end

      test "rejects an over-long availability or interests value" do
        availability = VolunteerAvailability.new(
          organization: @organization, user: @user,
          availability: "a" * 2_001, interests: "b" * 2_001
        )

        assert_not availability.valid?
        assert_includes availability.errors.attribute_names, :availability
        assert_includes availability.errors.attribute_names, :interests
      end

      test "requires selected area to match the chosen scope" do
        availability = VolunteerAvailability.new(
          organization: @organization,
          user: @user,
          area_scope: "mz",
          local_area: @komsiluk
        )

        assert_not availability.valid?
        assert_includes availability.errors.attribute_names, :local_area
      end

      test "defaults broad schedule fields when no narrow choice is provided" do
        availability = VolunteerAvailability.new(
          organization: @organization,
          user: @user
        )

        assert availability.valid?
        assert_equal Decidim::Bih::VolunteeringTaxonomy::WEEKDAYS, availability.day_keys
        assert_equal Decidim::Bih::VolunteeringTaxonomy::MONTHS, availability.month_keys
        assert_equal Decidim::Bih::VolunteeringTaxonomy::TIME_SLOTS, availability.time_slot_keys
      end

      test "interest choices reuse the public opportunity category keys" do
        assert_equal 8, Decidim::Bih::VolunteeringTaxonomy::CATEGORIES.size
        assert_equal Decidim::Bih::VolunteeringTaxonomy::CATEGORIES,
                     Decidim::Bih::VolunteeringTaxonomy::INTERESTS
      end
    end
  end
end
