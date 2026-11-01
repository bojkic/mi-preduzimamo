# frozen_string_literal: true

# test/integration/decidim_app/menu_registration_test.rb
require "test_helper"
require "capybara"

module DecidimApp
  class MenuRegistrationTest < ActionDispatch::IntegrationTest
    setup do
      @organization = create_organization
      create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :global_menu, weight: 10)
      host! @organization.host
      # This file describes the STEADY-STATE public menu. Between 6.9.2026 and
      # 14.10.2026 20:00 the suite itself runs inside the trka komšiluka window,
      # where config/initializers/decidim_bih_launch_mode.rb deliberately swaps
      # Volontiraj/Projekti/Naš uticaj for the launch pages and adds Milica —
      # so without this pin these expectations would go red for six weeks of
      # the calendar and green again afterwards. The launch-mode menu has its
      # own coverage in test/integration/launch_mode_navigation_test.rb.
      Decidim::Bih::Setting.put(@organization, "launch", "mode", "off")
    end

    EXPECTED_PUBLIC_LABELS = [
      "Prijavi problem",
      "Odlučuj",
      "Volontiraj",
      "Projekti",
      "Zajedništvo",
      "Komšiluk",
      "Naš uticaj"
    ].freeze

    REMOVED_PUBLIC_LABELS = [
      "Prijave",
      "Praćenje prijava",
      "Mapa prijava",
      "Donacije",
      "Uticaj",
      "Volontiranje",
      "Bodovi zajedništva",
      "Milica",
      "Vodič",
      "Kako funkcioniše",
      "Tabla doprinosa",
      "Nagrade",
      "Pozovi komšije",
      "Moj doprinos"
    ].freeze

    test "the homepage carries direct Bih capability navigation" do
      get "/"
      follow_redirect! while response.redirect?
      assert_response :success

      [
        "Vodič",
        "Prijavi problem",
        "Volontiraj",
        "Projekti",
        "Odlučuj",
        "Milica",
        "Zajedništvo",
        "Moj komšiluk"
      ].each do |label|
        assert_includes response.body, label
      end

      assert_select ".home__menu__container"
      assert_select ".home__menu-element--link", count: 8
      assert_select ".home__menu a[href=?]", "/biceriseno/vodic?locale=sr"
      assert_select ".home__menu a[href=?]", "/biceriseno/prijave/new?locale=sr"
      assert_select ".home__menu a[href=?]", "/biceriseno/volontiranje?locale=sr"
      assert_select ".home__menu a[href=?]", "/biceriseno/projekti?locale=sr"
      assert_select ".home__menu a[href=?]", "/processes"
      assert_select ".home__menu a[href=?][data-mi-bot-open]", "/biceriseno/mi-bot?locale=sr" do
        assert_select "svg.home__menu-icon use[href$='#ri-chat-new-line']", count: 1
      end
      assert_select ".home__menu a[href=?]", "/biceriseno/zajednistvo?locale=sr"
      assert_select ".home__menu a[href=?]", "/biceriseno/komsiluk-board?locale=sr" do
        assert_select "svg.home__menu-icon use[href$='#ri-home-heart-line']", count: 1
      end
    end

    test "the removed standalone items are absent from the public menu body" do
      get "/"
      follow_redirect! while response.redirect?
      assert_response :success
      # The nav menu should NOT contain these as standalone items (they live
      # inside the hub or in the account/user menu). We check that the menu
      # helper itself does not register them.
      menu = Decidim::Menu.new(:menu)
      menu.build_for(@controller.view_context)
      menu_labels = menu.items.map(&:label)

      REMOVED_PUBLIC_LABELS.each do |label|
        assert_not_includes menu_labels, label,
                            "Expected '#{label}' to be absent from the public :menu"
      end
    end

    test "the public action labels appear in the public menu" do
      menu = Decidim::Menu.new(:menu)

      get "/"
      follow_redirect! while response.redirect?
      menu.build_for(@controller.view_context)
      menu_labels = menu.items.map(&:label)

      assert_includes menu_labels, "Prijavi problem",
                      "Expected the report action label in the public :menu"
      assert_not_includes menu_labels, "Praćenje prijava",
                          "Expected report tracker to stay out of the main public :menu"
    end

    test "the public menu contains the grouped Bih items" do
      menu = Decidim::Menu.new(:menu)

      get "/"
      follow_redirect! while response.redirect?
      menu.build_for(@controller.view_context)
      menu_labels = menu.items.map(&:label)

      EXPECTED_PUBLIC_LABELS.each do |label|
        assert_includes menu_labels, label,
                        "Expected '#{label}' to be present in the public :menu"
      end
    end

    test "wallet and board are registered in the user_menu" do
      # Build the user_menu with a stub view context that satisfies the helpers
      # Decidim core's user_menu registration calls (available_verification_workflows,
      # route helpers, current_user, etc.). We only need the item to be added.
      get "/"
      follow_redirect! while response.redirect?

      view_ctx = @controller.view_context
      # Stub available_verification_workflows so Decidim's core block runs cleanly.
      view_ctx.singleton_class.define_method(:available_verification_workflows) { [] }

      menu = Decidim::Menu.new(:user_menu)
      menu.build_for(view_ctx)
      menu_labels = menu.items.map(&:label)

      assert_includes menu_labels, "Moj doprinos",
                      "Expected 'Moj doprinos' (wallet) to be present in :user_menu"
      assert_includes menu.items.map { |item| [item.label, item.url] },
                      [I18n.t("decidim.bih.menu.komsiluk"), "/biceriseno/komsiluk-board?locale=sr"]
    end

    test "organization memberships are registered in the user_menu" do
      user = FactoryBot.create(:user, :confirmed, organization: @organization)
      profile = Decidim::Bih::PartnerProfile.create!(
        organization: @organization,
        display_name: "Udruženje Meni",
        slug: "udruzenje-meni",
        kind: "association",
        verification_status: "verified",
        verified_at: Time.current
      )
      profile.memberships.create!(
        organization: @organization,
        user:,
        role: "owner",
        status: "accepted",
        accepted_at: Time.current
      )

      get "/"
      follow_redirect! while response.redirect?

      view_ctx = @controller.view_context
      organization = @organization
      view_ctx.singleton_class.define_method(:available_verification_workflows) { [] }
      view_ctx.singleton_class.define_method(:current_user) { user }
      view_ctx.singleton_class.define_method(:current_organization) { organization }

      menu = Decidim::Menu.new(:user_menu)
      menu.build_for(view_ctx)
      menu_labels = menu.items.map(&:label)
      menu_urls = menu.items.map(&:url)

      assert_includes menu_labels, "Moje organizacije"
      assert_includes menu_labels, "Organizacija: Udruženje Meni"
      assert_includes menu_urls, "/biceriseno/organizacije?locale=sr"
      assert_includes menu_urls, "/biceriseno/organizacija/udruzenje-meni?locale=sr"
    end

    test "organizations entry is visible in the user_menu before membership" do
      user = FactoryBot.create(:user, :confirmed, organization: @organization)

      get "/"
      follow_redirect! while response.redirect?

      view_ctx = @controller.view_context
      organization = @organization
      view_ctx.singleton_class.define_method(:available_verification_workflows) { [] }
      view_ctx.singleton_class.define_method(:current_user) { user }
      view_ctx.singleton_class.define_method(:current_organization) { organization }

      menu = Decidim::Menu.new(:user_menu)
      menu.build_for(view_ctx)
      menu_labels = menu.items.map(&:label)
      menu_urls = menu.items.map(&:url)

      assert_includes menu_labels, "Moje organizacije"
      assert_includes menu_urls, "/biceriseno/organizacije?locale=sr"
    end

    test "wallet is absent from the public menu" do
      menu = Decidim::Menu.new(:menu)

      get "/"
      follow_redirect! while response.redirect?
      menu.build_for(@controller.view_context)
      menu_labels = menu.items.map(&:label)

      assert_not_includes menu_labels, "Moj doprinos",
                          "Expected 'Moj doprinos' (wallet) to be absent from the public :menu"
    end
  end
end
