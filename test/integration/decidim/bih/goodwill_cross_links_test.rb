# frozen_string_literal: true

# test/integration/decidim/bih/goodwill_cross_links_test.rb
require "test_helper"
require "capybara"

module Decidim
  module Bih
    class GoodwillCrossLinksTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "the gifts page links onward to the goodwill surfaces" do
        sign_in @user
        get "/biceriseno/podrzi"
        assert_redirected_to %r{/biceriseno/moj-doprinos\?locale=sr&tab=podrzi\z}
        follow_redirect!
        assert_response :success
        # Signed-in gifts live in the wallet (engine 6e01eb13): it links to the hub,
        # whose default tab is the leaderboard, and to the other wallet tabs.
        assert_includes response.body, 'href="/biceriseno/zajednistvo"'
        assert_includes response.body, "/biceriseno/moj-doprinos?locale=sr&amp;tab=nagrade"
        assert_includes response.body, "/biceriseno/zajednistvo?tab=pozovi"
      end

      test "the leaderboard hub tab renders without server error" do
        # Legacy /biceriseno/tabla 301s to the hub; test the canonical hub URL.
        get "/biceriseno/zajednistvo?tab=tabla"
        assert_response :success
        # The hub renders leaderboard content — at minimum the hub title appears.
        assert_includes response.body, "Zajedništvo"
      end
    end
  end
end
