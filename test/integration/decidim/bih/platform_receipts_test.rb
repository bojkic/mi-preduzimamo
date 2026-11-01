# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class PlatformReceiptsTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = create(:user, :confirmed, organization: @organization)
        @receipt = PlatformDelivery.for!(user: @user, identity: "incident:revision", expires_at: 1.hour.from_now)
      end

      test "signed display capability is tenant scoped idempotent and expiring" do
        token = @receipt.receipt_token
        post "/biceriseno/platform-receipt", params: { token: }, as: :json
        assert_response :no_content
        assert_equal "browser_display", @receipt.reload.acknowledgment_kind
        acknowledged_at = @receipt.acknowledged_at
        post "/biceriseno/platform-receipt", params: { token: }, as: :json
        assert_equal acknowledged_at, @receipt.reload.acknowledged_at
        post "/biceriseno/platform-receipt", params: { token: "invalid" }, as: :json
        assert_response :not_found
        post "/biceriseno/platform-receipt", params: { token: "x" * 2049 }, as: :json
        assert_response :not_found
        post "/biceriseno/platform-receipt", params: { token: { unexpected: "shape" } }, as: :json
        assert_response :not_found
        host! create_organization.host
        post "/biceriseno/platform-receipt", params: { token: }, as: :json
        assert_response :not_found
        host! @organization.host
        travel_to 2.hours.from_now do
          post "/biceriseno/platform-receipt", params: { token: }, as: :json
          assert_response :not_found
        end
      end

      test "receipt deletion cascades with hard account and organization deletion" do
        foreign_keys = ActiveRecord::Base.connection.foreign_keys(PlatformDelivery.table_name)
        %w(decidim_users decidim_organizations).each do |table|
          assert_equal :cascade, foreign_keys.find { |key| key.to_table == table }.on_delete
        end
        @user.delete
        assert_not PlatformDelivery.exists?(@receipt.id)
      end

      test "explicit inbox read acknowledges only its delivery without treating a page visit as read" do
        area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-receipt", name: { sr: "Tabla" })
        CitizenProfile.for_user(@user, organization: @organization).assign_komsiluk!(area, source: "dropdown")
        notice = KomsilukPost.create!(organization: @organization, komsiluk: area, origin: "staff", publication_key: SecureRandom.uuid,
                                      category: "safety", title: "Obavještenje", body: "Javni sadržaj", expires_at: @receipt.expires_at)
        Komsiluk::NoticePublishing.publish!(post: notice, identity: @receipt.identity, expires_at: @receipt.expires_at)
        untouched = PlatformDelivery.for!(user: @user, identity: "another-notice", expires_at: 1.hour.from_now)
        KomsilukNoticeDeliveryJob.perform_now(@receipt.id)
        notification = @user.notifications.last
        assert notification
        sign_in @user
        get "/notifications"
        assert_response :success
        assert_nil @receipt.reload.acknowledged_at
        assert_nil @receipt.inbox_read_at
        assert_nil @receipt.browser_displayed_at
        delete "/notifications/#{notification.id}"
        assert_response :success
        assert_equal "inbox_read", @receipt.reload.acknowledgment_kind
        assert @receipt.inbox_read_at
        assert @receipt.acknowledged_at
        assert_nil @receipt.browser_displayed_at
        assert_nil untouched.reload.acknowledged_at
        assert_nil untouched.inbox_read_at
      end
    end
  end
end
