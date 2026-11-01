# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # The profile shows contribution publicly but the spendable wallet ONLY to
    # the owner (private, account-balance-like data).
    class WalletPrivacyTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      WALLET = "Bodovi (stanje)" # private
      WALLET_PANEL = "Bodovi za korištenje" # retired private MI profile panel label
      POSTAL = "Adresa potvrđena pismom"
      REPORTER = "Prijavljuje probleme"
      VOLUNTEER = "Volontira u zajednici"
      HIDDEN = "Javna priznanja su sakrivena"
      KOMSILUK = "Komšija iz Centar Sjever"

      setup do
        @organization = create_organization
        host! @organization.host
        @owner = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::Goodwill::Ledger.new.award(@owner, 50, reason: "proposal")
        FactoryBot.create(:authorization, :granted, user: @owner, name: "postal_letter")
        komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "centar-sjever",
          name: { "bs" => "Centar Sjever", "sr" => "Centar Sjever", "hr" => "Centar Sjever", "en" => "Centar Sjever" }
        )
        Decidim::Bih::CitizenProfile.for_user(@owner, organization: @organization).assign_komsiluk!(komsiluk, source: "dropdown")
        Decidim::Bih::Report.create!(
          organization: @organization,
          author: @owner,
          description: "Rupa na trotoaru"
        )
        opportunity = Decidim::Bih::VolunteerOpportunity.create!(
          organization: @organization,
          title: "Uredjenje parka",
          active: true,
          review_status: "approved"
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @owner,
          hours: 2,
          status: "approved"
        )
      end

      test "anonymous visitors see contribution but NOT the wallet" do
        get "/profiles/#{@owner.nickname}/activity"
        assert_response :success
        assert_select ".mi-public-profile-summary__item", text: /50/
        assert_includes response.body, POSTAL
        assert_includes response.body, REPORTER
        assert_includes response.body, VOLUNTEER
        assert_includes response.body, KOMSILUK
        assert_not_includes response.body, WALLET
        assert_not_includes response.body, WALLET_PANEL
        assert_not_includes response.body, "Tvoj javni profil na MI"
        assert_not_includes response.body, "Samo ti"
      end

      test "another signed-in user does NOT see the wallet" do
        sign_in FactoryBot.create(:user, :confirmed, organization: @organization)
        get "/profiles/#{@owner.nickname}/activity"
        assert_response :success
        assert_not_includes response.body, WALLET
        assert_not_includes response.body, WALLET_PANEL
      end

      test "opted-out public recognition is hidden from other visitors" do
        Decidim::Bih::PublicRecognition.set_enabled!(@owner, false)

        get "/profiles/#{@owner.nickname}/activity"

        assert_response :success
        assert_select ".mi-public-profile-summary__item", count: 0
        assert_not_includes response.body, POSTAL
        assert_not_includes response.body, REPORTER
        assert_not_includes response.body, VOLUNTEER
        assert_not_includes response.body, KOMSILUK
        assert_not_includes response.body, WALLET
        assert_not_includes response.body, "MI profil"
      end

      test "the owner sees public recognition but not private wallet data on the public profile" do
        sign_in @owner
        get "/profiles/#{@owner.nickname}/activity"
        assert_response :success
        assert_select ".mi-public-profile-summary__item", text: /50/
        assert_includes response.body, POSTAL
        assert_includes response.body, REPORTER
        assert_includes response.body, VOLUNTEER
        assert_includes response.body, KOMSILUK
        assert_not_includes response.body, WALLET
        assert_not_includes response.body, WALLET_PANEL
        assert_not_includes response.body, "Tvoj javni profil na MI"
        assert_not_includes response.body, "Samo ti"
      end

      test "the opted-out owner sees public recognition preview and opt-out notice without wallet data" do
        Decidim::Bih::PublicRecognition.set_enabled!(@owner, false)
        sign_in @owner

        get "/profiles/#{@owner.nickname}/activity"

        assert_response :success
        assert_includes response.body, HIDDEN
        assert_select ".mi-public-profile-summary__item", text: /50/
        assert_includes response.body, KOMSILUK
        assert_not_includes response.body, WALLET
        assert_not_includes response.body, WALLET_PANEL
        assert_not_includes response.body, "MI profil"
        assert_not_includes response.body, "Samo ti"
      end

      test "profile root is the MI contribution tab without public social graph tabs" do
        get "/profiles/#{@owner.nickname}"

        assert_response :success
        assert_select ".mi-public-profile"
        assert_select ".mi-public-profile-tab", text: "Doprinos"
        assert_select ".mi-public-profile-tab", text: "Aktivnosti"
        assert_select ".mi-public-profile-tab", text: "Bedževi"
        assert_select ".mi-public-profile-tab.is-active", text: "Doprinos"
        assert_select ".mi-public-profile-tab.is-active", count: 1
        assert_select ".mi-public-profile-hero__actions *", text: "Prati", count: 0
        assert_select "a[href=?]", "/profiles/#{@owner.nickname}/followers", count: 0
        assert_select "a[href=?]", "/profiles/#{@owner.nickname}/following", count: 0
      end

      test "MI public profile tabs use exact active states" do
        get "/profiles/#{@owner.nickname}/activity"

        assert_response :success
        assert_select ".mi-public-profile-tab.is-active", text: "Aktivnosti"
        assert_select ".mi-public-profile-tab.is-active", count: 1

        get "/profiles/#{@owner.nickname}/badges"

        assert_response :success
        assert_select ".mi-public-profile-tab.is-active", text: "Bedževi"
        assert_select ".mi-public-profile-tab.is-active", count: 1
      end

      test "MI badges replace the generic Decidim gamification badge page" do
        get "/profiles/#{@owner.nickname}/badges"

        assert_response :success
        assert_includes response.body, "Javna MI priznanja"
        assert_includes response.body, "Nivo zajedništva"
        assert_includes response.body, KOMSILUK
        assert_not_includes response.body, "decidim.gamification"
      end

      test "public social graph routes are not exposed to other visitors" do
        get "/profiles/#{@owner.nickname}/followers"
        assert_redirected_to "/profiles/#{@owner.nickname}"

        get "/profiles/#{@owner.nickname}/following"
        assert_redirected_to "/profiles/#{@owner.nickname}"
      end

      test "owner can still reach followed items from Moj nalog links" do
        sign_in @owner

        get "/profiles/#{@owner.nickname}/following"

        assert_response :success
      end
    end
  end
end
