# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class WebPushDeliveryJobTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @subscription = { "endpoint" => "https://fcm.googleapis.com/fcm/send/test", "auth" => "device-secret", "p256dh" => "public-key" }
        @user = create(:user, :confirmed, organization: @organization,
                                          notification_settings: { "subscriptions" => { "device-secret" => @subscription }, "mi_komsiluk_urgent_bell" => false })
        @fingerprint = WebPush.fingerprint(@subscription)
        @old_flag = ENV.fetch("DECIDIM_BIH_WEB_PUSH_ENABLED", nil)
        @old_subject = ENV.fetch("VAPID_SUBJECT", nil)
        ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = "true"
        ENV["VAPID_SUBJECT"] = "mailto:notifications@example.org"
        @old_public = Decidim.vapid_public_key
        @old_private = Decidim.vapid_private_key
        Decidim.vapid_public_key = "public-test-key"
        Decidim.vapid_private_key = "private-test-key"
      end

      teardown do
        ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = @old_flag
        ENV["VAPID_SUBJECT"] = @old_subject
        Decidim.vapid_public_key = @old_public
        Decidim.vapid_private_key = @old_private
      end

      test "correlated city push carries receipt capability but provider acceptance is not display" do
        receipt = PlatformDelivery.for!(user: @user, identity: "incident-1:revision-1", expires_at: 1.hour.from_now)
        sent = []
        ::WebPush.stub(:payload_send, ->(**params) { sent << params }) do
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint, "notifications", nil, nil, nil, receipt.id)
        end
        assert_equal 1, sent.size
        data = JSON.parse(sent.first.fetch(:message)).fetch("data")
        assert_equal "/biceriseno/platform-receipt", data["receipt_url"]
        assert_equal receipt, PlatformDelivery.find_signed(data["receipt_token"], purpose: :platform_display_receipt)
        assert_nil receipt.reload.acknowledged_at
      end

      test "delivery has a real subject generic content and an inbox URL" do
        sent = []
        ::WebPush.stub(:payload_send, ->(**params) { sent << params }) do
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint)
        end
        assert_equal 1, sent.size
        assert_equal ENV.fetch("VAPID_SUBJECT"), sent.first.dig(:vapid, :subject)
        payload = JSON.parse(sent.first.fetch(:message))
        assert_equal "https://#{@organization.host}/notifications", payload.dig("data", "url")
        assert_equal I18n.t("decidim.bih.web_push.body", locale: @user.locale), payload["body"]
        assert_equal 3600, sent.first[:ttl]
      end

      test "expired subscription is removed without deleting other preferences or devices" do
        settings = @user.notification_settings.deep_dup
        settings["subscriptions"]["second"] = @subscription.merge("auth" => "second")
        @user.update!(notification_settings: settings)
        response = Net::HTTPGone.new("1.1", "410", "Gone")
        response.instance_variable_set(:@read, true)
        error = ::WebPush::ExpiredSubscription.new(response, "fcm.googleapis.com")
        ::WebPush.stub(:payload_send, ->(**) { raise error }) do
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint)
        end
        assert_equal ["second"], @user.reload.notifications_subscriptions.keys
        assert_equal false, @user.notification_settings["mi_komsiluk_urgent_bell"]
      end

      test "transient failure retries only this device without recreating bell notifications" do
        ::WebPush.stub(:payload_send, ->(**) { raise Net::ReadTimeout }) do
          assert_no_difference "Decidim::Notification.count" do
            assert_enqueued_with(job: WebPushDeliveryJob, args: [@user.id, @fingerprint]) do
              WebPushDeliveryJob.perform_now(@user.id, @fingerprint)
            end
          end
        end
      end

      test "revoked subscriptions and disabled deployment are rechecked before sending" do
        calls = 0
        ::WebPush.stub(:payload_send, ->(**) { calls += 1 }) do
          ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = "false"
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint)
          ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = "true"
          @user.update!(notification_settings: {})
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint)
        end
        assert_equal 0, calls
      end

      test "arbitrary endpoints and blocked users cannot receive pushes" do
        calls = 0
        @subscription["endpoint"] = "https://127.0.0.1/private"
        @user.update!(notification_settings: { "subscriptions" => { "device-secret" => @subscription } })
        ::WebPush.stub(:payload_send, ->(**) { calls += 1 }) do
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint)
          @user.update!(blocked: true)
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint)
        end
        assert_equal 0, calls
      end

      # The fourth argument is Phase 3's correlation: the id of the ONE intent
      # this fan-out belongs to, so every device records its own outcome against
      # one logical message. It is an integer row id and nothing else — the
      # queue still carries no body, no endpoint URL and no subscription secret,
      # which is what this test has always been for.
      test "core dispatch queues a fingerprint and no private body or endpoint" do
        notification = Struct.new(:user).new(@user)
        assert_enqueued_with(job: WebPushDeliveryJob) do
          Decidim::SendPushNotification.new.perform(notification)
        end
        enqueued = enqueued_jobs.last.fetch(:args)

        assert_equal [@user.id, @fingerprint, "notifications"], enqueued.first(3)
        assert_equal 6, enqueued.size
        assert_kind_of Integer, enqueued[3]
        assert_equal Decidim::Bih::Messaging::Intent.last.id, enqueued[3]
        assert_equal "community_news", enqueued[4]
        assert_nil enqueued[5]
        serialized = JSON.generate(enqueued)
        assert_not_includes serialized, @subscription.fetch("endpoint")
        assert_not_includes serialized, @subscription.fetch("auth")
        assert_not_includes serialized, @subscription.fetch("p256dh")
      end

      test "queued push rechecks its topic while another enabled topic still delivers" do
        TopicPreferences.set!(@user, topic: :report_updates, enabled: false)
        sent = []
        ::WebPush.stub(:payload_send, ->(**params) { sent << params }) do
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint, "notifications", nil, "report_updates")
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint, "notifications", nil, "community_news")
        end
        assert_equal 1, sent.size
      end

      test "old unclassified queued push does not bypass a disabled topic" do
        TopicPreferences.set!(@user, topic: :neighborhood_info, enabled: false)
        calls = 0
        ::WebPush.stub(:payload_send, ->(**) { calls += 1 }) do
          WebPushDeliveryJob.perform_now(@user.id, @fingerprint)
        end
        assert_equal 0, calls
      end

      test "availability checks supported subscription details before selecting push" do
        assert WebPush.available_for?(@user, topic: :report_updates)
        @user.update!(notification_settings: { "subscriptions" => { "invalid" => @subscription.merge("endpoint" => "https://127.0.0.1/push") } })
        assert_not WebPush.available_for?(@user, topic: :report_updates)
      end

      test "a repeated event queues the same intent and sends each device only once" do
        2.times { WebPush.enqueue(@user, topic: :report_updates, deduplication_key: "report:one:status") }
        jobs = enqueued_jobs.select { |job| job[:job] == WebPushDeliveryJob }
        assert_equal 2, jobs.size
        assert_equal jobs.first[:args][3], jobs.last[:args][3]
        calls = 0
        ::WebPush.stub(:payload_send, ->(**) { calls += 1 }) do
          jobs.each { |job| WebPushDeliveryJob.perform_now(*ActiveJob::Arguments.deserialize(job[:args])) }
        end
        assert_equal 1, calls
      end

      test "a bell assigned to another proactive transport does not also enqueue push" do
        notification = Struct.new(:user, :extra).new(@user, { "proactive_channel" => "external" })
        assert_no_enqueued_jobs { Decidim::SendPushNotification.new.perform(notification) }
      end

      test "missing sender contact disables both delivery and the setting" do
        ENV.delete("VAPID_SUBJECT")
        assert_not WebPush.enabled?
        assert_not Decidim::NotificationsSettingsForm.new.meet_push_notifications_requirements?
        assert_no_enqueued_jobs { WebPush.enqueue(@user) }
      end
    end
  end
end
