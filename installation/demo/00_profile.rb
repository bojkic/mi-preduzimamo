# frozen_string_literal: true

# Present only in the demo image. A runtime/production image has no HTTP/capture override.
raise "Demo image requires explicit demo profile" unless ENV["MI_INSTALL_PROFILE"] == "demo" && ENV["MI_LOCAL_HTTP"] == "true"
raise "Demo host must stay local" unless ENV.fetch("RAILS_ALLOWED_HOSTS", "").split(",").all? { |host| %w(127.0.0.1 localhost).include?(host) }

Rails.application.config.force_ssl = false
Rails.application.config.assume_ssl = false
Rails.application.config.action_mailer.default_url_options = { host: "127.0.0.1", port: ENV.fetch("MI_WEB_PORT", "3100"), protocol: "http" }

require Rails.root.join("installation/demo/drain_probe_job")
