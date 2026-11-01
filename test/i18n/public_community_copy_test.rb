# frozen_string_literal: true
require "test_helper"
require "yaml"

class PublicCommunityCopyTest < ActiveSupport::TestCase
  test "host wording has priority over engine fallback across all supported locales" do
    copy = YAML.safe_load_file(Rails.root.join("config/locales/decidim_bih_bijeljina_copy.yml"))
    %w(sr sr-Cyrl bs hr en).each do |locale|
      expected = copy.fetch(locale).fetch("decidim").fetch("bih").fetch("concierge")
      assert_equal expected.fetch("help"), I18n.t("decidim.bih.concierge.help", locale:)
      assert_equal expected.fetch("status").fetch("not_found").gsub("%{reference}", "TEST-REFERENCE"),
                   I18n.t("decidim.bih.concierge.status.not_found", locale:, reference: "TEST-REFERENCE")
    end
  end

  test "host priority persists when the I18n backend reloads" do
    expected = I18n.t("decidim.bih.concierge.help", locale: "sr")
    I18n.backend.reload!
    assert_equal expected, I18n.t("decidim.bih.concierge.help", locale: "sr")
  end

  test "community project interpolation renders in all four application locales" do
    %w(sr sr-Cyrl bs hr).each do |locale|
      text = I18n.t("mi_project_choice.component_intro", locale:, name: "AUTHORED-TEST")
      assert_includes text, "AUTHORED-TEST"
      assert_not_includes text, "%{name}"
      assert_not_includes text, "Translation missing"
      assert_match(/\p{Cyrillic}/, text) if locale == "sr-Cyrl"
    end
  end
end
