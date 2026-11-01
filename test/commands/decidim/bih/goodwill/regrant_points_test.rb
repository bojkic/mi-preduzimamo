# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class RegrantPointsTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          # A "group" is a Decidim::User with extended_data["group"]=true (0.31.5).
          @group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                        name: "Udruženje X",
                                                        extended_data: { "group" => true })
          @profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Udruženje X",
            slug: "udruzenje-x",
            kind: "association",
            verification_status: "verified",
            legacy_user_group: @group,
            verified_at: Time.current
          )
          @admin = FactoryBot.create(:user, :confirmed, organization: @organization)
          @member = FactoryBot.create(:user, :confirmed, organization: @organization)

          @profile.memberships.create!(
            organization: @organization,
            user: @admin,
            role: "owner",
            status: "accepted",
            accepted_at: Time.current
          )
          @profile.memberships.create!(
            organization: @organization,
            user: @member,
            role: "member",
            status: "accepted",
            accepted_at: Time.current
          )

          # Fund the group's wallet (received goodwill).
          Decidim::Bih::Goodwill::Ledger.new.award(@group, 100, reason: "gift")
        end

        test "a group admin re-grants the group's wallet to a member" do
          state = nil
          RegrantPoints.call(@admin, @profile.id, @member.id, 40, category: "volunteer_grant") do
            on(:ok) { state = :ok }
            on(:forbidden) { state = :forbidden }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :ok, state
          ledger = Decidim::Bih::Goodwill::Ledger.new
          assert_equal 60, ledger.account_for(@group).balance
          assert_equal 40, ledger.account_for(@member).balance
          # Re-granting is not an "earn": the member's recognition stays at 0.
          assert_equal 0, ledger.account_for(@member).contribution_score
          transaction = Decidim::Bih::Goodwill::Transaction.order(:created_at).last
          assert_equal "organization_grant", transaction.reason
          assert_equal "volunteer_grant", transaction.metadata["grant_category"]
        end

        test "a group admin can send a thank-you award to a registered non-member" do
          helper = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "pomocnik")
          state = nil
          RegrantPoints.call(
            @admin,
            @profile.id,
            nil,
            25,
            category: "logistics",
            recipient_lookup: "@pomocnik"
          ) do
            on(:ok) { state = :ok }
            on(:forbidden) { state = :forbidden }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :ok, state
          ledger = Decidim::Bih::Goodwill::Ledger.new
          assert_equal 75, ledger.account_for(@group).balance
          assert_equal 25, ledger.account_for(helper).balance
          assert_equal 0, ledger.account_for(helper).contribution_score
          transaction = Decidim::Bih::Goodwill::Transaction.order(:created_at).last
          assert_equal "logistics", transaction.metadata["grant_category"]
          assert_equal false, transaction.metadata["member_required"]
        end

        test "broadcasts :insufficient when the group wallet can't cover it" do
          state = nil
          RegrantPoints.call(@admin, @profile.id, @member.id, 999) do
            on(:ok) { state = :ok }
            on(:forbidden) { state = :forbidden }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :insufficient, state
          assert_equal 100, Decidim::Bih::Goodwill::Ledger.new.account_for(@group).balance
        end

        test "a non-admin member is :forbidden" do
          state = nil
          RegrantPoints.call(@member, @profile.id, @admin.id, 10) do
            on(:ok) { state = :ok }
            on(:forbidden) { state = :forbidden }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :forbidden, state
          assert_equal 100, Decidim::Bih::Goodwill::Ledger.new.account_for(@group).balance
        end

        test "a non-member recipient is :invalid" do
          outsider = FactoryBot.create(:user, :confirmed, organization: @organization)
          state = nil
          RegrantPoints.call(@admin, @profile.id, outsider.id, 10) do
            on(:ok) { state = :ok }
            on(:forbidden) { state = :forbidden }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :invalid, state
          assert_equal 100, Decidim::Bih::Goodwill::Ledger.new.account_for(@group).balance
        end

        test "a zero amount is :invalid" do
          state = nil
          RegrantPoints.call(@admin, @profile.id, @member.id, 0) do
            on(:ok) { state = :ok }
            on(:forbidden) { state = :forbidden }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :invalid, state
        end
      end
    end
  end
end
