# frozen_string_literal: true

# The one guarded way this host assigns a Decidim::Bih setting.
#
# The host app and the decidim-bih engine deploy through SEPARATE git
# operations, and production loads the engine's working tree directly (see
# CLAUDE.md — "Production loads the engine's working tree directly"). A window
# therefore exists in which this host ships before the engine gains a setting,
# or the engine is rolled back under a host that is already live. An
# initializer that just assigns would turn that window into a NoMethodError at
# boot — a TOTAL SITE OUTAGE over a feature toggle — instead of the feature
# quietly running on the engine's own default.
#
# So every assignment goes through here: apply it only when the running engine
# actually defines the setter, and log once (never raise) when one is skipped,
# so version skew shows up in the log rather than killing boot.
#
# Loaded twice on purpose, and safe both times: each consumer pulls it in with
# require_relative (so the dependency is explicit and cannot break on a rename
# or a change in initializer load order), and Rails then `load`s it again as an
# initializer in its own right — `load` does not consult the require cache. The
# guard below makes the second evaluation a no-op rather than a silent
# redefinition of the module.
return if defined?(DecidimBihSettings)

module DecidimBihSettings
  module_function

  # `prefix` names the calling initializer in the log line, so a skipped
  # setting is traceable to the file that wanted it.
  def apply(prefix, setting, value)
    setter = :"#{setting}="
    unless Decidim::Bih.respond_to?(setter)
      Rails.logger.warn(
        "[#{prefix}] Decidim::Bih.#{setter} is not defined by the loaded " \
        "decidim-bih engine — skipping. The engine may predate this setting; " \
        "its own default will be used instead."
      )
      return false
    end

    Decidim::Bih.public_send(setter, value)
    true
  end
end
