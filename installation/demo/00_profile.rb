# frozen_string_literal: true

# Present only in the demo image. A runtime/production image has no HTTP/capture override.
raise "Demo image requires explicit demo profile" unless ENV["MI_INSTALL_PROFILE"] == "demo" && ENV["MI_LOCAL_HTTP"] == "true"

allowed_hosts = ENV.fetch("RAILS_ALLOWED_HOSTS", "").split(",")
raise "Demo host must stay local" unless allowed_hosts.any? && allowed_hosts.all? { |host| %w(127.0.0.1 localhost).include?(host) }

Rails.application.config.force_ssl = false
Rails.application.config.assume_ssl = false
Rails.application.config.action_mailer.default_url_options = { host: "127.0.0.1", port: ENV.fetch("MI_WEB_PORT", "3100"), protocol: "http" }

Rails.application.config.to_prepare do
  require Rails.root.join("installation/demo/drain_probe_job")
end

# The engine's proof mail normally links to the organization's public HTTPS
# domain. This file exists only in the explicitly guarded local demo image.
module MiDemoEmailProofOrigin
  private

  def confirmation_url(token, organization)
    raise "Demo confirmation host must stay local" unless %w(127.0.0.1 localhost).include?(organization.host)

    port = Integer(ENV.fetch("MI_WEB_PORT", "3100"))
    raise "Invalid local demo port" unless (1024..65_535).cover?(port)

    Decidim::Bih.public_url("potvrdi-email/#{token}", base_url: "http://127.0.0.1:#{port}")
  end
end

Rails.application.config.to_prepare do
  mailer = Decidim::Bih::EmailConfirmationMailer
  mailer.prepend(MiDemoEmailProofOrigin) unless mailer < MiDemoEmailProofOrigin
end
