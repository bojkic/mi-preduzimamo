# frozen_string_literal: true

require "test_helper"
require "support/route_smoke_helpers"

class RouteSmokeTest < ActionDispatch::IntegrationTest
  include RouteSmokeHelpers

  PUBLIC_GET_ROUTES = {
    "/" => nil,
    "/biceriseno" => nil,
    "/biceriseno/prijave/new" => nil,
    "/biceriseno/prijave" => nil,
    "/biceriseno/mapa" => nil,
    "/biceriseno/mapa.json" => "application/json",
    "/biceriseno/mapa-problema" => nil,
    "/biceriseno/projekti" => nil,
    "/biceriseno/donacije" => nil,
    "/biceriseno/uticaj" => nil,
    "/biceriseno/zajednistvo" => nil,
    "/biceriseno/zajednistvo?tab=tabla" => nil,
    "/biceriseno/zajednistvo?tab=nagrade" => nil,
    "/biceriseno/zajednistvo?tab=pozovi" => nil,
    "/biceriseno/zajednistvo?tab=kako" => nil,
    "/biceriseno/zajednistvo?tab=tabla&period=month" => nil,
    "/biceriseno/podrzi" => nil,
    "/biceriseno/volontiranje" => nil,
    "/biceriseno/mi-bot" => nil,
    "/processes" => nil,
    "/pages/terms-of-service" => nil,
    "/up" => nil
  }.freeze

  AUTHENTICATED_GET_ROUTES = [
    "/biceriseno/moj-doprinos"
  ].freeze

  ADMIN_GET_ROUTES = [
    "/admin/bih/goodwill",
    "/admin/decidim_awesome/maintenance/checks",
    "/admin/decidim_awesome/maintenance/private_data",
    "/admin/decidim_awesome/maintenance/hashcash",
    "/admin/decidim_awesome/maintenance/hashcash/ip_addresses"
  ].freeze

  setup do
    setup_smoke_organization!
    reset_smoke_concierge!
    stub_decidim_awesome_release_check!
  end

  teardown { reset_smoke_concierge! }

  PUBLIC_GET_ROUTES.each do |path, media_type|
    test "public GET #{path} is reachable" do
      get path

      assert_smoke_reachable(path, require_body: path != "/up")
      assert_equal media_type, response.media_type if media_type
    end
  end

  AUTHENTICATED_GET_ROUTES.each do |path|
    test "authenticated citizen GET #{path} is reachable" do
      sign_in_smoke_user!

      get path

      assert_smoke_success(path)
    end
  end

  test "public dynamic organization profile is reachable" do
    group = FactoryBot.create(
      :user,
      :confirmed,
      organization: @organization,
      name: "Udruženje smoke",
      extended_data: { "group" => true }
    )
    profile = Decidim::Bih::PartnerProfile.create!(
      organization: @organization,
      display_name: "Udruženje smoke",
      slug: "udruzenje-smoke",
      kind: "association",
      verification_status: "verified",
      legacy_user_group: group,
      verified_at: Time.current
    )
    Decidim::Bih::Goodwill::Ledger.new.award(group, 10, reason: "route_smoke")

    get "/biceriseno/organizacija/#{profile.slug}"

    assert_smoke_success("/biceriseno/organizacija/:id")
    assert_includes response.body, "Udruženje smoke"
  end

  test "homepage global menu shows the civic navigation links" do
    create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :global_menu, weight: 10)

    get "/"

    assert_smoke_success("/")
    assert_select "a[href=?]", "/biceriseno/prijave/new"
    assert_select "a[href=?]", "/biceriseno/volontiranje"
    assert_select "a[href=?]", "/biceriseno/projekti"
    assert_select "a[href=?]", "/processes"
    assert_select "a[href=?]", "/biceriseno/mi-bot"
    assert_select "a[href=?]", "/biceriseno/zajednistvo"
    assert_select "a[href=?]", "/biceriseno/komsiluk-board"
    assert_select ".home__menu__container"
    assert_select ".home__menu-element--link", count: 8

    menu = Decidim::Menu.new(:home_content_block_menu)
    menu.build_for(@controller.view_context)
    menu_links = menu.items.map { |item| [item.label, item.url] }

    assert_includes menu_links, ["Vodič", "/biceriseno/vodic"]
    assert_includes menu_links, ["Prijavi problem", "/biceriseno/prijave/new"]
    assert_includes menu_links, ["Volontiraj", "/biceriseno/volontiranje"]
    assert_includes menu_links, ["Projekti", "/biceriseno/projekti"]
    assert_includes menu_links, ["Odlučuj", "/processes"]
    assert_includes menu_links, ["Milica", "/biceriseno/mi-bot"]
    assert_includes menu_links, ["Zajedništvo", "/biceriseno/zajednistvo"]
    assert_includes menu_links, ["Moj komšiluk", "/biceriseno/komsiluk-board"]
  end

  test "public POST /biceriseno/chat is reachable through the same-origin web chat endpoint" do
    post "/biceriseno/chat",
         params: { message: "zdravo" }.to_json,
         headers: WEB_CHAT_HEADERS

    assert_smoke_success("/biceriseno/chat")
    assert response.parsed_body["reply"].present?, "Expected /biceriseno/chat to return a reply"
  end

  ADMIN_GET_ROUTES.each do |path|
    test "authenticated admin GET #{path} renders without credentials from production" do
      sign_in_smoke_admin!

      get path

      assert_smoke_success(path)
    end
  end

  private

  def stub_decidim_awesome_release_check!
    return unless respond_to?(:stub_request)

    %w(
      https://api.github.com/repos/decidim/decidim/releases
      https://api.github.com/repos/decidim-ice/decidim-module-decidim_awesome/releases
    ).each do |url|
      stub_request(:get, url)
        .to_return(
          status: 200,
          body: [{ tag_name: "v0.0.0", name: "Test release" }].to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end
  end
end
