# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class WebPushTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        host! @organization.host
        @user = create(:user, :confirmed, organization: @organization)
        @subscription = { "endpoint" => "https://fcm.googleapis.com/fcm/send/test", "auth" => "device-secret", "p256dh" => "public-key" }
        @user.update!(notification_settings: { "subscriptions" => { "device-secret" => @subscription } })
        @fingerprint = WebPush.fingerprint(@subscription)
        @public_key = Decidim.vapid_public_key
        @private_key = Decidim.vapid_private_key
        @flag = ENV.fetch("DECIDIM_BIH_WEB_PUSH_ENABLED", nil)
        @subject = ENV.fetch("VAPID_SUBJECT", nil)
        key = ::WebPush.generate_key
        Decidim.vapid_public_key = key.public_key
        Decidim.vapid_private_key = key.private_key
        ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = "true"
        ENV["VAPID_SUBJECT"] = "mailto:notifications@example.org"
      end

      teardown do
        Decidim.vapid_public_key = @public_key
        Decidim.vapid_private_key = @private_key
        ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = @flag
        ENV["VAPID_SUBJECT"] = @subject
      end

      # Phase 4 made /biceriseno/moj-nalog/poruke the ONE communication page and
      # sends GET navigation there, so the push controls these tests are about
      # now render on the canonical page. The citizen's route to them is the
      # redirect, so these tests keep walking it rather than jumping the queue.
      def open_notification_settings
        get "/notifications_settings"
        assert_equal 302, response.status,
                     "navigation must redirect temporarily; a 301 is cached by the browser and would outlive a rollback"
        follow_redirect!
      end

      test "enabled settings render device guidance test and private unsubscribe routes" do
        sign_in @user
        open_notification_settings
        assert_response :success
        assert_select "[data-push-notifications-container][data-install][data-blocked]"
        assert_select "[data-test-url='/biceriseno/push-notification-test']"
        assert_select "[data-unsubscribe-url='/biceriseno/push-subscription']"
        assert_select "button[data-push-test][type=button]"
      end

      test "unconfigured deployment hides push controls" do
        ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = "false"
        sign_in @user
        open_notification_settings
        assert_response :success
        assert_select "[data-push-notifications-container]", count: 0
      end

      test "current and new users are offered push without changing account preferences" do
        [@user, create(:user, :confirmed, organization: @organization)].each do |user|
          settings = user.notification_settings.deep_dup
          sign_in user
          get "/notifications"
          assert_response :success
          assert_select "[data-push-offer][hidden]"
          assert_select "button[data-push-enable][type=button]"
          assert_select "button[data-push-dismiss][type=button]"
          assert_equal settings, user.reload.notification_settings
          assert_not_includes response.body, "device-secret"
          sign_out user
        end
      end

      test "signed out and unconfigured pages never show a push invitation" do
        get "/"
        assert_response :success
        assert_select "[data-push-offer]", count: 0
        sign_in @user
        ENV["DECIDIM_BIH_WEB_PUSH_ENABLED"] = "false"
        get "/notifications"
        assert_response :success
        assert_select "[data-push-offer]", count: 0
      end

      test "notification settings retain one set of controls and an account dismissal key" do
        sign_in @user
        open_notification_settings
        assert_response :success
        assert_select "[data-push-offer]", count: 0
        assert_select "[data-push-notifications-toggle]", count: 1
        assert_select "[data-push-offer-key]", count: 1
      end

      test "a browser subscription is saved for the signed in user" do
        sign_in @user
        post "/notifications_subscriptions", params: {
          endpoint: @subscription.fetch("endpoint"),
          keys: { auth: "second-device", p256dh: @subscription.fetch("p256dh") }
        }, as: :json
        assert_response :ok
        subscriptions = @user.reload.notifications_subscriptions
        assert_equal 2, subscriptions.size
        assert_equal @subscription.fetch("endpoint"), subscriptions.fetch("second-device").fetch("endpoint")
      end

      test "test push targets only the signed in users registered device" do
        sign_in @user
        redis = Minitest::Mock.new
        redis.expect(:set, "OK", ["bih:web_push_test:#{@user.id}", "1"], nx: true, ex: 60)
        Sidekiq.stub(:redis, ->(&block) { block.call(redis) }) do
          assert_enqueued_with(job: WebPushDeliveryJob, args: [@user.id, @fingerprint]) do
            post "/biceriseno/push-notification-test", params: { fingerprint: @fingerprint }, as: :json
          end
        end
        redis.verify
        assert_response :accepted
      end

      test "unknown device cannot enqueue and cooldown prevents repeated sends" do
        sign_in @user
        assert_no_enqueued_jobs only: WebPushDeliveryJob do
          post "/biceriseno/push-notification-test", params: { fingerprint: "other-device" }, as: :json
          assert_response :unprocessable_entity
          redis = Minitest::Mock.new
          redis.expect(:set, nil, ["bih:web_push_test:#{@user.id}", "1"], nx: true, ex: 60)
          Sidekiq.stub(:redis, ->(&block) { block.call(redis) }) do
            post "/biceriseno/push-notification-test", params: { fingerprint: @fingerprint }, as: :json
          end
          assert_response :too_many_requests
          redis.verify
        end
      end

      test "unsubscribe is idempotent and leaves another user subscription intact" do
        other = create(:user, :confirmed, organization: @organization, notification_settings: @user.notification_settings)
        sign_in @user
        2.times do
          delete "/biceriseno/push-subscription", params: { fingerprint: @fingerprint }, as: :json
          assert_response :no_content
        end
        assert_empty @user.reload.notifications_subscriptions
        assert_equal 1, other.reload.notifications_subscriptions.size
      end

      test "anonymous browser cannot subscribe or request a test" do
        assert_no_enqueued_jobs only: WebPushDeliveryJob do
          post "/notifications_subscriptions", params: {}, as: :json
          assert_response :unauthorized
          post "/biceriseno/push-notification-test", params: { fingerprint: @fingerprint }, as: :json
          assert_response :unauthorized
        end
      end

      test "subscription secrets are filtered from request and database logs" do
        filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
        result = filter.filter("endpoint" => @subscription["endpoint"], "keys" => { "auth" => "secret", "p256dh" => "key" })
        assert_equal "[FILTERED]", result["endpoint"]
        assert_equal "[FILTERED]", result.dig("keys", "auth")
        database_filter = ActiveSupport::ParameterFilter.new(ActiveRecord::Base.filter_attributes)
        assert_equal "[FILTERED]", database_filter.filter("notification_settings" => @user.notification_settings)["notification_settings"]
      end

      test "another organizations session cannot register or test subscriptions" do
        outsider = create(:user, :confirmed, organization: create_organization)
        sign_in outsider
        assert_no_enqueued_jobs only: WebPushDeliveryJob do
          post "/notifications_subscriptions", params: {}, as: :json
          assert_response :forbidden
          post "/biceriseno/push-notification-test", params: { fingerprint: @fingerprint }, as: :json
          assert_response :forbidden
          delete "/biceriseno/push-subscription", params: { fingerprint: @fingerprint }, as: :json
          assert_response :forbidden
        end
        assert_equal 1, @user.reload.notifications_subscriptions.size
      end

      test "device mutations require CSRF tokens" do
        sign_in @user
        previous = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        assert_no_enqueued_jobs only: WebPushDeliveryJob do
          post "/biceriseno/push-notification-test", params: { fingerprint: @fingerprint }, as: :json
          assert_response :unprocessable_entity
          delete "/biceriseno/push-subscription", params: { fingerprint: @fingerprint }, as: :json
          assert_response :unprocessable_entity
        end
        assert_equal 1, @user.reload.notifications_subscriptions.size
      ensure
        ActionController::Base.allow_forgery_protection = previous
      end
    end
  end
end
