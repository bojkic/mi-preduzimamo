# frozen_string_literal: true

require_relative "boot"

# Languages for the Bosnian market — UI translations are provided by the
# decidim-bih engine. Codes:
#   sr      = Serbian (Latin)     — Decidim's existing translations
#   sr-Cyrl = Serbian (Cyrillic)  — generated from `sr` via decidim-bih
#   bs      = Bosnian
#   hr      = Croatian
# Must be set BEFORE Decidim loads (it reads these env vars lazily and memoizes
# them during boot). Kept here, not in .env, so the choice is version-controlled;
# `||=` lets a real ENV/deploy still override. Switch the default to "sr-Cyrl"
# to make Cyrillic the primary script.
ENV["DECIDIM_AVAILABLE_LOCALES"] ||= "sr,sr-Cyrl,bs,hr"
ENV["DECIDIM_DEFAULT_LOCALE"] ||= "sr"

# Keep browser sessions for 365 days of inactivity. Set before Decidim
# builds both the cookie store and Devise timeout from this value (minutes).
ENV["DECIDIM_EXPIRE_SESSION_AFTER"] ||= "525600"

require "decidim/rails"

# Add the frameworks used by your app that are not loaded by Decidim.
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)
require_relative "runtime_asset_configuration"

module DecidimApp
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w(assets tasks))

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Bijeljina local time so goodwill daily caps roll over at local (not UTC)
    # midnight. ActiveRecord stays UTC for storage.
    config.time_zone = "Europe/Sarajevo"
    # config.eager_load_paths << Rails.root.join("extras")

    # Re-sync ActiveRecord's attribute filter from the fully-populated
    # filter_parameters list.
    #
    # WHY THIS IS NEEDED: Rails' active_record.set_filter_attributes railtie
    # snapshots config.filter_parameters into
    # ActiveRecord::Base.filter_attributes BEFORE config/initializers/*.rb and
    # before engine initializers run. Decidim and this app both add entries
    # (including :phone) in those later stages, so the snapshot captures an
    # empty list and ActiveRecord::Base.filter_attributes stays [].
    #
    # The consequence is not cosmetic: ActiveRecord::LogSubscriber#filter
    # redacts SQL bind parameters using the GLOBAL
    # ActiveRecord::Base.inspection_filter, which is derived from
    # filter_attributes and never consults a per-model override. With the
    # global empty, raw phone numbers from decidim_bih_viber_linkages and
    # decidim_bih_viber_business_contacts are printed in SQL logs whenever an
    # operator raises the log level to debug — exactly when someone is
    # troubleshooting an incident and least thinking about PII.
    #
    # Setting it on Base propagates through the class_attribute to every model
    # that has not overridden it. Verified: a per-model
    # `filter_attributes = [:phone]` does NOT stop the leak; only this does.
    config.after_initialize do |app|
      # Rails 8.1 adds qualified model filters to filter_parameters while
      # loading models. Share the values, never the mutable array: aliasing it
      # would repeatedly prefix inherited filters during eager loading.
      ActiveRecord::Base.filter_attributes = app.config.filter_parameters.dup
    end
  end
end
