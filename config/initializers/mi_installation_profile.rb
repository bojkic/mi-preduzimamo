# frozen_string_literal: true

# Existing host deployments leave this unset. Public container installations
# select one explicit profile; a production image rejects demo switches.
profile = ENV.fetch("MI_INSTALL_PROFILE", nil)
if profile.present?
  raise "Unknown MI installation profile" unless %w(demo production).include?(profile)

  if profile == "production" && %w(MI_LOCAL_HTTP MI_LOCAL_PHONE_CAPTURE MI_DEMO_PHONE_CAPTURE).any? { |key| ENV[key] == "true" }
    raise "Production profile refuses demo HTTP/phone capture overrides"
  end
end
