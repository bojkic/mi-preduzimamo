# frozen_string_literal: true

# Reads the effective Action Mailer STARTTLS setting out of the REAL
# config/environments/production.rb, in a throwaway process whose environment is
# supplied by a fixture env file.
#
# It defines an empty Rails::Application subclass (so `config` is a real
# Rails::Application::Configuration) and `load`s the production environment
# file; it never calls `initialize!`, so no initializer, database, Redis or
# mail connection is opened. Only the boolean is written out: SMTP host, user
# name and password never leave this process.
require "bundler/setup"
require "json"
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "decidim/env"

class SmtpProbeApplication < Rails::Application
end

load File.expand_path("config/environments/production.rb", Dir.pwd)

settings = Rails.application.config.action_mailer.smtp_settings
File.write(
  ENV.fetch("SMTP_PROBE_OUTPUT"),
  JSON.generate(
    "enable_starttls_auto" => settings[:enable_starttls_auto],
    "enable_starttls_auto_class" => settings[:enable_starttls_auto].class.name,
    "keys" => settings.keys.map(&:to_s).sort
  )
)
