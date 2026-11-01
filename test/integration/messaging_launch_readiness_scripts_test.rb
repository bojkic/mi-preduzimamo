# frozen_string_literal: true

require "test_helper"
require "open3"
require "securerandom"
require "json"
require "tempfile"

class MessagingLaunchReadinessScriptsTest < ActiveSupport::TestCase
  APP_ROOT = Rails.root.to_s
  VIBER_ENV_KEYS = %w(
    DECIDIM_BIH_VIBER_BOT_ENABLED
    DECIDIM_BIH_VIBER_PUBLIC_ONBOARDING_ENABLED
    INFOBIP_API_KEY
    INFOBIP_BASE_URL
    INFOBIP_CHAT_CHANNELS
    INFOBIP_CHAT_WEBHOOK_SECRET
    INFOBIP_MESSENGER_SENDER
    INFOBIP_MESSAGES_API_ENABLED
    INFOBIP_SMS_SENDER
    INFOBIP_VIBER_BM_LOGIN_TEMPLATE_ID
    INFOBIP_VIBER_BM_OTP_TEMPLATE_ID
    INFOBIP_VIBER_BM_SENDER
    INFOBIP_VIBER_BOT_SENDER
    INFOBIP_VIBER_SENDER
    INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME
    INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE
    INFOBIP_WHATSAPP_SENDER
    VIBER_BM_WEBHOOK_SECRET
    VIBER_BOT_URI
    VIBER_WEBHOOK_SECRET
  ).freeze

  teardown do
    hosts = Array(@owned_readiness_hosts)
    next if hosts.empty?

    # These rows were created by this test's child process and are outside the
    # parent transactional fixture. Remove only the exact test-owned tenants.
    code = <<~RUBY
      hosts = JSON.parse(ENV.fetch("OWNED_READINESS_HOSTS"))
      abort "Invalid fixture ownership" unless hosts.all? { |host| /\\A(?:empty-)?messaging-readiness-[a-f0-9]{16}\\.lvh\\.me\\z/.match?(host) }
      Decidim::Organization.where(host: hosts).find_each do |organization|
        # Factory-created mandatory legal pages intentionally reject ordinary
        # deletion. These belong only to this isolated test-owned tenant.
        Decidim::StaticPage.where(organization: organization).delete_all
        # The readiness fixture also creates its own geographic area. The
        # organization does not own a dependent-destroy association for it.
        Decidim::Bih::LocalArea.where(organization: organization).destroy_all
        organization.destroy!
      end
      abort "Owned fixture remains" if Decidim::Organization.where(host: hosts).exists?
    RUBY
    stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "test", "OWNED_READINESS_HOSTS" => JSON.generate(hosts) },
      "bin/rails", "runner", code, chdir: APP_ROOT)
    assert status.success?, "Owned readiness fixture cleanup failed: #{stderr} #{stdout}"
  end

  test "strict Viber readiness accepts the complete legacy phone path while Bot and Messages API are disabled" do
    stdout, stderr, status = run_viber_smoke(
      production_like_viber_env.merge(
        "FAIL_ON_WARN" => "1",
        "INFOBIP_VIBER_SENDER" => "TestLegacyViber"
      )
    )

    assert status.success?, "Expected disabled launch surfaces to pass strict readiness, stderr=#{stderr.inspect}, stdout=#{stdout.inspect}"
    assert_includes stdout, "viber\tbot_launch_gate\tdisabled\tok"
    assert_includes stdout, "viber\tlaunch_approval\tskipped\tok"
    assert_includes stdout, "viber\tINFOBIP_VIBER_BM_SENDER\tpresent\tok\tsource=legacy_alias"
    assert_includes stdout, "viber\tINFOBIP_VIBER_BOT_SENDER\tskipped\tok"
    assert_includes stdout, "viber\tviber_bm_auth_templates\tskipped\tok"
    assert_includes stdout, "viber\tmessages_api\tdisabled\tok"
    assert_includes stdout, "viber\tpublic_onboarding\tdisabled\tok"
    assert_includes stdout, "viber\toverall\tok\tok"
    assert_not_includes stdout, "test-api-key-123456"
    assert_not_includes stdout, "configured-test-secret"
  end

  test "strict Viber readiness rejects partial hidden Bot configuration" do
    stdout, _stderr, status = run_viber_smoke(
      production_like_viber_env.merge(
        "FAIL_ON_WARN" => "1",
        # The Bot is off for this deployment, so a partial config only has to be
        # rejected once someone deliberately switches the Bot back on.
        "DECIDIM_BIH_VIBER_BOT_ENABLED" => "1",
        "INFOBIP_VIBER_SENDER" => "TestLegacyViber",
        "VIBER_BOT_URI" => "testbot"
      )
    )

    assert_not status.success?
    assert_includes stdout, "viber\tbot_launch_gate\trequested\tok"
    assert_includes stdout, "viber\tINFOBIP_VIBER_BOT_SENDER\tmissing\twarn"
    assert_includes stdout, "viber\tinfobip_viber_bot_sender\tmissing\twarn"
    assert_includes stdout, "viber\toverall\twarn\twarn"
    assert_not_includes stdout, "configured-test-secret"
  end

  test "strict Viber readiness treats leftover Bot config as inert while the Bot is switched off" do
    stdout, _stderr, status = run_viber_smoke(
      production_like_viber_env.merge(
        "FAIL_ON_WARN" => "1",
        "INFOBIP_VIBER_SENDER" => "TestLegacyViber",
        # Both a Bot sender and a Bot URI present, and the switch absent. This
        # is the live launch state: credentials alone must never read as a
        # launch request, or the billed channel could come back by accident.
        "INFOBIP_VIBER_BOT_SENDER" => "TestBotSender",
        "VIBER_BOT_URI" => "testbot"
      )
    )

    assert status.success?, "Expected a switched-off Bot to pass strict readiness, stdout=#{stdout.inspect}"
    assert_includes stdout, "viber\tbot_launch_gate\tdisabled\tok"
    assert_includes stdout, "viber\toverall\tok\tok"
  end

  test "strict Viber readiness rejects an opened Business Messages channel with incomplete delivery" do
    stdout, _stderr, status = run_viber_smoke(
      production_like_viber_env.merge(
        "FAIL_ON_WARN" => "1",
        # Channel opened, inbound secret in place, but no Business Messages
        # sender — replies would have nowhere to come from.
        "INFOBIP_CHAT_CHANNELS" => "viber_bm",
        "VIBER_BM_WEBHOOK_SECRET" => "configured-viber-bm-secret"
      )
    )

    assert_not status.success?
    assert_includes stdout, "viber_bm\tchannel_gate\tenabled\tok"
    assert_includes stdout, "viber_bm\ttwo_way_delivery\tincomplete\twarn"
    assert_includes stdout, "viber_bm\twebhook_secret\tpresent\tok"
    assert_not_includes stdout, "configured-viber-bm-secret"
  end

  test "strict Viber readiness rejects enabled Messages API without both Viber templates" do
    stdout, _stderr, status = run_viber_smoke(
      production_like_viber_env.merge(
        "FAIL_ON_WARN" => "1",
        "INFOBIP_MESSAGES_API_ENABLED" => "1",
        "INFOBIP_VIBER_SENDER" => "TestLegacyViber",
        "INFOBIP_VIBER_BM_OTP_TEMPLATE_ID" => "test-otp-template"
      )
    )

    assert_not status.success?
    assert_includes stdout, "viber\tINFOBIP_VIBER_BM_LOGIN_TEMPLATE_ID\tmissing\twarn"
    assert_includes stdout, "viber\tviber_bm_auth_templates\tpartial\twarn"
    assert_includes stdout, "viber\tmessages_api\tenabled\tok"
    assert_includes stdout, "viber\toverall\twarn\twarn"
  end

  test "Viber readiness reports configured WhatsApp AUTH without claiming provider approval" do
    stdout, _stderr, status = run_viber_smoke(
      production_like_viber_env.merge(
        "INFOBIP_MESSAGES_API_ENABLED" => "1",
        "INFOBIP_VIBER_SENDER" => "TestLegacyViber",
        "INFOBIP_VIBER_BM_OTP_TEMPLATE_ID" => "test-otp-template",
        "INFOBIP_VIBER_BM_LOGIN_TEMPLATE_ID" => "test-login-template",
        "INFOBIP_WHATSAPP_SENDER" => "TestWhatsApp",
        "INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME" => "mi_verifikacija_kod_v1",
        "INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE" => "sr"
      )
    )

    assert status.success?, "Expected configured staged transport to pass, stdout=#{stdout.inspect}"
    assert_includes stdout, "viber\tphone_delivery_policy\tviber>whatsapp>sms\tok"
    assert_includes stdout, "viber\twhatsapp_phone_template_language\tsr\tok"
    assert_includes stdout, "viber\twhatsapp_phone_delivery\tconfigured\tok"
    assert_includes stdout, "approval_and_live_delivery_unverified"
    assert_includes stdout, "viber\tmessenger_phone_delivery\texcluded\tok"
  end

  test "Viber readiness warns and skips WhatsApp AUTH with invalid bs language" do
    stdout, _stderr, status = run_viber_smoke(
      production_like_viber_env.merge(
        "FAIL_ON_WARN" => "1",
        "INFOBIP_MESSAGES_API_ENABLED" => "1",
        "INFOBIP_VIBER_SENDER" => "TestLegacyViber",
        "INFOBIP_VIBER_BM_OTP_TEMPLATE_ID" => "test-otp-template",
        "INFOBIP_VIBER_BM_LOGIN_TEMPLATE_ID" => "test-login-template",
        "INFOBIP_WHATSAPP_SENDER" => "TestWhatsApp",
        "INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME" => "mi_verifikacija_kod_v1",
        "INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE" => "bs"
      )
    )

    assert_not status.success?
    assert_includes stdout, "viber\twhatsapp_phone_template_language\tbs\twarn"
    assert_includes stdout, "viber\twhatsapp_phone_delivery\tpartial\twarn"
    assert_includes stdout, "viber\tmessenger_phone_delivery\texcluded\tok"
  end

  test "strict city-service Viber readiness skips collection-only parsers while alerts are disabled" do
    stdout, stderr, status = run_city_service_smoke(
      "FAIL_ON_WARN" => "1",
      "MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "false"
    )

    assert status.success?, "Expected disabled alerts to pass strict readiness, stderr=#{stderr.inspect}, stdout=#{stdout.inspect}"
    assert_match(/city_service_viber\tparser:[^\t]+\tcollection_only\tok\tskipped until/, stdout)
    assert_includes stdout, "city_service_viber\tprovider_readiness\tskipped\tok"
    assert_includes stdout, "city_service_viber\tprovider_health\tskipped\tok"
    assert_includes stdout, "city_service_viber\tlaunch_approval\tskipped\tok"
    assert_includes stdout, "city_service_viber\tMI_CITY_SERVICE_VIBER_ALERTS_ENABLED\tdisabled\tok"
    assert_includes stdout, "city_service_viber\toverall\tok\tok"
  end

  test "strict city-service Viber readiness rejects enabled alerts with collection-only sources" do
    stdout, _stderr, status = run_city_service_smoke(
      "FAIL_ON_WARN" => "1",
      "MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "1",
      "INFOBIP_BASE_URL" => "https://example.test",
      "INFOBIP_API_KEY" => "test-api-key-123456",
      "INFOBIP_VIBER_BM_SENDER" => "TestViberBusiness"
    )

    assert_not status.success?
    assert_match(/city_service_viber\tparser:[^\t]+\tcollection_only\twarn\talerts enabled/, stdout)
    assert_includes stdout, "city_service_viber\tprovider_readiness\tconfigured\tok"
    assert_match(/city_service_viber\tprovider_health\t(?:ok|unknown|stale|failing)\t(?:ok|warn)/, stdout)
    assert_includes stdout, "city_service_viber\tMI_CITY_SERVICE_VIBER_ALERTS_ENABLED\tenabled\tok"
    assert_includes stdout, "city_service_viber\toverall\twarn\twarn"
  end

  test "strict disabled city-service Viber readiness does not require launch targeting data" do
    stdout, stderr, status = run_script(
      "mi_city_service_viber_readiness_smoke",
      VIBER_ENV_KEYS.index_with { nil }.merge(
        "FAIL_ON_WARN" => "1",
        "HOST" => nil,
        "MI_CITY_SERVICE_HEALTH_HOST" => committed_empty_test_organization_host,
        "MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "false"
      )
    )

    assert status.success?, "Expected disabled alerts without launch targeting data to pass, stderr=#{stderr.inspect}, stdout=#{stdout.inspect}"
    assert_includes stdout, "city_service_viber\tpolicy_sample\tskipped\tok\talerts disabled"
    assert_includes stdout, "city_service_viber\toverall\tok\tok"
  end

  test "city-service Viber readiness fails closed for an unknown explicit organization host" do
    stdout, _stderr, status = run_script(
      "mi_city_service_viber_readiness_smoke",
      "MI_CITY_SERVICE_HEALTH_HOST" => "missing-city-service-org.example.test",
      "MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "false"
    )

    assert_not status.success?
    assert_includes stdout, "city_service_viber\torganization\tmissing\tfail"
    assert_includes stdout, "city_service_viber\toverall\tfail\tfail"
    assert_not_includes stdout, "missing-city-service-org.example.test"
  end

  test "unconfigured city-service catalogue stays inactive and needs no inherited source" do
    stdout, stderr, status = run_script("mi_city_service_viber_readiness_smoke",
      "MI_CITY_SERVICE_HEALTH_HOST" => committed_empty_test_organization_host,
      "MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "false", "MI_CITY_SOURCES_PATH" => "", "FAIL_ON_WARN" => "1")
    assert status.success?, "Expected inactive fresh-install diagnostics, stderr=#{stderr.inspect}, stdout=#{stdout.inspect}"
    assert_includes stdout, "city_service_viber\tsource_catalogue\t0\tok"
    assert_includes stdout, "city_service_viber\tpolicy_sample\tskipped\tok\tsample source is not configured or enabled"
    assert_includes stdout, "city_service_viber\ttarget_preview\tskipped\tok"
    assert_includes stdout, "city_service_viber\toverall\tok\tok"
  end

  private

  def production_like_viber_env
    {
      "DECIDIM_BIH_VIBER_PUBLIC_ONBOARDING_ENABLED" => "false",
      "INFOBIP_API_KEY" => "test-api-key-123456",
      "INFOBIP_BASE_URL" => "https://example.test",
      "INFOBIP_MESSAGES_API_ENABLED" => "false",
      "INFOBIP_SMS_SENDER" => "TestSMS",
      "VIBER_WEBHOOK_SECRET" => "configured-test-secret"
    }
  end

  def run_viber_smoke(env)
    run_script(
      "mi_viber_launch_readiness_smoke",
      VIBER_ENV_KEYS.index_with { nil }.merge(env).merge(
        "DECIDIM_CONCIERGE_ORG_HOST" => committed_test_organization_host
      )
    )
  end

  def run_city_service_smoke(env)
    run_script(
      "mi_city_service_viber_readiness_smoke",
      VIBER_ENV_KEYS.index_with { nil }.merge(env).merge(
        "HOST" => nil,
        "MI_CITY_SERVICE_HEALTH_HOST" => committed_test_organization_host
      )
    )
  end

  def run_script(name, env)
    invoke = ->(options) { Open3.capture3(options.merge("RAILS_ENV" => "test"), File.join(APP_ROOT, "script", name), chdir: APP_ROOT) }
    return invoke.call(env) unless name == "mi_city_service_viber_readiness_smoke" && !env.key?("MI_CITY_SOURCES_PATH")

    # Child processes need their own explicit catalogue, with authored URLs.
    rows = DecidimApp::Bijeljina::CityServiceSources::REFERENCE_SOURCES.map do |row|
      row.deep_dup.merge(label: "Izmišljeni testni izvor", provider: "Izmišljeni testni pružalac",
        source_url: "https://#{row.fetch(:key).tr('_', '-')}.example.invalid/notices", enabled: row.fetch(:enabled, true))
    end
    Tempfile.create(["authored-readiness-sources", ".json"]) do |file|
      file.write(JSON.generate(sources: rows)); file.flush
      invoke.call(env.merge("MI_CITY_SOURCES_PATH" => file.path))
    end
  end

  def committed_test_organization_host
    @committed_test_organization_host ||= begin
      host = "messaging-readiness-#{SecureRandom.hex(8)}.lvh.me"
      code = <<~RUBY
        require Rails.root.join("test/support/decidim_test_setup").to_s
        organization = Object.new.extend(DecidimFactoryHelpers).create_organization(host: ENV.fetch("ORG_HOST"))
        unless Decidim::Bih::LocalArea.where(organization:).exists?
          Decidim::Bih::LocalArea.create!(
            organization:,
            kind: "mz",
            slug: ENV.fetch("AREA_SLUG"),
            name: { "bs" => "Test readiness area", "sr" => "Test readiness area" }
          )
        end
        puts organization.host
      RUBY
      stdout, stderr, status = Open3.capture3(
        {
          "AREA_SLUG" => "readiness-#{SecureRandom.hex(8)}",
          "ORG_HOST" => host,
          "RAILS_ENV" => "test"
        },
        "bin/rails",
        "runner",
        code,
        chdir: APP_ROOT
      )
      assert status.success?, "Expected test organization setup to pass, stderr=#{stderr.inspect}, stdout=#{stdout.inspect}"
      created_host = stdout.strip
      assert_equal host, created_host
      (@owned_readiness_hosts ||= []) << created_host
      created_host
    end
  end

  def committed_empty_test_organization_host
    @committed_empty_test_organization_host ||= begin
      host = "empty-messaging-readiness-#{SecureRandom.hex(8)}.lvh.me"
      code = <<~RUBY
        require Rails.root.join("test/support/decidim_test_setup").to_s
        organization = Object.new.extend(DecidimFactoryHelpers).create_organization(host: ENV.fetch("ORG_HOST"))
        puts organization.host
      RUBY
      stdout, stderr, status = Open3.capture3(
        { "ORG_HOST" => host, "RAILS_ENV" => "test" },
        "bin/rails",
        "runner",
        code,
        chdir: APP_ROOT
      )
      assert status.success?, "Expected empty test organization setup to pass, stderr=#{stderr.inspect}, stdout=#{stdout.inspect}"
      created_host = stdout.strip
      assert_equal host, created_host
      (@owned_readiness_hosts ||= []) << created_host
      created_host
    end
  end
end
