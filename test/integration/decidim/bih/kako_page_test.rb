# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # R12 — public onboarding explainer at /biceriseno/kako-funkcionise.
    class KakoPageTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "GET kako-funkcionise renders the explainer with earn schedule and levels" do
        # Legacy URL 301s to hub kako tab; test the canonical hub URL directly.
        get "/biceriseno/zajednistvo?tab=kako"

        assert_response :success
        assert_includes response.body, "Kako funkcioniše"
        # The earning schedule action labels appear (volonterski sat is the headline).
        assert_includes response.body, "Volonterski sat"
        # Recognition levels appear (komšija -> heroj titles).
        assert_includes response.body, "Heroj grada"
        assert_includes response.body, "ručno potvrđuje zalihe"
      end

      test "the explainer renders for an anonymous visitor (no auth required)" do
        get "/biceriseno/zajednistvo?tab=kako"
        assert_response :success
      end

      test "legacy GET /biceriseno/kako-funkcionise redirects to hub kako tab" do
        get "/biceriseno/kako-funkcionise"
        assert_redirected_to "/biceriseno/zajednistvo?tab=kako"
        assert_equal 301, response.status
      end
    end
  end
end
