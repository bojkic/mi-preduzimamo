# frozen_string_literal: true

require "test_helper"
require "yaml"

# Decidim ships no sr/bs/hr locales and the host falls back straight to en, so
# any core key the citizen meets during sign-up, mail or verification must be
# supplied by decidim-bih. These are the ones a first-time citizen hits.
#
# The English baseline is read from the gems' own `en.yml` files on disk, not
# from the runtime I18n backend: `en` is not among DECIDIM_AVAILABLE_LOCALES
# (sr, sr-Cyrl, bs, hr), so Decidim prunes parts of the runtime `:en` namespace
# and `I18n.t(key, locale: :en)` cannot be trusted as the "still English"
# baseline — it can come back nil and make the comparison pass vacuously.
class DecidimCoreKeysTranslatedTest < ActiveSupport::TestCase
  LOCALES = %w(sr bs hr sr-Cyrl).freeze

  KEYS = %w(
    decidim.newsletter_mailer.newsletter.no_reply_notice
    decidim.newsletters_opt_in_mailer.notify.subject
    decidim.verifications.authorizations.index.granted_verification
    decidim.verifications.authorizations.index.pending_verification
    decidim.verifications.authorizations.index.unauthorized_methods
    decidim.authorization_handlers.sms.name
    decidim.authorization_handlers.sms.explanation
    decidim.authorization_handlers.postal_letter.name
    decidim.authorization_handlers.postal_letter.explanation
    decidim.verifications.sms.authorizations.new.title
    decidim.verifications.sms.authorizations.new.send
    decidim.verifications.sms.authorizations.create.success
    decidim.verifications.sms.authorizations.create.error
    decidim.verifications.sms.authorizations.update.success
    decidim.verifications.sms.authorizations.update.error
    decidim.verifications.sms.authorizations.destroy.success
    decidim.verifications.authorizations.new.authorize_with
    decidim.verifications.authorizations.new.authorize
    decidim.verifications.authorizations.create.unconfirmed
    decidim.verifications.authorizations.create.success
    decidim.verifications.authorizations.create.error
    decidim.verifications.postal_letter.authorizations.create.success
    decidim.verifications.postal_letter.authorizations.update.success
    decidim.verifications.postal_letter.authorizations.update.error
    decidim.wizard_step_form.wizard_aside.back
    forms.required_explanation
    forms.required
    activemodel.attributes.mobile_phone.mobile_phone_number
    devise.failure.unconfirmed
  ).freeze

  # Every `%{}` name any of the keys above uses, so a translation can be
  # rendered without I18n::MissingInterpolationArgument.
  PLACEHOLDERS = { authorizer: "X", organization_name: "O", link: "L", unsubscribe: "U" }.freeze

  # Gems owning the English source of those keys, in i18n load order (later
  # wins), so the baseline matches what English would actually render.
  ENGLISH_SOURCE_GEMS = %w(devise decidim-core decidim-verifications).freeze

  def self.deep_merge(base, overlay)
    base.merge(overlay) do |_key, a, b|
      a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
    end
  end

  ENGLISH = ENGLISH_SOURCE_GEMS.each_with_object({}) do |gem_name, acc|
    spec = Gem.loaded_specs.fetch(gem_name)
    file = File.join(spec.gem_dir, "config", "locales", "en.yml")
    acc.replace(deep_merge(acc, YAML.load_file(file).fetch("en")))
  end.freeze

  def english_source(key)
    key.split(".").reduce(ENGLISH) { |node, part| node.is_a?(Hash) ? node[part] : nil }
  end

  LOCALES.each do |locale|
    test "citizen-facing core keys are not English in #{locale}" do
      KEYS.each do |key|
        english = english_source(key)
        # Guards the key list itself: a renamed/misspelled key would otherwise
        # look "translated" simply because there is nothing to compare against.
        assert_kind_of String, english, "#{key} has no English source in the gems — check the key name"

        # No interpolation values are passed, so I18n returns the raw string and
        # the comparison is raw-against-raw.
        local = I18n.t(key, locale:, default: nil)
        assert_not_nil local, "#{key} missing in #{locale}"
        assert_not_equal english, local, "#{key} still English in #{locale}"
      end
    end

    test "translated core keys keep the gems' placeholders and render in #{locale}" do
      KEYS.each do |key|
        expected = english_source(key).to_s.scan(/%\{(\w+)\}/).flatten.uniq.sort
        local = I18n.t(key, locale:, default: nil).to_s
        assert_equal expected, local.scan(/%\{(\w+)\}/).flatten.uniq.sort,
                     "#{key} in #{locale} does not carry the same %{} placeholders as English"

        assert_nothing_raised { I18n.t(key, locale:, **PLACEHOLDERS) }
      end
    end
  end
end
