# frozen_string_literal: true

# Host wording overrides engine fallback copy after generic sanitization.
community_copy = Rails.root.join("config/locales/decidim_bih_bijeljina_copy.yml").to_s
Rails.application.config.after_initialize do
  I18n.load_path.delete(community_copy)
  I18n.load_path << community_copy
  I18n.reload!
end

# Podešavanja zajednice. Spoljni adapteri nemaju podrazumijevane primaoce.
# Lokalni izvori se povezuju tek poslije eksplicitne konfiguracije administratora.
{
  infobip_sms_sender: "INFOBIP_SMS_SENDER",
  reporter_mailer_from: "REPORTER_MAILER_FROM",
  sistem48_mailer_from: "SISTEM48_FROM",
  sistem48_central_intake: "SISTEM48_CENTRAL_INTAKE",
  sistem48_archive_url: "SISTEM48_ARCHIVE_URL",
  public_support_email: "MI_PUBLIC_SUPPORT_EMAIL",
  mailer_reply_to: "MI_MAILER_REPLY_TO",
  public_support_name: "MI_PUBLIC_SUPPORT_NAME",
  public_support_address: "MI_PUBLIC_SUPPORT_ADDRESS",
  public_support_website: "MI_PUBLIC_SUPPORT_WEBSITE",
  mz_directory_source_label: "MI_AREA_SOURCE_LABEL",
  flagship_process_slug: "MI_FLAGSHIP_PROCESS_SLUG",
  campaign_hashtag: "MI_CAMPAIGN_HASHTAG",
  report_reply_mailbox: "REPORT_REPLY_MAILBOX"
}.each do |setting, variable|
  value = ENV[variable].to_s.strip
  Decidim::Bih.public_send("#{setting}=", value.empty? ? nil : value)
end
Decidim::Bih.sistem48_auto_forward = false
Decidim::Bih.sistem48_forwarded_via_name = "platforme MI preduzimamo"
Decidim::Bih.public_funding_statement = nil
Decidim::Bih.city_data_freshness_provider = nil
Decidim::Bih.city_data_preview_provider = nil
Decidim::Bih.report_mail_transport = ENV.fetch("REPORT_MAIL_TRANSPORT", "gmail")

# Generic host wiring: lookup is per turn, and an unconfigured slug yields nil.
# Never cache a database-dependent component id at boot.
Decidim::Bih.proposal_path = lambda do
  require_dependency Rails.root.join("app/services/decidim_app/bijeljina/civic_destinations").to_s
  DecidimApp::Bijeljina::CivicDestinations.proposal_path
end
