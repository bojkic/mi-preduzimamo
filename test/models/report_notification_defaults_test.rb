# frozen_string_literal: true

require "test_helper"

class ReportNotificationDefaultsTest < ActiveSupport::TestCase
  setup do
    @organization = create_organization
    @organization.update!(host: "mi.fondacijabijeljina.com")
  end

  test "new Bijeljina accounts inherit all four topics without matrix writes" do
    user = FactoryBot.create(:user, organization: @organization)
    Decidim::Bih::TopicPreferences::TOPICS.each do |topic|
      assert Decidim::Bih::TopicPreferences.enabled?(user, topic:)
    end
    assert_empty user.notification_settings
    assert_equal 0, Decidim::Bih::Messaging::Preference.where(user:).count
    assert_equal 0, Decidim::Bih::Messaging::PreferenceChange.where(user:).count
  end

  test "explicit registration refusal survives ordinary saves and legacy default calls" do
    user = FactoryBot.create(:user, organization: @organization)
    Decidim::Bih::TopicPreferences.set_all!(user, enabled: false)
    assert_no_difference "Decidim::Bih::Messaging::PreferenceChange.count" do
      user.update!(name: "Changed")
      user.apply_report_notification_defaults
      user.apply_and_mirror_report_notification_defaults!(overwrite: true)
    end
    assert Decidim::Bih::Messaging::Preference.where(user:).all?(&:blocked?)
    assert_empty user.reload.notification_settings
  end

  test "compatibility default application fills an absent report choice with organization provenance" do
    user = FactoryBot.create(:user, organization: @organization)
    user.apply_and_mirror_report_notification_defaults!(overwrite: true)
    preference = Decidim::Bih::Messaging::Preference.find_by!(user:, topic: "report_updates")
    assert_predicate preference, :allowed?
    assert_not preference.personal_choice?
    assert_equal "organization_default", preference.source
    assert_no_difference "Decidim::Bih::Messaging::PreferenceChange.count" do
      user.apply_and_mirror_report_notification_defaults!(overwrite: true)
    end
    assert_empty user.reload.notification_settings
  end

  test "default application never clears provider suppression or device setup" do
    user = FactoryBot.create(:user, organization: @organization,
                                    notification_settings: { "subscriptions" => { "device" => { "auth" => "fixture" } } })
    suppression = Decidim::Bih::Messaging::Suppression.create!(
      organization: @organization, user:, provider: "infobip", channel: "whatsapp",
      destination_kind: "phone", destination_digest: "a" * 64, reason: "provider_opt_out",
      source: "provider_webhook", suppressed_at: Time.current
    )
    original = user.notification_settings.deep_dup
    user.apply_and_mirror_report_notification_defaults!(overwrite: true)
    assert_equal original, user.reload.notification_settings
    assert_predicate suppression.reload, :active?
  end

  test "a failed explicit default write rolls back its preference and history together" do
    user = FactoryBot.create(:user, organization: @organization)
    exploded = ->(*) { raise ActiveRecord::StatementInvalid, "history unavailable" }
    assert_no_difference ["Decidim::Bih::Messaging::Preference.count", "Decidim::Bih::Messaging::PreferenceChange.count"] do
      assert_raises(ActiveRecord::StatementInvalid) do
        Decidim::Bih::Messaging::PreferenceChange.stub(:create!, exploded) do
          user.apply_and_mirror_report_notification_defaults!(overwrite: true)
        end
      end
    end
  end

  test "account creation no longer depends on the retired default mirror" do
    exploded = ->(*) { raise ActiveRecord::StatementInvalid, "retired mirror must not run" }
    assert_difference "Decidim::User.count", 1 do
      Decidim::Bih::Messaging::PreferenceChange.stub(:create!, exploded) do
        FactoryBot.create(:user, organization: @organization)
      end
    end
  end

  test "Bijeljina compatibility helper does not write defaults for another organization" do
    @organization.update!(host: "other.example.org")
    user = FactoryBot.create(:user, organization: @organization)
    user.apply_and_mirror_report_notification_defaults!(overwrite: true)
    assert_equal 0, Decidim::Bih::Messaging::Preference.where(user:).count
    assert_empty user.notification_settings
  end
end
