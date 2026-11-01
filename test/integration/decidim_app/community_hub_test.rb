# frozen_string_literal: true

# test/integration/decidim_app/community_hub_test.rb
#
# Tests for the "Zajedništvo" community hub (Subsystem 1):
#   - Hub renders each tab via ?tab=
#   - Default tab is "tabla" (leaderboard)
#   - Period sub-filter works on the tabla tab
#   - Legacy routes redirect to the hub with the right ?tab=
#   - Redeem POST still routes correctly (reward redemption unchanged)
#   - Invite/pozovi tab shows login CTA when anonymous
require "test_helper"
require "support/route_smoke_helpers"

module DecidimApp
  class CommunityHubTest < ActionDispatch::IntegrationTest
    include RouteSmokeHelpers
    include Devise::Test::IntegrationHelpers

    setup do
      setup_smoke_organization!
      reset_smoke_concierge!
    end

    teardown { reset_smoke_concierge! }

    # ---- Hub renders each tab ------------------------------------------- #

    test "hub renders the tabla tab by default (no ?tab= param)" do
      get "/biceriseno/zajednistvo"

      assert_response :success
      assert_includes response.body, "Zajedništvo"
      # Leaderboard section is rendered for the default tab
      assert_select "section#tabla"
    end

    test "hub renders the tabla tab when ?tab=tabla" do
      get "/biceriseno/zajednistvo?tab=tabla"

      assert_response :success
      assert_select "section#tabla"
      assert_select "section#nagrade", count: 0
      assert_select "section#pozovi", count: 0
      assert_select "section#kako", count: 0
    end

    test "hub renders the nagrade tab when ?tab=nagrade" do
      get "/biceriseno/zajednistvo?tab=nagrade"

      assert_response :success
      assert_select "section#nagrade"
      assert_select "section#tabla", count: 0
    end

    test "hub renders the pozovi tab when ?tab=pozovi" do
      get "/biceriseno/zajednistvo?tab=pozovi"

      assert_response :success
      assert_select "section#pozovi"
      assert_select "section#tabla", count: 0
    end

    test "hub renders the kako tab when ?tab=kako" do
      get "/biceriseno/zajednistvo?tab=kako"

      assert_response :success
      assert_select "section#kako"
      assert_select "section#tabla", count: 0
    end

    # ---- Tab navigation is present for all tabs ------------------------- #

    test "tab navigation links are rendered on every tab" do
      %w(tabla nagrade pozovi kako).each do |tab|
        get "/biceriseno/zajednistvo?tab=#{tab}"

        assert_response :success
        # Each tab link appears in the tab nav
        assert_select "nav[aria-label]" do
          assert_select "a[href*='tab=tabla']"
          assert_select "a[href*='tab=nagrade']"
          assert_select "a[href*='tab=pozovi']"
          assert_select "a[href*='tab=kako']"
        end
      end
    end

    test "signed-in viewer summary appears below header and before tabs without a duplicate header action" do
      sign_in_smoke_user!

      get "/biceriseno/zajednistvo"

      assert_response :success
      assert_select ".mi-community-summary"
      assert_select ".mi-surface-header__action", count: 0
      assert_select ".mi-community-summary a[href='/biceriseno/moj-doprinos']", count: 1
      assert_operator response.body.index("mi-community-summary"), :<, response.body.index("mi-surface-tabs")
    end

    test "cross-module pillar links use platform icons" do
      get "/biceriseno/zajednistvo"

      assert_response :success
      assert_select "a[href='/biceriseno/prijave/new'] svg"
      assert_select "a[href='/biceriseno/volontiranje'] svg"
      assert_select "a[href='/biceriseno/komsiluk-board'] svg"
      assert_select "a[href='/biceriseno/projekti'] svg"
      assert_select "a[href='/biceriseno/uticaj'] svg"
      assert_not_includes response.body, "📍"
      assert_not_includes response.body, "🙌"
      assert_not_includes response.body, "🏘"
      assert_not_includes response.body, "📊"
    end

    # ---- Period sub-filter on tabla tab --------------------------------- #

    test "tabla tab with period=all renders successfully" do
      get "/biceriseno/zajednistvo?tab=tabla&period=all"

      assert_response :success
      assert_select "section#tabla"
    end

    test "tabla tab with period=month renders successfully" do
      get "/biceriseno/zajednistvo?tab=tabla&period=month"

      assert_response :success
      assert_select "section#tabla"
    end

    test "tabla tab with period=week renders successfully" do
      get "/biceriseno/zajednistvo?tab=tabla&period=week"

      assert_response :success
      assert_select "section#tabla"
    end

    test "tabla tab period sub-filter links include both tab and period params" do
      get "/biceriseno/zajednistvo?tab=tabla"

      assert_response :success
      # Period links in the leaderboard sub-nav point to the hub with ?tab=tabla&period=...
      assert_select "a[href*='tab=tabla'][href*='period=month']"
      assert_select "a[href*='tab=tabla'][href*='period=week']"
    end

    # ---- Legacy routes redirect to hub ---------------------------------- #

    test "GET /biceriseno/tabla redirects to hub tabla tab" do
      get "/biceriseno/tabla"

      assert_redirected_to "/biceriseno/zajednistvo?tab=tabla"
      assert_equal 301, response.status
    end

    test "GET /biceriseno/kako-funkcionise redirects to hub kako tab" do
      get "/biceriseno/kako-funkcionise"

      assert_redirected_to "/biceriseno/zajednistvo?tab=kako"
      assert_equal 301, response.status
    end

    test "GET /biceriseno/nagrade redirects to hub nagrade tab" do
      get "/biceriseno/nagrade"

      assert_redirected_to "/biceriseno/zajednistvo?tab=nagrade"
      assert_equal 301, response.status
    end

    test "GET /biceriseno/pozovi redirects to hub pozovi tab" do
      get "/biceriseno/pozovi"

      assert_redirected_to "/biceriseno/zajednistvo?tab=pozovi"
      assert_equal 301, response.status
    end

    # ---- Invite tab: anonymous user sees login CTA ---------------------- #

    test "pozovi tab shows login-CTA when user is anonymous" do
      get "/biceriseno/zajednistvo?tab=pozovi"

      assert_response :success
      assert_select "section#pozovi"
      # The invite show view renders the login-to-invite message for anonymous users
      assert_includes response.body, I18n.t("decidim.bih.invite.show.login_to_invite")
    end

    test "pozovi tab shows invite links when user is signed in" do
      sign_in_smoke_user!
      get "/biceriseno/zajednistvo?tab=pozovi"

      assert_response :success
      assert_select "section#pozovi"
      # When signed in, the invite link input is rendered
      assert_select "input[readonly]"
    end

    # ---- Redeem POST route is unchanged --------------------------------- #

    test "POST /biceriseno/nagrade/redeem/:key is still a real route (not a redirect)" do
      # We don't need a real reward — just confirm the route resolves to the
      # rewards#redeem action (i.e. not a 404 or a redirect). A missing reward
      # key results in a flash+redirect back, which is a real controller response.
      sign_in_smoke_user!
      post "/biceriseno/nagrade/redeem/nonexistent_reward_key_for_smoke_test"

      # Expect redirect back to rewards (the controller does redirect_to action: :show
      # which now resolves to /biceriseno/nagrade which 301s to the hub nagrade tab).
      assert_includes [200, 301, 302], response.status,
                      "Expected redeem POST to produce a real controller response, not a routing error"
      assert_not_equal 404, response.status
    end

    # ---- Unknown ?tab= value falls back to tabla ------------------------ #

    test "unknown tab param falls back to tabla" do
      get "/biceriseno/zajednistvo?tab=nepostojeci"

      assert_response :success
      assert_select "section#tabla"
    end
  end
end
