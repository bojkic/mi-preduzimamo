# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # The public profile shows a "verified" flair for a confirmed user who holds
    # a granted authorization (wired via the goodwill ProfileCell override).
    class VerifiedFlairTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "a verified user's profile shows the verified flair" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        FactoryBot.create(:authorization, :granted, user:)

        get "/profiles/#{user.nickname}/activity"

        assert_response :success
        assert_includes response.body, "Verifikovan/a"
      end

      test "a postal-verified user's profile shows letter proof without address data" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        authorization = FactoryBot.create(:authorization, :granted, user:, name: "postal_letter")
        authorization.update_columns(verification_metadata: { "full_address" => "Ulica privatna 12" }) # rubocop:disable Rails/SkipsModelValidations

        get "/profiles/#{user.nickname}/activity"

        assert_response :success
        assert_includes response.body, "Adresa potvrđena pismom"
        assert_not_includes response.body, "Ulica privatna 12"
      end

      test "an unverified user's profile does not show the flair" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)

        get "/profiles/#{user.nickname}/activity"

        assert_response :success
        assert_not_includes response.body, "Verifikovan/a"
      end
    end
  end
end
