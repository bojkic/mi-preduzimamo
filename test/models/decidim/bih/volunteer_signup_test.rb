# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Review and seat state are distinct: applying consumes no place, while an
    # explicitly accepted place counts against capacity.
    class VolunteerSignupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @opportunity = VolunteerOpportunity.create!(
          organization: @organization, title: "Čišćenje parka",
          active: true, review_status: "approved", capacity: 2
        )
      end

      def automatic_attributes(status)
        { status:, review_status: "automatic", review_source: "automatic",
          reviewed_at: Time.current, queued_at: (Time.current if status == "waitlisted") }
      end

      test "is valid with going status" do
        signup = VolunteerSignup.new(
          organization: @organization, opportunity: @opportunity, user: @user,
          **automatic_attributes("going")
        )

        assert signup.valid?
      end

      test "going without an explicit review outcome is invalid" do
        signup = VolunteerSignup.new(
          organization: @organization, opportunity: @opportunity, user: @user, status: "going"
        )

        assert_not signup.valid?
        assert_includes signup.errors.attribute_names, :review_status
      end

      test "is valid with waitlisted status" do
        signup = VolunteerSignup.new(
          organization: @organization, opportunity: @opportunity, user: @user,
          **automatic_attributes("waitlisted")
        )

        assert signup.valid?
        assert signup.waitlisted?
        assert signup.active_rsvp?
      end

      test "rejects an unknown status" do
        signup = VolunteerSignup.new(
          organization: @organization, opportunity: @opportunity, user: @user, status: "maybe"
        )

        assert_not signup.valid?
        assert_includes signup.errors.attribute_names, :status
      end

      test "defaults to pending review and does not reserve a place" do
        signup = VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: @user
        )

        assert_equal "pending", signup.status
        assert_equal "pending", signup.review_status
        assert_not signup.going?
        assert_equal 0, @opportunity.reload.signups_count
      end

      test "the signup scopes separate confirmed, waitlisted and active RSVPs" do
        going = VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: @user,
          **automatic_attributes("going")
        )
        waitlisted_user = FactoryBot.create(:user, :confirmed, organization: @organization)
        waitlisted = VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: waitlisted_user,
          **automatic_attributes("waitlisted")
        )
        cancelled_user = FactoryBot.create(:user, :confirmed, organization: @organization)
        VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: cancelled_user,
          status: "cancelled", participation_ended_at: Time.current
        )

        assert_equal [going.id], VolunteerSignup.going.pluck(:id)
        assert_equal [waitlisted.id], VolunteerSignup.waitlisted.pluck(:id)
        assert_equal [going.id, waitlisted.id].sort, VolunteerSignup.active_rsvp.pluck(:id).sort
      end

      test "a user can sign up for an opportunity only once (unique index)" do
        VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: @user
        )

        assert_raises(ActiveRecord::RecordNotUnique) do
          VolunteerSignup.create!(
            organization: @organization, opportunity: @opportunity, user: @user
          )
        end
      end

      test "signups_count and full? count only GOING signups against capacity" do
        one = VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: @user,
          **automatic_attributes("going")
        )
        second = FactoryBot.create(:user, :confirmed, organization: @organization)
        two = VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: second,
          **automatic_attributes("going")
        )

        assert_equal 2, @opportunity.signups_count
        assert @opportunity.full?

        waitlisted_user = FactoryBot.create(:user, :confirmed, organization: @organization)
        VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: waitlisted_user,
          **automatic_attributes("waitlisted")
        )

        assert_equal 2, @opportunity.reload.signups_count
        assert @opportunity.full?

        # Cancelling one frees a seat: the count drops and it is no longer full.
        two.update!(status: "cancelled", participation_ended_at: Time.current)
        assert_equal 1, @opportunity.reload.signups_count
        assert_not @opportunity.full?

        # A cancelled-only seat does not count even when the user re-cancels.
        assert one.going?
      end

      test "an opportunity without a capacity is never full" do
        uncapped = VolunteerOpportunity.create!(
          organization: @organization, title: "Bez ograničenja", active: true, review_status: "approved"
        )
        VolunteerSignup.create!(
          organization: @organization, opportunity: uncapped, user: @user,
          **automatic_attributes("going")
        )

        assert_not uncapped.full?
      end
    end
  end
end
