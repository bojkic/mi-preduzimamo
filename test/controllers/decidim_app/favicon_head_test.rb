# frozen_string_literal: true

require "test_helper"
require "capybara"

module DecidimApp
  # The legacy rel=icon link must use the compact static public/favicon.ico,
  # not the 432 KB organization upload; every other icon link is unchanged.
  class FaviconHeadTest < ActionDispatch::IntegrationTest
    setup do
      @organization = create_organization
      host! @organization.host
      get "/"
      assert_response :success
      @head = Nokogiri::HTML(response.body).at_css("head")
    end

    test "legacy icon points at the compact static file" do
      legacy = @head.css("link[rel=icon]").select { |l| l["sizes"] == "any" }
      assert_equal ["/favicon.ico"], legacy.pluck("href")
      assert_operator Rails.public_path.join("favicon.ico").size, :<, 10_000
    end

    test "the original organization upload is no longer linked as the legacy icon" do
      assert_not(@head.css("link[rel=icon]").any? { |l| l["sizes"] == "any" && l["href"].to_s.include?("rails/active_storage") })
    end

    test "PNG icon, apple-touch icon and manifest wiring remain" do
      icons = @head.css("link[rel=icon]")
      assert_operator icons.size, :>=, 2, "expected the legacy icon plus Decidim PNG icon"
      assert(icons.any? { |l| l["href"] != "/favicon.ico" })
      assert @head.at_css("link[rel=apple-touch-icon]")
      assert_equal "/manifest.webmanifest", @head.at_css("link[rel=manifest]")["href"]
    end
  end
end
