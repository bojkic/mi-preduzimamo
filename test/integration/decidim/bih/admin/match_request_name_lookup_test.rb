# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 11, Item 4 — match-request user lookup by name instead of raw ID.
      class MatchRequestNameLookupTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                        extended_data: { "group" => true })
          @group.update!(name: "Udruženje aktivnih", nickname: "udruzenje_aktivnih")
          @profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: @group.name,
            slug: @group.nickname,
            kind: "association",
            verification_status: "verified",
            legacy_user_group: @group,
            verified_at: Time.current
          )
        end

        test "admin records a match request by exact name" do
          sign_in @admin
          post "/admin/bih/goodwill/match-request",
               params: { owner_name: "Udruženje aktivnih", points: 100 }

          assert_response :redirect
          req = Decidim::Bih::Goodwill::MatchRequest.last
          assert_not_nil req
          assert_equal @profile, req.owner
          assert_equal 100, req.points
        end

        test "admin records a match request by exact profile slug" do
          sign_in @admin
          post "/admin/bih/goodwill/match-request",
               params: { owner_name: "udruzenje_aktivnih", points: 50 }

          assert_response :redirect
          req = Decidim::Bih::Goodwill::MatchRequest.last
          assert_equal @profile, req.owner
        end

        test "unknown name returns an error flash and records nothing" do
          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::MatchRequest.count" do
            post "/admin/bih/goodwill/match-request",
                 params: { owner_name: "Nepoznat korisnik", points: 50 }
          end
          assert_response :redirect
        end

        test "ambiguous name (two users with same name) returns error" do
          second_group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                              extended_data: { "group" => true })
          second_group.update!(name: "Udruženje aktivnih", nickname: "druga_org")
          Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Udruženje aktivnih",
            slug: "druga-org",
            kind: "association",
            verification_status: "verified",
            legacy_user_group: second_group,
            verified_at: Time.current
          )

          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::MatchRequest.count" do
            post "/admin/bih/goodwill/match-request",
                 params: { owner_name: "Udruženje aktivnih", points: 50 }
          end
          assert_response :redirect
        end

        test "cross-org name does not match" do
          other = create_organization
          other_group = FactoryBot.create(:user, :confirmed, organization: other,
                                                             extended_data: { "group" => true })
          other_group.update!(name: "Tuđe udruženje", nickname: "tudje")
          Decidim::Bih::PartnerProfile.create!(
            organization: other,
            display_name: "Tuđe udruženje",
            slug: "tudje",
            kind: "association",
            verification_status: "verified",
            legacy_user_group: other_group,
            verified_at: Time.current
          )

          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::MatchRequest.count" do
            post "/admin/bih/goodwill/match-request",
                 params: { owner_name: "Tuđe udruženje", points: 50 }
          end
          assert_response :redirect
        end
      end
    end
  end
end
