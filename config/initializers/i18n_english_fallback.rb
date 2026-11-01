# frozen_string_literal: true

# Decidim ships some strings (notably the emoji-picker data used by every page's
# JS config) ONLY under the `en` locale. This app restricts the user-facing
# locales to the Bosnian-market set (sr/sr-Cyrl/bs/hr), which removed the
# implicit English fallback — so a string missing in `sr` (like `emojis`) is
# returned as a raw "translation missing" String and breaks rendering.
#
# Make `en` the explicit ultimate i18n fallback (and a valid fallback target),
# realizing CLAUDE.md's "untranslated UI falls back to English". This runs after
# Decidim sets `config.i18n.fallbacks = true`, so it takes precedence.
Rails.application.config.after_initialize do
  require "i18n/backend/fallbacks"
  I18n::Backend::Simple.include(I18n::Backend::Fallbacks) unless I18n.backend.is_a?(I18n::Backend::Fallbacks)
  # `en` must be a permitted locale for I18n to use it as a fallback target.
  I18n.available_locales = (I18n.available_locales | [:en])
  I18n.fallbacks = I18n::Locale::Fallbacks.new(:en)
  # The backend loaded translations before `en` was permitted, so `en.yml`
  # strings (incl. the emoji-picker data) were skipped. Reload now that `en` is
  # available so they are present as fallback targets.
  I18n.backend.reload!
  # Complete the final catalogue reload at startup, before a civic turn's
  # nine-second budget starts. Otherwise the first translation lookup can
  # time out and make an understood, supported question appear unavailable.
  I18n.eager_load!
end
