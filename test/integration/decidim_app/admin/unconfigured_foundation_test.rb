# frozen_string_literal: true
require "test_helper"
require "capybara"

class UnconfiguredFoundationControllerTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers

  setup do
    @organization = create_organization
    @organization.update!(available_locales: %w(sr sr-Cyrl bs hr))
    host! @organization.host
  end

  test "administrator sees configuration requirement in every supported locale without invented review dates" do
    admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    sign_in admin
    %w(sr sr-Cyrl bs hr).each do |locale|
      get "/admin/bih/foundation-status", params: { locale: }
      assert_response :success
      assert_select "#admin-foundation-status-effective", text: /#{Regexp.escape(I18n.t("decidim_app.admin.foundation_status.show.unconfigured", locale:))}/
    end
  end

  test "unconfigured institution does not grant a citizen administrator access" do
    sign_in FactoryBot.create(:user, :confirmed, organization: @organization)
    get "/admin/bih/foundation-status"
    assert_response :redirect
  end
end
