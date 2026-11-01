# frozen_string_literal: true

require "application_system_test_case"

class KomsilukAddressSuggestTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
    create_local_areas!
  end

  test "citizen can assign komsiluk through address suggest without storing address" do
    geocoder = lambda do |address|
      assert_equal "Glavna 1", address

      [{ lat: 44.758, lon: 19.215, label: "Glavna 1", precision: "address" }]
    end

    Decidim::Bih::Geo::Geocoder.stub(:search, geocoder) do
      sign_in_user! @citizen

      visit "/biceriseno/komsiluk"
      accept_data_consent!
      page.execute_script("const details = document.querySelector('#bih-address-suggest').closest('details'); if (details) details.open = true")
      fill_in "bih-address-input", with: "Glavna 1"
      click_button I18n.t("decidim.bih.komsiluk.edit.address_search", locale: :sr)

      assert_selector "#bih-address-candidate-list button", count: 1
      assert_equal "", find_by_id("bih-address-komsiluk-id", visible: :hidden).value
      within("#bih-address-candidate-list") { click_button I18n.t("decidim.bih.address_candidates.choose", locale: :sr) }
      assert_selector "#bih-address-result", text: "Centar Sjever", visible: :visible
      assert_equal "44.758", find_by_id("bih-address-lat", visible: :hidden).value
      assert_equal "19.215", find_by_id("bih-address-lon", visible: :hidden).value
      click_button I18n.t("decidim.bih.komsiluk.edit.address_confirm", locale: :sr)
      assert_text I18n.t("decidim.bih.komsiluk.update.success", name: "Centar Sjever", locale: :sr)
    end

    profile = Decidim::Bih::CitizenProfile.find_by!(user: @citizen)
    assert_equal @komsiluk.id, profile.komsiluk_id
    assert_equal @mz.id, profile.mz_id
    assert_equal "address", profile.source
    assert_not profile.attributes.has_key?("address")
  end

  test "onboarding broad street result requires a map choice and editing clears old results" do
    candidates = [{ lat: 44.758, lon: 19.215, label: "Glavna", precision: "street" }]
    Decidim::Bih::Geo::Geocoder.stub(:search, candidates) do
      sign_in_user! @citizen
      visit "/biceriseno/komsiluk"
      accept_data_consent!
      fill_in "bih-address-input", with: "Glavna"
      click_button I18n.t("decidim.bih.komsiluk.edit.address_search", locale: :sr)
      assert_selector "#bih-address-candidate-list button", count: 1
      assert_equal "", find_by_id("bih-komsiluk-select").value
      within("#bih-address-candidate-list") { click_button I18n.t("decidim.bih.address_candidates.show_map", locale: :sr) }
      assert_selector "#bih-address-map-hint", visible: :visible
      assert_equal "", find_by_id("bih-komsiluk-select").value
      fill_in "bih-address-input", with: "Other street"
      assert_no_selector "#bih-address-candidates", visible: :visible
      assert_equal "", find_by_id("bih-komsiluk-select").value
    end
  end

  private

  def create_local_areas!
    @mz = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "mz",
      slug: "mz-centar-system",
      name: { "sr" => "MZ Centar" },
      boundary: polygon(19.20, 44.75, 19.23, 44.77)
    )
    @komsiluk = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "komsiluk",
      slug: "komsiluk-centar-system",
      name: { "sr" => "Centar Sjever" },
      boundary: polygon(19.21, 44.755, 19.22, 44.76)
    )
  end

  def polygon(west, south, east, north)
    {
      "type" => "Polygon",
      "coordinates" => [
        [
          [west, south],
          [east, south],
          [east, north],
          [west, north],
          [west, south]
        ]
      ]
    }
  end
end
