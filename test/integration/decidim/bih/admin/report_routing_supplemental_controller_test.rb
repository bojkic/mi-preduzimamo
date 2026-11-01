# frozen_string_literal: true

require "test_helper"
require "capybara"

class ReportRoutingSupplementalControllerTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers

  setup do
    @organization = create_organization
    @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
    host! @organization.host
    sign_in @admin
    Decidim::Bih::Setting.put(@organization, "sistem48_routing", "saobracaj", "reviewed@fixtures.invalid")
  end

  test "Rails multiple select blanks are removed on create and clearing an edit" do
    post "/admin/bih/report-routing-guides", params: { guide: values }
    assert_response :redirect
    guide = Decidim::Bih::ReportRoutingGuide.find_by!(organization: @organization, key: "synthetic-routing")
    assert_equal ["saobracaj"], guide.categories
    assert_equal ["saobracaj"], guide.approved_recipient_keys
    assert_equal @admin.id, guide.approved_by_id
    assert guide.active

    patch "/admin/bih/report-routing-guides/#{guide.id}", params: { guide: { categories: [""], approved_recipient_keys: [""], body_sr: "Updated reviewed guidance" } }
    assert_response :redirect
    assert_empty guide.reload.categories
    assert_empty guide.approved_recipient_keys
    assert_equal 2, guide.version
  end

  test "nonblank unknown selections remain invalid and cannot change reviewed guidance" do
    guide = Decidim::Bih::ReportRoutingGuide.create!(organization: @organization, approved_by: @admin,
                                                     key: "synthetic-routing", title: "Reviewed guide", body_sr: "Protected guidance", active: true,
                                                     categories: ["saobracaj"], approved_recipient_keys: ["saobracaj"])
    before = guide.attributes
    patch "/admin/bih/report-routing-guides/#{guide.id}", params: { guide: { categories: ["", "invented"], approved_recipient_keys: ["", "invented"] } }
    assert_response :unprocessable_entity
    assert_equal before, guide.reload.attributes
  end

  private

  def values
    { key: "synthetic-routing", title: "Reviewed guide", body_sr: "Synthetic reviewed guidance", active: "1",
      categories: ["", "saobracaj"], approved_recipient_keys: ["", "saobracaj"] }
  end
end
