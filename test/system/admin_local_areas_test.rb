# frozen_string_literal: true

require "application_system_test_case"

class AdminLocalAreasTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @mz = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "mz",
      slug: "centar-browser",
      name: { "sr" => "Centar browser" },
      predsjednik: "Mira Browser",
      telefon: "055-100-200",
      metadata: { "napomena" => "Interna browser napomena" }
    )
    Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "komsiluk",
      slug: "trg-browser",
      name: { "sr" => "Trg browser" },
      primary_mz_slug: @mz.slug,
      overlapping_mz_slugs: [@mz.slug]
    )
  end

  test "admin local areas workflow tabs render cleanly" do
    sign_in_user! @admin

    visit "/admin/bih/local-areas"
    accept_data_consent!

    assert_selector "#local-areas-header[data-local-areas-active-tab='mz']"
    assert_selector "#local-areas-workflow-nav a[aria-current='page'][href='/sr/admin/bih/local-areas?tab=mz']"
    assert_selector "#local-areas-mz-list", text: "Centar browser"
    assert_selector "#local-areas-mz-list", text: "Mira Browser"
    assert_no_selector "#local-areas-komsiluk-list"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/local-areas?tab=komsiluk"

    assert_selector "#local-areas-header[data-local-areas-active-tab='komsiluk']"
    assert_selector "#local-areas-komsiluk-list", text: "Trg browser"
    assert_selector "#local-areas-komsiluk-list", text: "Centar browser"
    assert_no_selector "#local-areas-mz-list"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/local-areas?tab=routing"

    assert_selector "#local-areas-header[data-local-areas-active-tab='routing']"
    assert_selector "#local-areas-routing-impact", text: "Pregled uticaja rutiranja"
    assert_selector "#local-areas-routing-impact", text: "Trg browser"
    assert_selector "#local-areas-routing-impact", text: "Centar browser"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end
end
