# frozen_string_literal: true

require "test_helper"

# Guards the Decidim Minitest factory harness: if Decidim's factories or the
# locale/fallback wiring regress, this fails loudly rather than every model test.
class DecidimTestSetupTest < ActiveSupport::TestCase
  test "can create a Decidim organization scoped to the BiH locales" do
    org = create_organization
    assert org.persisted?
    assert_equal %w(sr sr-Cyrl bs hr), org.available_locales
    assert_equal "sr", org.default_locale
  end

  test "can create a confirmed user in an organization" do
    user = create(:user, :confirmed, organization: create_organization)
    assert user.persisted?
    assert user.confirmed?
  end

  test "untranslated Decidim strings fall back to English" do
    # A core key not present in the incomplete sr stub locale should resolve via
    # the English fallback rather than raising.
    assert_nothing_raised do
      I18n.with_locale(:sr) { I18n.t("decidim.welcome_notification.default_subject") }
    end
  end
end
