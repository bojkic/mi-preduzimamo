# frozen_string_literal: true

require "test_helper"
require "support/route_smoke_helpers"
require "decidim/proposals/test/factories"
require "decidim/budgets/test/factories"

# Renders the homepage with the decidim-bih :mi_hero and :mi_cta content
# blocks placed, mirroring the production layout. Covers the poster copy, the
# CTA targets, and the degraded paths: zero activity / zero data must hide the
# ticker and the stats strip without breaking the page.
class MiHeroContentBlockTest < ActionDispatch::IntegrationTest
  include RouteSmokeHelpers

  setup do
    @prior_static_image_path = Decidim::Bih.mi_bot_persona_static_image_path
    Decidim::Bih.mi_bot_persona_static_image_path = "/mi/heart-mark.webp"
    @prior_flagship_process_slug = Decidim::Bih.flagship_process_slug
    Decidim::Bih.flagship_process_slug = "authored-participation"
    setup_smoke_organization!
    create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :mi_hero, weight: 1)
    create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :mi_cta, weight: 50)
    # Same reason as menu_registration_test: this file describes the ordinary
    # hero. Between 6.9.2026 and 14.10.2026 20:00 the suite runs inside the
    # trka komšiluka window, where config/initializers/decidim_bih_launch_mode.rb
    # feeds the cell its own launch buttons and a stat threshold. Pin the mode
    # off so these expectations do not depend on the day the suite is run.
    Decidim::Bih::Setting.put(@organization, "launch", "mode", "off")
  end

  teardown do
    Decidim::Bih.mi_bot_persona_static_image_path = @prior_static_image_path
    Decidim::Bih.flagship_process_slug = @prior_flagship_process_slug
  end

  test "homepage invitation does not promise a fixed number of ways to participate" do
    create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :mi_hub, weight: 2)
    get "/"
    assert_smoke_success("/")
    assert_includes response.body, "Dajemo ti mnogo načina da uzmeš stvari u svoje ruke"
    assert_not_includes response.body, "Četiri načina da preuzmeš grad"
    assert_select ".mi-omni-band__emblem img[src=?]", "/mi/heart-mark.webp"
    assert_select ".mi-omni-band__emblem img[src$='.gif']", count: 0
  end

  test "homepage renders the poster hero and closing CTA without any data" do
    get "/"

    assert_smoke_success("/")

    # Poster stack + eyebrow.
    assert_includes response.body, "PREDLAŽEMO,"
    assert_includes response.body, "ODLUČUJEMO,"
    assert_includes response.body, "MIJENJAMO GRAD."
    assert_select ".mi-hero__identity", count: 0
    assert_select ".mi-hero__learn-more", count: 0

    # Both hero CTAs (no authored-participation process here → fallback hrefs).
    assert_includes response.body, "Pokreni svoju ideju"
    assert_includes response.body, "Vidi gdje idu pare"
    assert_select ".mi-hero__ctas a[href=?]", "/processes/authored-participation", count: 2

    # Trust line.
    assert_includes response.body, "jedan građanin, jedan glas"

    # First-scroll registration value proposition.
    assert_select ".mi-hero-register a[href=?]", "/registracija", text: "Registruj se"
    assert_includes response.body, "Registruj se i preuzmi svoj dio platforme."
    assert_includes response.body, "Bodovi i nagrade za doprinos"
    assert_includes response.body, "Komšiluk tabla i obavještenja"

    # The quick-action bar above the header is gone (2026-09-07); the mobile
    # toolbar carries the primary tasks.
    assert_select ".mi-action-launcher", count: 0
    assert_select ".mi-mobile-bottom-nav a[href=?]", "/biceriseno/prijave/new", text: "Problem"
    assert_select ".mi-mobile-bottom-nav a[href=?]", "/processes", text: "Odlučuj"
    assert_select ".mi-mobile-bottom-nav a[href=?]", "/biceriseno/mi-bot", text: "Milica"
    assert_select ".mi-mobile-more-sheet a[href=?]", "/biceriseno/volontiranje", text: "Volontiraj"
    assert_select ".mi-mobile-more-sheet a[href=?]", "/biceriseno/zajednistvo", text: "Zajedništvo"

    # Zero activity / zero data: ticker absent. The stats strip still shows
    # the fixed campaign figure — it isn't derived from live org data — so
    # the strip itself is never fully empty.
    assert_select ".mi-ticker", count: 0
    assert_select ".mi-hero-stats__item--hi .mi-hero-stats__value", text: "6.000 KM"
    assert_includes response.body, "za projekte komšiluka"

    # Closing CTA block.
    assert_includes response.body, "Grad se ne mijenja sam."
    assert_includes response.body, "Mijenjamo ga MI."
    assert_includes response.body, "#MojaZajednica"
    assert_select ".mi-cta__actions a[href=?]", "/registracija", text: "Pridruži se besplatno"
    assert_select ".mi-cta__actions a[href=?]", "/biceriseno/projekti", text: "Pogledaj projekte"
  end

  test "stats strip shows verified service submissions with correct singular copy" do
    Decidim::Bih::Report.create!(organization: @organization, description: "Rupa na putu", status: "proslijedjeno", forwarded_at: Time.current)

    get "/"

    assert_smoke_success("/")
    assert_select ".mi-hero-stats__value", text: "1"
    # Keep the singular count and its label in agreement.
    assert_includes response.body, "prijava poslata službama"
    assert_not_includes response.body, "riješenih prijava"
  end

  test "hero ticker lists recent public activity" do
    actor = create(:user, :confirmed, organization: @organization, name: "Autorska učesnica")
    component = create(:proposal_component, organization: @organization)
    proposal = create(:proposal, component:, published_at: Time.current)
    create(
      :action_log,
      user: actor,
      organization: @organization,
      action: "publish",
      visibility: "public-only",
      resource: proposal,
      component:,
      participatory_space: component.participatory_space
    )

    get "/"

    assert_smoke_success("/")
    assert_select ".mi-ticker"
    assert_includes response.body, "Autorska učesnica"
  end

  test "hero CTAs deep-link into the flagship process components when they exist" do
    process = create(:participatory_process, :published, slug: "authored-participation", organization: @organization)
    proposals = create(:proposal_component, participatory_space: process)
    budgets = create(:budgets_component, participatory_space: process)

    get "/"

    assert_smoke_success("/")
    assert_select ".mi-hero__ctas a[href=?]", Decidim::EngineRouter.main_proxy(proposals).root_path
    assert_select ".mi-hero__ctas a[href=?]", Decidim::EngineRouter.main_proxy(budgets).root_path
    assert_select ".mi-hero__ctas a[href=?]", "/processes/authored-participation", count: 0
  end

  test "hero ticker skips activity rows from deleted accounts" do
    actor = create(:user, :confirmed, organization: @organization, name: "Nestala Korisnica")
    component = create(:proposal_component, organization: @organization)
    proposal = create(:proposal, component:, published_at: Time.current)
    create(
      :action_log,
      user: actor,
      organization: @organization,
      action: "publish",
      visibility: "public-only",
      resource: proposal,
      component:,
      participatory_space: component.participatory_space
    )
    # Decidim::DestroyAccount blanks the name but keeps the action log rows.
    # rubocop:disable Rails/SkipsModelValidations
    actor.update_columns(name: "", deleted_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations

    get "/"

    assert_smoke_success("/")
    assert_select ".mi-ticker", count: 0
  end

  test "closing CTA points signed-in citizens at their contribution wallet" do
    sign_in_smoke_user!

    get "/"

    assert_smoke_success("/")
    assert_select ".mi-hero-register a[href=?]", "/biceriseno/moj-doprinos", text: "Pogledaj svoj doprinos"
    assert_includes response.body, "Tvoj nalog je spreman."
    assert_select ".mi-hero-register a[href=?]", "/registracija", count: 0
    assert_select ".mi-cta__actions a[href=?]", "/biceriseno/moj-doprinos", text: "Pogledaj svoj doprinos"
    assert_select ".mi-cta__actions a[href=?]", "/registracija", count: 0
  end
end
