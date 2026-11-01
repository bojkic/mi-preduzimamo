# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class GiftPointsTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
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
          Decidim::Bih::Goodwill::Ledger.new.award(@user, 100, reason: "volunteer_hour")
        end

        test "gifts wallet points to an organization without touching recognition" do
          state = nil
          GiftPoints.call(@user, @profile.id, 40) do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :ok, state
          ledger = Decidim::Bih::Goodwill::Ledger.new
          assert_equal 60, ledger.account_for(@user).balance
          assert_equal 40, ledger.account_for(@group).balance
          assert_equal 100, ledger.account_for(@user).contribution_score # recognition intact
        end

        test "broadcasts :insufficient when the wallet can't cover it" do
          state = nil
          GiftPoints.call(@user, @profile.id, 999) do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end
          assert_equal :insufficient, state
          assert_equal 100, Decidim::Bih::Goodwill::Ledger.new.account_for(@user).balance
        end

        test "broadcasts :invalid and moves no points when the group is blocked" do
          blocked_group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                               name: "Blokirana grupa",
                                                               blocked: true, blocked_at: Time.current,
                                                               extended_data: { "group" => true })
          blocked_profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Blokirana grupa",
            slug: "blokirana-grupa",
            kind: "association",
            verification_status: "verified",
            legacy_user_group: blocked_group,
            verified_at: Time.current
          )
          ledger = Decidim::Bih::Goodwill::Ledger.new
          state = nil
          GiftPoints.call(@user, blocked_profile.id, 10) do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :invalid, state
          assert_equal 100, ledger.account_for(@user).balance
          assert_equal 0, ledger.account_for(blocked_group).balance
        end

        test "broadcasts :invalid and moves no points when the group is deleted" do
          deleted_group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                               name: "Obrisana grupa",
                                                               deleted_at: Time.current,
                                                               extended_data: { "group" => true })
          deleted_profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Obrisana grupa",
            slug: "obrisana-grupa",
            kind: "association",
            verification_status: "verified",
            legacy_user_group: deleted_group,
            verified_at: Time.current
          )
          ledger = Decidim::Bih::Goodwill::Ledger.new
          state = nil
          GiftPoints.call(@user, deleted_profile.id, 10) do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end

          assert_equal :invalid, state
          assert_equal 100, ledger.account_for(@user).balance
          assert_equal 0, ledger.account_for(deleted_group).balance
        end

        test "broadcasts :invalid for a non-group recipient or zero amount" do
          plain_user = FactoryBot.create(:user, :confirmed, organization: @organization)
          state = nil
          GiftPoints.call(@user, plain_user.id, 10) do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end
          assert_equal :invalid, state # recipient is not a group

          state = nil
          GiftPoints.call(@user, @profile.id, 0) do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end
          assert_equal :invalid, state # zero amount
        end
      end
    end
  end
end
