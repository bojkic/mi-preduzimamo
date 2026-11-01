# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      class KomsilukPostPhotosTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @member = FactoryBot.create(:user, :confirmed, organization: @organization)
          @area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "photo-review", name: { sr: "Pregled fotografije" })
          @post = KomsilukPost.create!(organization: @organization, komsiluk: @area, author: @member, origin: "citizen",
                                       category: "activity", title: "Aktivnost sa fotografijom", body: "Privatni sadržaj za članove", status: "hidden",
                                       expires_at: 2.days.from_now, details: { "activity" => { "starts_at" => 1.day.from_now.iso8601,
                                                                                               "place_label" => "Park", "action_url" => "https://example.org/activity" },
                                                                               "help_enabled" => true })
          Rails.root.join("test/fixtures/files/chat_photo.jpg").open do |file|
            @post.photo.attach(io: file, filename: "photo.jpg", content_type: "image/jpeg")
          end
        end

        test "global moderator sees hidden photo and structured details without public storage links" do
          sign_in @admin
          get "/admin/bih/komsiluk-posts/#{@post.id}"
          assert_response :success
          assert_select "img[src='/admin/bih/komsiluk-posts/#{@post.id}/photo']", count: 1
          assert_select "a[href='https://example.org/activity']", count: 1
          assert_includes response.body, "Park"
          assert_select ".mi-board-admin-detail img[src*=active_storage]", count: 0
          assert_select ".mi-board-admin-detail a[href*=active_storage]", count: 0
          get "/admin/bih/komsiluk-posts/#{@post.id}/photo"
          assert_response :success
          assert_equal "image/jpeg", response.media_type
          assert_includes response.headers["Cache-Control"], "no-store"
          assert_equal "nosniff", response.headers["X-Content-Type-Options"]
        end

        test "scoped moderator photo access expires with its area permission" do
          moderator = FactoryBot.create(:user, :confirmed, organization: @organization)
          grant = OperatorRole.create!(organization: @organization, user: moderator, created_by: @admin, role: "komsiluk_moderator",
                                       area_scope: "selected", komsiluk_ids: [@area.id], expires_at: 2.days.from_now)
          sign_in moderator
          get "/admin/bih/komsiluk-posts/#{@post.id}/photo"
          assert_response :success
          other = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "photo-other", name: { sr: "Drugi" })
          grant.update!(komsiluk_ids: [other.id])
          get "/admin/bih/komsiluk-posts/#{@post.id}/photo"
          assert_response :not_found
          assert_not_equal "image/jpeg", response.media_type
        end

        test "ordinary member cannot use the moderator photo endpoint" do
          sign_in @member
          get "/admin/bih/komsiluk-posts/#{@post.id}/photo"
          assert_response :redirect
          assert_not_equal "image/jpeg", response.media_type
        end
      end
    end
  end
end
