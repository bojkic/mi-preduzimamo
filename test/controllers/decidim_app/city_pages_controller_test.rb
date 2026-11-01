# frozen_string_literal: true

require "test_helper"
# Integration tests that render Decidim layouts need Capybara loaded so
# Decidim::UrlOptionResolver can reference Capybara.server_port.
require "capybara"

module DecidimApp
  # Legacy public city-data URLs now redirect to MI bot. Host-only city-service
  # data remains available through the concierge and admin preview, not direct
  # anonymous browse pages.
  class CityPagesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @organization = create_organization
      host! @organization.host
    end

    test "waste URL redirects to MI bot instead of rendering city-service data" do
      get "/biceriseno/odvoz-smeca"
      assert_redirected_to "/biceriseno/mi-bot"
    end

    test "budget URL redirects to MI bot instead of rendering city-service data" do
      get "/biceriseno/budzet"
      assert_redirected_to "/biceriseno/mi-bot"
    end
  end
end
