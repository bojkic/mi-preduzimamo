# frozen_string_literal: true

require "test_helper"
require "capybara"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"

module DecidimApp
  class KomsilukCampaignLinksTest < ActionDispatch::IntegrationTest
    setup do
      @organization = create_organization
      create(:user, :admin, :confirmed, organization: @organization)
      @area = Decidim::Bih::LocalArea.create!(
        organization: @organization,
        kind: "komsiluk",
        slug: "komsiluk-1",
        name: { "sr" => "Savino" }
      )
      DecidimApp::Bijeljina::KomsilukNamingCampaignSetup.call(
        organization: @organization,
        nomination_start: Date.new(2026, 9, 1),
        nomination_end: Date.new(2026, 9, 21),
        voting_end: Date.new(2026, 10, 5)
      )
      host! @organization.host
    end

    test "numeric smart link redirects to the matching filtered proposal list" do
      get "/k/1"

      assert_response :redirect
      assert_includes response.location, "/processes/imenujmo-komsiluke/"
      assert_includes CGI.unescape(response.location), "with_any_taxonomies"
      assert_includes CGI.unescape(response.location), DecidimApp::Bijeljina::KomsilukNamingCampaign.taxonomy_id_for_area(@area).to_s
    end

    test "slug smart link resolves and unknown or cross-tenant links fail closed" do
      get "/k/komsiluk-1"
      assert_response :redirect

      get "/k/999"
      assert_response :not_found

      other = create_organization
      host! other.host
      get "/k/1"
      assert_response :not_found
    end
  end
end
