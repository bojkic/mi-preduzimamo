# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class OnboardingGuideTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "signed-out guide shows the full capability index and registration path" do
        get "/biceriseno/vodic"

        assert_response :success
        assert_select ".mi-guide h1", text: "Šta mogu ovdje?"
        assert_select ".mi-guide-account a[href=?]", "/registracija", text: "Registruj se"

        expected_links = [
          "/biceriseno/prijave/new",
          "/biceriseno/mi-bot",
          "/biceriseno/verifikacija",
          "/biceriseno/prijave",
          "/biceriseno/mapa",
          "/biceriseno/mapa-problema",
          "/biceriseno/uticaj",
          "/processes",
          "/biceriseno/volontiranje",
          "/biceriseno/moj-doprinos",
          "/biceriseno/zajednistvo",
          "/biceriseno/zajednistvo?tab=nagrade",
          "/biceriseno/komsiluk-board",
          "/biceriseno/projekti",
          "/biceriseno/mjesne-zajednice"
        ]

        expected_links.each do |href|
          assert_select ".mi-guide a[href='#{href}']"
        end

        assert_not_includes response.body, "translation missing"
        assert_not_includes response.body, "translation_missing"
      end

      test "signed-in guide points citizens to the MI account overview" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        sign_in user

        get "/biceriseno/vodic"

        assert_response :success
        assert_select ".mi-guide-account h2", text: "Nastavi tamo gdje si stao/la"
        assert_select ".mi-guide-account a[href='/biceriseno/moj-nalog']", text: "Otvori moj nalog"
      end
    end
  end
end
