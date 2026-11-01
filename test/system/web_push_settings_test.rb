# frozen_string_literal: true

require "application_system_test_case"

class WebPushSettingsTest < ApplicationSystemTestCase
  # Check the bundle selected by the current manifest, including test builds
  # without content hashes. A stale unrelated bundle must not satisfy the guard.
  PUSH_MODULE_MARKER = "data-push-enable"

  def self.compiled_push_module?
    manifest = JSON.parse(Rails.public_path.join("packs-test/manifest.json").read)
    asset = manifest["decidim_sw.js"]
    return false unless asset.is_a?(String) && asset.match?(%r{\A/packs-test/js/decidim_sw(?:-[a-zA-Z0-9]+)?\.js\z})

    Rails.public_path.join(asset.delete_prefix("/")).read.include?(PUSH_MODULE_MARKER)
  rescue Errno::ENOENT, JSON::ParserError
    false
  end

  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @user = create(:user, :confirmed, organization: @organization)
    @old_public = Decidim.vapid_public_key
    @old_private = Decidim.vapid_private_key
    @flag = ENV.fetch("DECIDIM_BIH_WEB_PUSH_ENABLED", nil)
    @subject = ENV.fetch("VAPID_SUBJECT", nil)
    key = WebPush.generate_key
    Decidim.vapid_public_key = key.public_key
    Decidim.vapid_private_key = key.private_key
    ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = "true"
    ENV["VAPID_SUBJECT"] = "mailto:notifications@example.org"
    sign_in_user!(@user)
  end

  teardown do
    Decidim.vapid_public_key = @old_public
    Decidim.vapid_private_key = @old_private
    ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = @flag
    ENV["VAPID_SUBJECT"] = @subject
  end

  test "compiled permission module renders mobile controls and handles denial" do
    assert_compiled_push_module!
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/notifications_settings"
    accept_data_consent!
    assert_selector "[data-push-notifications-toggle][data-initialized=true]", visible: :all
    assert_selector "[data-push-status]", text: I18n.t("decidim.bih.web_push.ready", locale: :sr), wait: 15
    assert_no_horizontal_overflow!
    page.execute_script('window.Notification.requestPermission = async () => "denied";')
    find("[data-push-enable]").click
    assert_selector "[data-push-status]", text: I18n.t("decidim.bih.web_push.blocked", locale: :sr)
    assert_selector "[data-push-test][disabled]"
  end
  test "compiled default invitation needs a click and respects dismissal" do
    assert_compiled_push_module!
    page.driver.browser.manage.window.resize_to(390, 844)
    visit "/notifications"
    accept_data_consent!
    assert_selector "[data-push-offer]", visible: true
    assert_no_horizontal_overflow!
    page.execute_script('window.pushPermissionCalls = 0; window.Notification.requestPermission = async () => { window.pushPermissionCalls += 1; return "default"; };')
    assert_equal 0, page.evaluate_script("window.pushPermissionCalls")
    find("[data-push-enable]").click
    assert_equal 1, page.evaluate_script("window.pushPermissionCalls")
    assert_selector "[data-push-offer]", visible: true
    find("[data-push-dismiss]").click
    assert_no_selector "[data-push-offer]", visible: true
    visit "/notifications"
    assert_selector "[data-push-offer]", visible: :hidden
  end

  private

  def assert_compiled_push_module!
    assert_equal "1", ENV.fetch("DECIDIM_TEST_COMPILED_ASSETS", nil),
                 "Run with DECIDIM_TEST_COMPILED_ASSETS=1 after shakapacker:compile"
    assert self.class.compiled_push_module?,
           "public/packs-test carries no #{PUSH_MODULE_MARKER}, so it predates this app's push module and " \
           "these tests would drive Decidim core's instead. Run RAILS_ENV=test bin/rails shakapacker:compile, " \
           "and check that public/packs-test is not a symlink into the deployed checkout."
  end
end
