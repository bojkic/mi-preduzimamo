# frozen_string_literal: true
require "application_system_test_case"

class RaceVisibilityTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
    @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "race-visible", zona: "grad", name: { sr: "Race area" })
    Decidim::Bih::Race::Standing.create!(organization: @organization, komsiluk: @area, zona: "grad", registered: 1,
      reports: 0, proposals: 0, score: 1, rank_overall: 1, rank_in_zone: 1, computed_at: Time.current, final: false)
  end

  test "both open projector aliases clear figures on a successful hidden poll and restore them" do
    %w(/ekran /biceriseno/ekran).each do |path|
      visit path
      assert_selector "[data-screen-field='registered']", text: "1"
      Decidim::Bih::Race::Visibility.change!(@organization, visible: false, actor: @admin, reason: "Archive")
      page.execute_script("document.dispatchEvent(new Event('visibilitychange'))")
      assert_selector "[data-screen-hidden]", visible: :visible
      assert_equal "", page.evaluate_script("document.querySelector('[data-screen-field=registered]').textContent")
      assert_nil page.evaluate_script("document.body.getAttribute('data-screen-registered')")
      assert_equal 0, page.evaluate_script("document.querySelector('[data-screen-top]').children.length")
      Decidim::Bih::Race::Visibility.change!(@organization, visible: true, actor: @admin, reason: "Restore")
      page.execute_script("document.dispatchEvent(new Event('visibilitychange'))")
      assert_selector "[data-screen-field='registered']", text: "1", visible: :visible
      assert_selector "[data-screen-top] li", count: 1
    end
  end
end
