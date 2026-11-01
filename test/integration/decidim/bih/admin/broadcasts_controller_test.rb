# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      class BroadcastsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = create(:user, :admin, :confirmed, organization: @organization)
          @citizen = create(:user, :confirmed, organization: @organization)
        end

        test "bookmarked broadcast composer leads to durable board publishing" do
          sign_in @admin
          get "/admin/bih/broadcasts/new"
          assert_redirected_to "/admin/bih/board-notices/new"
        end

        test "stale count-only confirmations cannot create records or send messages" do
          sign_in @admin
          assert_no_difference ["Decidim::Bih::Broadcast.count", "Decidim::Bih::KomsilukPost.count", "Decidim::Bih::KomsilukPhoneDelivery.count"] do
            post "/admin/bih/broadcasts", params: { confirm_preview: "1", message: "old copy", local_area_id: 1, channels: { automatic: "1" } }
          end
          assert_redirected_to "/admin/bih/board-notices/new"
        end

        test "ordinary members cannot use the old operator entry point" do
          sign_in @citizen
          post "/admin/bih/broadcasts", params: { message: "not authorized" }
          assert_response :redirect
          assert_empty Decidim::Bih::Broadcast.all
        end
      end
    end
  end
end
