# frozen_string_literal: true

# Test harness for exercising Decidim-integrated models/features under Minitest.
#
# Decidim is RSpec-centric; its factories generate data with English Faker and
# its code falls back to English for untranslated strings. This app restricts
# the user-facing locales to the Bosnian-market set (sr/sr-Cyrl/bs/hr), so for
# the TEST environment we additionally:
#   - load Decidim's FactoryBot factories,
#   - load English + Faker's English locale data,
#   - register :en and wire English as the i18n fallback.
# (Production keeps the four-locale set; this affects tests only.)

require "factory_bot_rails"
require "decidim/dev"
require "decidim/core/test/factories"

faker_dir = Gem.loaded_specs["faker"].gem_dir
I18n.load_path += Dir[File.join(faker_dir, "lib/locales/en.yml")]
I18n.load_path += Dir[File.join(faker_dir, "lib/locales/en/*.yml")]
I18n.available_locales = (I18n.available_locales + [:en]).uniq

require "i18n/backend/fallbacks"
I18n::Backend::Simple.include(I18n::Backend::Fallbacks)
I18n.fallbacks = I18n::Locale::Fallbacks.new(:en)
I18n.backend.reload!
Faker::Config.locale = :en

# Helpers for building Decidim records scoped to this app's locales.
module DecidimFactoryHelpers
  # The user-facing locales this app enables; pinning them here keeps the
  # organization off Decidim's default full-locale list (which includes locales
  # we deliberately don't ship translation data for, e.g. :ca).
  BIH_LOCALES = %w(sr sr-Cyrl bs hr).freeze

  def create_organization(**attrs)
    FactoryBot.create(
      :organization,
      **organization_defaults,
      **attrs
    )
  end

  private

  def organization_defaults
    token = SecureRandom.hex(4)
    {
      available_locales: BIH_LOCALES,
      default_locale: "sr",
      # Date.current in fixture setup and inside an organization request must
      # describe the same day, including after local midnight but before UTC.
      time_zone: Time.zone.name,
      name: localized_text("Test organizacija #{token}"),
      short_name: localized_text("Test#{token}"),
      description: localized_text("Test organization #{token}"),
      admin_terms_of_service_body: localized_text("Test admin terms #{token}"),
      # Guaranteed-unique host so a polluted test DB can never collide with the
      # factory's process-local host sequence.
      host: "test-#{SecureRandom.hex(8)}.lvh.me"
    }
  end

  def localized_text(value)
    BIH_LOCALES.index_with { value }
  end
end
