# frozen_string_literal: true
require "test_helper"
require "capybara"

class PublicConsentDefaultsTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_organization
    @organization.update!(available_locales: %w(sr sr-Cyrl bs hr))
    host! @organization.host
  end

  test "public consent describes the disabled optional integrations without inherited installation identifiers" do
    %w(sr sr-Cyrl bs hr).each do |locale|
      get "/otvoreni-kod", params: { locale: }
      assert_response :success
      description = I18n.t("layouts.decidim.data_consent.dialog.description", locale:)
      assert_includes response.body, ERB::Util.html_escape(description)
      assert_select 'meta[name="mi-analytics-config"]', count: 0
      assert_select 'script[src*="mi-analytics.js"], script[src*="googletagmanager"], script[src*="cloudflareinsights"]', count: 0
      assert_no_match(/G-[A-Z0-9]{6,}/, response.body)
      assert_no_match(/_ga_[A-Z0-9]+/, response.body)
    end
    optional_cookies = Decidim.consent_categories.reject { |category| category[:mandatory] }.flat_map { |category| Array(category[:items]) }
    assert_empty optional_cookies
    assert_equal "mi-consent-v2", Decidim.consent_cookie_name
  end
end
