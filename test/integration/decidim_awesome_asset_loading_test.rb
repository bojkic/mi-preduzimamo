# frozen_string_literal: true

require "test_helper"
require "capybara"

class DecidimAwesomeAssetLoadingTest < ActionDispatch::IntegrationTest
  BICERISENO_PUBLIC_ROUTES = [
    "/biceriseno/prijave/new",
    "/biceriseno/mapa",
    "/biceriseno/donacije",
    "/biceriseno/volontiranje",
    "/biceriseno/mi-bot"
  ].freeze

  setup do
    @organization = create_organization
    host! @organization.host
  end

  BICERISENO_PUBLIC_ROUTES.each do |path|
    test "#{path} omits global Decidim Awesome public packs" do
      get path

      assert_response :success
      assert_no_global_awesome_assets
    end
  end

  test "MI homepage uses its smaller public pack and omits global Awesome packs" do
    get "/"

    assert_response :success
    assert_no_global_awesome_assets
    assert_select "script[src*=mi_home]"
    assert_select "script[src*=decidim_core]", count: 0
    assert_select "script[src*=decidim_sw][defer]"
  end

  test "normal Decidim public pages still load global Decidim Awesome packs" do
    create(:participatory_process, :published, organization: @organization)

    get "/processes"

    assert_response :success
    assert_global_awesome_assets
  end

  private

  def assert_no_global_awesome_assets
    assert_not_includes response.body, "decidim_decidim_awesome"
    assert_not_includes response.body, "decidim_decidim_awesome_custom_fields"
  end

  def assert_global_awesome_assets
    assert_includes response.body, "decidim_decidim_awesome"
    assert_includes response.body, "decidim_decidim_awesome_custom_fields"
  end
end
