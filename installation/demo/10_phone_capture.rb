# frozen_string_literal: true

# Loaded only by the explicit demo image; never modifies provider Client#configured?.
if ENV["MI_DEMO_PHONE_CAPTURE"] == "true"
  unless ENV["MI_INSTALL_PROFILE"] == "demo" && ENV["MI_LOCAL_HTTP"] == "true" && ENV["SMTP_ADDRESS"] == "mail" && ENV["SMTP_PORT"] == "1025"
    raise "Phone capture requires local demo SMTP"
  end
  raise "Phone capture requires installer identity" unless ENV.fetch("MI_INSTALL_ID", "").match?(/\Ami-[0-9a-f]{16}\z/)

  require Rails.root.join("installation/demo/phone_capture")

  Rails.application.config.to_prepare do
    Decidim::Bih.phone_auth_demo_client_factory = -> { MiDemoPhoneCapture.new } if ENV["MI_INSTALL_PROFILE"] == "demo" && ENV["MI_DEMO_PHONE_CAPTURE"] == "true"
  end
end
