# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class RegisterVolunteerAvailabilityTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        @komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-centar",
          name: { "sr" => "Centar" }
        )
      end

      test "creates structured availability and awards the one-time volunteer availability points" do
        status, record = RegisterVolunteerAvailability.call(
          user: @volunteer,
          organization: @organization,
          availability: "Radnim danom poslije 17h",
          interests: "Ekologija",
          area_scope: "komsiluk",
          local_area: @komsiluk,
          day_keys: %w(monday tuesday),
          month_keys: %w(july august),
          time_slot_keys: %w(day afternoon),
          interest_keys: %w(environment),
          skill_keys: %w(field_work),
          capability_keys: %w(outdoor_work)
        )

        assert_equal :created, status
        assert record.persisted?
        assert_equal "Radnim danom poslije 17h", record.availability
        assert_equal "komsiluk", record.area_scope
        assert_equal @komsiluk.id, record.local_area_id
        assert_equal %w(monday tuesday), record.day_keys
        assert_equal %w(july august), record.month_keys
        assert_equal %w(day afternoon), record.time_slot_keys
        assert_equal ["environment"], record.interest_keys
        assert_equal ["field_work"], record.skill_keys
        assert_equal ["outdoor_work"], record.capability_keys
        assert_empty record.availability_windows
        assert_equal 10, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "updates existing availability without awarding again" do
        RegisterVolunteerAvailability.call(
          user: @volunteer,
          organization: @organization,
          availability: "Subotom",
          interests: "Sadnja"
        )

        status, record = RegisterVolunteerAvailability.call(
          user: @volunteer,
          organization: @organization,
          availability: "Nedjeljom",
          interests: "Čišćenje"
        )

        assert_equal :updated, status
        assert_equal "Nedjeljom", record.availability
        assert_equal "Čišćenje", record.interests
        assert_equal 10, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end
    end
  end
end
