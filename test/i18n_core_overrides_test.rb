# frozen_string_literal: true

require "test_helper"
require "yaml"

# Round 25 / Wave 1 — guards against Decidim CORE i18n keys leaking English on
# the live public site. A frontend audit of mi.fondacijabijeljina.com found the
# cookie-consent dialog, homepage statistics tooltips, the footer attribution,
# and the PWA/offline banner rendering in ENGLISH across every locale because
# the decidim-bih engine never translated them. These keys are owned by
# decidim-core, so the fix lives in the engine's locale files
# (decidim-bih/config/locales/{sr,sr-Cyrl,bs,hr}.yml).
#
# For each key we assert, in each of our four locales, that the translation is
# present and DIFFERS from the canonical English string shipped by decidim-core
# — i.e. it is a real translation and not an English fallback.
#
# The canonical English value is read straight from decidim-core's en.yml rather
# than from the live I18n backend: Decidim prunes the runtime `:en` namespace to
# the configured locales, so untranslated core keys are absent from `:en` at
# runtime even though they are exactly what the public site renders in English.
class I18nCoreOverridesTest < ActiveSupport::TestCase
  LOCALES = %w(sr sr-Cyrl bs hr).freeze

  # Core key paths confirmed against decidim-core 0.31.5 en.yml. Note the
  # cookie/footer/offline keys live under the TOP-LEVEL `layouts.decidim.*`
  # namespace, while the statistics tooltips live under `decidim.statistics.*`.
  KEYS = %w(
    layouts.decidim.data_consent.dialog.title
    layouts.decidim.data_consent.dialog.description
    layouts.decidim.data_consent.modal.title
    layouts.decidim.data_consent.modal.description
    layouts.decidim.data_consent.modal.essential.title
    layouts.decidim.data_consent.modal.essential.description
    layouts.decidim.data_consent.modal.analytics.title
    layouts.decidim.data_consent.modal.analytics.description
    layouts.decidim.data_consent.modal.marketing.description
    layouts.decidim.data_consent.modal.preferences.title
    layouts.decidim.data_consent.modal.preferences.description
    layouts.decidim.data_consent.warning.all_categories
    layouts.decidim.data_consent.warning.change_settings
    layouts.decidim.data_consent.warning.consent_required
    decidim.statistics.users_count_tooltip
    decidim.statistics.comments_count_tooltip
    decidim.statistics.participants_count_tooltip
    decidim.statistics.followers_count_tooltip
    decidim.forms.errors.error
    decidim.pages.index.standalone_pages
    decidim.pages.index.subheading
    decidim.pages.index.title
    decidim.pages.index.topics
    layouts.decidim.footer.made_with_open_source
    layouts.decidim.offline_banner.cache_version_page
  ).freeze

  # Keys whose correct translation is a loanword identical to English in the
  # Latin-script locales (e.g. "Marketing"). We still require them present in
  # every locale, but do not demand they differ from the English value.
  PRESENCE_ONLY_KEYS = %w(
    layouts.decidim.data_consent.modal.marketing.title
  ).freeze

  # Canonical English values, read once from the decidim-core gem's en.yml.
  CORE_EN = begin
    core_dir = Gem.loaded_specs["decidim-core"].gem_dir
    YAML.load_file(File.join(core_dir, "config", "locales", "en.yml")).fetch("en")
  end

  def core_en_value(key)
    key.split(".").reduce(CORE_EN) do |node, segment|
      assert node.is_a?(Hash) && node.has_key?(segment),
             "Sanity check failed: core en.yml has no key #{key.inspect}"
      node[segment]
    end
  end

  KEYS.each do |key|
    LOCALES.each do |locale|
      test "#{key} is translated (not English fallback) in #{locale}" do
        en = core_en_value(key)

        translated =
          begin
            I18n.t(key, locale: locale, raise: true)
          rescue I18n::MissingTranslationData => e
            flunk "Missing translation for #{key} in #{locale}: #{e.message}"
          end

        assert translated.present?, "#{key} is blank in #{locale}"
        assert_not_equal en, translated,
                         "#{key} in #{locale} is still the English value (#{en.inspect})"
      end
    end
  end

  PRESENCE_ONLY_KEYS.each do |key|
    LOCALES.each do |locale|
      test "#{key} is present in #{locale}" do
        # Sanity-check the path against core en.yml without asserting difference.
        core_en_value(key)

        translated =
          begin
            I18n.t(key, locale: locale, raise: true)
          rescue I18n::MissingTranslationData => e
            flunk "Missing translation for #{key} in #{locale}: #{e.message}"
          end

        assert translated.present?, "#{key} is blank in #{locale}"
      end
    end
  end
end
