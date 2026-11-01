# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class KomsilukNotificationOptoutTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper
      PAGE = "/biceriseno/moj-nalog/poruke"

      setup do
        @organization = create_organization(badges_enabled: false)
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        @komsiluk = Decidim::Bih::LocalArea.create!(
          organization: @organization, kind: "komsiluk", slug: "k-optout", name: { "sr" => "Komšiluk" }
        )
      end

      test "local notifications have one topic choice and legacy navigation reaches it" do
        sign_in @user
        get "/notifications_settings?legacy=1"
        assert_redirected_to PAGE
        follow_redirect!
        assert_response :success
        assert_select "#communication_settings_neighborhood_info[checked]", count: 1
        assert_select "#communication_settings_urgent_bell, #communication_settings_city_service_alerts_viber", count: 0
        assert_select "[data-setting-section=inapp] input", count: 0
        assert_includes response.body, I18n.t("decidim.bih.communication_settings.platform_always_available", locale: :sr)
      end

      test "the local topic choice persists without channel keys and does not change other topics" do
        sign_in @user
        before = @user.notification_settings.deep_dup
        patch PAGE, params: { communication_settings: { neighborhood_info: "0" } }
        assert_redirected_to PAGE
        assert_not TopicPreferences.enabled?(@user.reload, topic: :neighborhood_info)
        assert TopicPreferences.enabled?(@user, topic: :report_updates)
        assert TopicPreferences.enabled?(@user, topic: :community_news)
        assert_equal before, @user.notification_settings
        patch PAGE, params: { communication_settings: { neighborhood_info: "1" } }
        assert TopicPreferences.enabled?(@user.reload, topic: :neighborhood_info)
        assert_equal before, @user.notification_settings
      end

      test "old notification forms cannot restore platform or channel opt-outs" do
        sign_in @user
        before = @user.notification_settings.deep_dup
        put "/notifications_settings", params: {
          notifications_from_own_activity: "0", notifications_from_followed: "0",
          notification_settings: { mi_komsiluk_urgent_bell: "0", mi_city_service_alerts_viber: "0" }
        }
        assert_response :see_other
        assert_equal before, @user.reload.notification_settings
        assert_equal "all", @user.notification_types
        assert TopicPreferences.enabled?(@user, topic: :neighborhood_info)
      end

      test "an opted-out local topic still receives the urgent notification in the platform inbox" do
        assign_neighbor!
        TopicPreferences.set!(@user, topic: :neighborhood_info, enabled: false)
        @user.update!(notification_types: "none")
        assert_difference -> { local_notifications(@user).count }, 1 do
          perform_enqueued_jobs { create_urgent_post! }
        end
        assert_not TopicPreferences.enabled?(@user.reload, topic: :neighborhood_info)
      end

      test "historical local bell and board opt-outs no longer suppress inbox fan-out" do
        assign_neighbor!
        @user.update!(notification_settings: { "komsiluk_board" => false, "mi_komsiluk_urgent_bell" => false })
        assert_difference -> { local_notifications(@user).count }, 1 do
          perform_enqueued_jobs { create_urgent_post! }
        end
      end

      test "always available inbox still excludes the author and people outside the neighborhood" do
        assign_neighbor!
        author = FactoryBot.create(:user, :confirmed, organization: @organization)
        outsider = FactoryBot.create(:user, :confirmed, organization: @organization)
        CitizenProfile.for_user(author, organization: @organization).assign_komsiluk!(@komsiluk, source: "dropdown")
        perform_enqueued_jobs { create_urgent_post!(author:) }
        assert_equal 1, local_notifications(@user).count
        assert_equal 0, local_notifications(author).count
        assert_equal 0, local_notifications(outsider).count
      end

      private

      def assign_neighbor!
        CitizenProfile.for_user(@user, organization: @organization).assign_komsiluk!(@komsiluk, source: "dropdown")
      end

      def create_urgent_post!(author: FactoryBot.create(:user, :confirmed, organization: @organization))
        Komsiluk::PostCreator.new(organization: @organization, author:, komsiluk: @komsiluk)
                             .call(category: "safety", title: "Provala", body: "Provala u zgradi kod ulaza")
      end

      def local_notifications(user)
        Decidim::Notification.where(user:, event_name: "decidim.events.bih.komsiluk_post")
      end
    end
  end
end
