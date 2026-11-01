# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for volunteer RSVP / sign-up: a signed-in citizen registers
    # intent to attend; capacity is enforced with a waitlist; the listing shows
    # the going count and a sign-up/cancel control. RSVP awards no points.
    class VolunteerSignupPageTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        @opportunity = VolunteerOpportunity.create!(
          organization: @organization, title: "Čišćenje parka",
          active: true, review_status: "approved", capacity: 2
        )
      end

      test "the listing shows the going count and a sign-up control for signed-in citizens" do
        sign_in @volunteer
        get "/biceriseno/volontiranje"

        assert_response :success
        # "0/2 mjesta" — going count against capacity.
        assert_includes response.body, "0/2"
        assert_includes response.body, "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
      end

      test "a signed-in citizen signs up and the count goes up; no points awarded" do
        sign_in @volunteer
        assert_difference -> { VolunteerSignup.going.count }, 1 do
          post "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        end

        assert_response :redirect
        signup = VolunteerSignup.last
        assert_equal @volunteer.id, signup.decidim_user_id
        assert signup.going?
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "signed-in users from another organization cannot sign up on this host" do
        outsider = signed_in_other_org_user

        assert_no_difference -> { VolunteerSignup.count } do
          post "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        end

        assert_response :redirect
        assert_nil VolunteerSignup.find_by(organization: @organization, user: outsider)
      end

      test "signing in is required to sign up" do
        assert_no_difference -> { VolunteerSignup.count } do
          post "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        end

        assert_response :redirect
      end

      test "re-signing up is idempotent and does not create a duplicate" do
        sign_in @volunteer
        post "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"

        assert_no_difference -> { VolunteerSignup.where(decidim_user_id: @volunteer.id).count } do
          post "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        end

        assert_response :redirect
        assert_equal 1, VolunteerSignup.going.where(opportunity: @opportunity).count
      end

      test "signing up for a full opportunity joins the waitlist without awarding points" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        other = FactoryBot.create(:user, :confirmed, organization: @organization)
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: other, status: "going",
          review_status: "automatic", review_source: "automatic"
        )

        sign_in @volunteer
        assert_no_difference -> { VolunteerSignup.going.where(opportunity: full).count } do
          assert_difference -> { VolunteerSignup.waitlisted.where(opportunity: full).count }, 1 do
            post "/biceriseno/volontiranje/prijavi-se/#{full.id}"
          end
        end

        assert_response :redirect
        signup = VolunteerSignup.find_by(opportunity: full, user: @volunteer)
        assert signup.waitlisted?
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "rejoining the same full opportunity is idempotent for waitlisted citizens" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        other = FactoryBot.create(:user, :confirmed, organization: @organization)
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: other, status: "going",
          review_status: "automatic", review_source: "automatic"
        )

        sign_in @volunteer
        post "/biceriseno/volontiranje/prijavi-se/#{full.id}"

        assert_no_difference -> { VolunteerSignup.where(opportunity: full, user: @volunteer).count } do
          post "/biceriseno/volontiranje/prijavi-se/#{full.id}"
        end

        assert_response :redirect
        assert VolunteerSignup.find_by(opportunity: full, user: @volunteer).waitlisted?
      end

      test "an already-going citizen re-signing up for a full opportunity is allowed (idempotent)" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: @volunteer, status: "going",
          review_status: "automatic", review_source: "automatic"
        )

        sign_in @volunteer
        assert_no_difference -> { VolunteerSignup.where(opportunity: full).count } do
          post "/biceriseno/volontiranje/prijavi-se/#{full.id}"
        end

        assert_response :redirect
        assert VolunteerSignup.find_by(opportunity: full, user: @volunteer).going?
      end

      test "cancelling a confirmed signup promotes the oldest waitlisted citizen" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        first = FactoryBot.create(:user, :confirmed, organization: @organization)
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: first, status: "going",
          review_status: "automatic", review_source: "automatic"
        )

        # Second citizen waits while full.
        sign_in @volunteer
        post "/biceriseno/volontiranje/prijavi-se/#{full.id}"
        assert VolunteerSignup.find_by(opportunity: full, user: @volunteer).waitlisted?

        # First citizen cancels, so the waitlisted citizen is promoted.
        sign_out @volunteer
        sign_in first
        notifications = []
        VolunteerNotifications.stub(:publish, ->(**attributes) { notifications << attributes }) do
          delete "/biceriseno/volontiranje/prijavi-se/#{full.id}"
        end
        assert_equal "cancelled", VolunteerSignup.find_by(opportunity: full, user: first).status
        assert VolunteerSignup.find_by(opportunity: full, user: @volunteer).reload.going?
        assert full.reload.full?
        assert_equal @volunteer, notifications.sole.fetch(:user)
        assert_equal "promoted", notifications.sole.fetch(:status)
      end

      test "cancelling a waitlisted signup removes it from the active RSVP list" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        other = FactoryBot.create(:user, :confirmed, organization: @organization)
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: other, status: "going",
          review_status: "automatic", review_source: "automatic"
        )

        sign_in @volunteer
        post "/biceriseno/volontiranje/prijavi-se/#{full.id}"

        assert_difference -> { VolunteerSignup.cancelled.where(opportunity: full, user: @volunteer).count }, 1 do
          delete "/biceriseno/volontiranje/prijavi-se/#{full.id}"
        end

        assert_equal 1, VolunteerSignup.going.where(opportunity: full).count
        assert_equal 0, VolunteerSignup.waitlisted.where(opportunity: full).count
      end

      test "cancelling a signup with confirmed attendance is refused" do
        admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        signup = VolunteerSignup.create!(
          organization: @organization,
          opportunity: @opportunity,
          user: @volunteer,
          status: "going",
          review_status: "automatic",
          review_source: "automatic",
          attendance_confirmed_at: Time.current,
          attendance_source: "operator",
          attendance_confirmer: admin
        )

        sign_in @volunteer
        assert_no_difference -> { VolunteerSignup.cancelled.count } do
          delete "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        end

        assert_response :redirect
        assert signup.reload.going?
        assert signup.attendance_confirmed?
      end

      test "re-signing up after cancelling reactivates the existing record" do
        sign_in @volunteer
        post "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        delete "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        assert_equal "cancelled", VolunteerSignup.find_by(opportunity: @opportunity, user: @volunteer).status

        assert_no_difference -> { VolunteerSignup.where(opportunity: @opportunity, user: @volunteer).count } do
          post "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        end

        assert VolunteerSignup.find_by(opportunity: @opportunity, user: @volunteer).going?
      end

      test "signed-in users from another organization cannot cancel current-host signups" do
        signup = VolunteerSignup.create!(
          organization: @organization, opportunity: @opportunity, user: @volunteer, status: "going",
          review_status: "automatic", review_source: "automatic"
        )
        signed_in_other_org_user

        assert_no_difference -> { VolunteerSignup.cancelled.count } do
          delete "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        end

        assert_response :redirect
        assert signup.reload.going?
      end

      test "cannot sign up for another organization's opportunity" do
        other_org = create_organization
        other_opportunity = VolunteerOpportunity.create!(
          organization: other_org, title: "Tuđa akcija",
          active: true, review_status: "approved", capacity: 5
        )

        sign_in @volunteer
        assert_no_difference -> { VolunteerSignup.count } do
          post "/biceriseno/volontiranje/prijavi-se/#{other_opportunity.id}"
        end

        assert_response :redirect
      end

      private

      def signed_in_other_org_user
        other_organization = create_organization
        outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)
        sign_in outsider
        outsider
      end
    end
  end
end
