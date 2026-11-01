# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class WalletPageTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "anonymous visitors are redirected away" do
        get "/biceriseno/moj-doprinos"
        assert_response :redirect
      end

      test "a signed-in citizen sees their wallet, level and history" do
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 100, reason: "volunteer_hour")
        sign_in @user

        get "/biceriseno/moj-doprinos"

        assert_response :success
        assert_includes response.body, "Moj doprinos"
        assert_includes response.body, "Volonterski sat" # history entry label for the earn
      end

      test "the wallet links to the invite tab on the hub" do
        sign_in @user
        get "/biceriseno/moj-doprinos"
        assert_response :success
        assert_includes response.body, "/biceriseno/zajednistvo?tab=pozovi"
        assert_includes response.body, "Pozovi komšije"
      end

      test "wallet response includes mi-install.js" do
        sign_in @user
        get "/biceriseno/moj-doprinos"
        assert_response :success
        assert_includes response.body, "mi-install.js"
      end

      test "wallet renders the season score when goodwill_season_started_at is set" do
        # Award points so there is a season figure to show
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 50, reason: "report")
        old_val = Decidim::Bih.goodwill_season_started_at
        begin
          Decidim::Bih.goodwill_season_started_at = Date.new(2026, 1, 1)
          sign_in @user
          get "/biceriseno/moj-doprinos"
          assert_response :success
          # The wallet view shows the season block when @season_score is non-nil
          assert_includes response.body, "Ova sezona",
                          "season section must render when goodwill_season_started_at is set"
        ensure
          Decidim::Bih.goodwill_season_started_at = old_val
        end
      end

      test "wallet hides season score when goodwill_season_started_at is nil" do
        old_val = Decidim::Bih.goodwill_season_started_at
        begin
          Decidim::Bih.goodwill_season_started_at = nil
          sign_in @user
          get "/biceriseno/moj-doprinos"
          assert_response :success
          assert_not_includes response.body, "Ova sezona",
                              "season section must not render when goodwill_season_started_at is nil"
        ensure
          Decidim::Bih.goodwill_season_started_at = old_val
        end
      end

      test "the wallet renders a monthly contribution statement grouped by month" do
        ledger = Decidim::Bih::Goodwill::Ledger.new
        # Two earns in different months so two month buckets appear.
        mar = ledger.award(@user, 100, reason: "proposal")
        mar.update_column(:created_at, Time.utc(2026, 3, 10, 12)) # rubocop:disable Rails/SkipsModelValidations
        mar.entries.update_all(created_at: Time.utc(2026, 3, 10, 12)) # rubocop:disable Rails/SkipsModelValidations
        apr = ledger.award(@user, 40, reason: "proposal")
        apr.update_column(:created_at, Time.utc(2026, 4, 5, 9)) # rubocop:disable Rails/SkipsModelValidations
        apr.entries.update_all(created_at: Time.utc(2026, 4, 5, 9)) # rubocop:disable Rails/SkipsModelValidations

        sign_in @user
        get "/biceriseno/moj-doprinos"

        assert_response :success
        # Both month headers render (localized "%B %Y").
        assert_includes response.body, I18n.l(Date.new(2026, 3, 1), format: "%B %Y")
        assert_includes response.body, I18n.l(Date.new(2026, 4, 1), format: "%B %Y")
        # The cumulative running balance of the latest month equals the wallet balance (100 + 40).
        assert_includes response.body, "140"
      end

      test "a signed-in citizen sees their reward fulfillment statuses" do
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 600, reason: "volunteer_hour")
        Decidim::Bih::Goodwill::RedeemReward.call(@user, "majica")
        sign_in @user

        get "/biceriseno/moj-doprinos"

        assert_response :success
        assert_includes response.body, "Moje nagrade"
        assert_includes response.body, I18n.t("decidim.bih.goodwill.rewards.majica")
        assert_includes response.body, "Zatraženo"
      end
    end
  end
end
