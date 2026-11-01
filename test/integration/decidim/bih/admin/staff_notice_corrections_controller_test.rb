# frozen_string_literal: true

require "test_helper"
require "capybara"
require_relative "../../../../support/komsiluk_notice_source_fixtures"

module Decidim
  module Bih
    module Admin
      class StaffNoticeCorrectionsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include KomsilukNoticeSourceFixtures

        setup do
          setup_notice_sources
          host! @organization.host
          @publisher = create(:user, :confirmed, organization: @organization)
          OperatorRole.create!(organization: @organization, user: @publisher, role: "broadcast_operator",
                               created_by: @admin, expires_at: 1.month.from_now)
          @member = create(:user, :confirmed, organization: @organization)
          CitizenProfile.for_user(@member, organization: @organization).assign_komsiluk!(@area, source: "map")
          composer = Komsiluk::NoticeComposer.new(organization: @organization, actor: @publisher)
          preview = composer.preview_publication(title: "Original staff notice", body: "Original public wording", category: "general",
                                                 expires_at: 2.days.from_now.iso8601, area_ids: [@area.id])
          composer.confirm!(preview[:intent].confirmation_token)
          @notice = KomsilukPost.find_by!(organization: @organization, publication_key: preview[:intent].publication_key)
          sign_in @publisher
        end

        test "publisher can reach published detail without gaining citizen moderation or city phone authority" do
          get "/admin/bih/komsiluk-posts/#{@notice.id}"
          assert_response :success
          assert_select "#notice-delivery"
          assert_select "#board-review-decision", count: 0
          assert_select "#board-review-history", count: 0
          assert_select "a[href='/admin/bih/board-notices/#{@notice.id}/edit']"
          citizen = KomsilukPost.create!(organization: @organization, author: @member, komsiluk: @area, origin: "citizen",
                                         category: "general", title: "PRIVATE_CITIZEN_REVIEW_TITLE", body: "Member-only citizen evidence")
          get "/admin/bih/komsiluk-posts/#{citizen.id}"
          assert_redirected_to "/admin/bih/board-notices/new"
          assert_not_includes response.body, citizen.title
          @notice.update!(origin: "city_service")
          get "/admin/bih/komsiluk-posts/#{@notice.id}"
          assert_response :success
          assert_select "a[href='/admin/bih/board-notices/#{@notice.id}/phone']", count: 0
          assert_select "a[href='/admin/bih/board-notices/#{@notice.id}/edit']", count: 0
        end

        test "correction preview and repeated confirmation preserve placement identity without a new notification" do
          get "/admin/bih/board-notices/#{@notice.id}/edit"
          assert_response :success
          assert_select "input[name='notice[notify]'][value='0'][checked]"
          assert_select "input[name='notice[notify]'][value='1'][checked]", count: 0
          receipt_ids = PlatformDelivery.where(komsiluk_post_id: @notice.id).pluck(:id)
          post_count = KomsilukPost.count
          post "/admin/bih/board-notices/#{@notice.id}/correction-preview", params: { notice: correction }
          assert_response :success
          assert_select "#board-correction-preview"
          assert_equal "Original public wording", @notice.reload.body
          token = css_select("input[name=confirmation_token]").sole["value"]
          2.times { post "/admin/bih/board-notices/confirm", params: { confirmation_token: token, notice: { body: "tampered" } } }
          assert_redirected_to "/admin/bih/komsiluk-posts/#{@notice.id}"
          assert_equal post_count, KomsilukPost.count
          assert_equal correction[:body], @notice.reload.body
          assert_equal 2, @notice.content_revision
          assert_equal receipt_ids, PlatformDelivery.where(komsiluk_post_id: @notice.id).pluck(:id)
          assert_empty KomsilukPhoneDelivery.all
        end

        test "stale correction preserves the reviewed draft and does not offer another confirm button" do
          post "/admin/bih/board-notices/#{@notice.id}/correction-preview", params: { notice: correction }
          token = css_select("input[name=confirmation_token]").sole["value"]
          @notice.update!(body: "Someone else's newer wording")
          post "/admin/bih/board-notices/confirm", params: { confirmation_token: token }
          assert_response :unprocessable_entity
          assert_select "#board-correction-preview"
          assert_includes response.body, correction[:body]
          assert_select "input[name=confirmation_token]", count: 0
          assert_equal "Someone else's newer wording", @notice.reload.body
        end

        test "malformed correction or a citizen post cannot be used as a staff edit target" do
          post "/admin/bih/board-notices/#{@notice.id}/correction-preview", params: { notice: correction.merge(body: "") }
          assert_response :unprocessable_entity
          assert_select "#board-notice-correction"
          post "/admin/bih/board-notices/#{@notice.id}/correction-preview", params: { notice: correction.merge(expires_at: "invalid-date") }
          assert_response :unprocessable_entity
          assert_select "#board-notice-correction"
          assert_select "textarea[name='notice[body]']", text: correction[:body]
          @notice.update!(origin: "citizen", author: @member)
          post "/admin/bih/board-notices/#{@notice.id}/correction-preview", params: { notice: correction }
          assert_redirected_to "/admin/bih/board-notices/new"
          assert_equal "Original public wording", @notice.reload.body
        end

        test "moderation role alone cannot prepare or confirm a staff correction" do
          moderator = create(:user, :confirmed, organization: @organization)
          OperatorRole.create!(organization: @organization, user: moderator, role: "komsiluk_moderator",
                               created_by: @admin, expires_at: 1.month.from_now, area_scope: "selected", komsiluk_ids: [@area.id])
          sign_in moderator
          get "/admin/bih/komsiluk-posts/#{@notice.id}"
          assert_response :success
          assert_select "a[href='/admin/bih/board-notices/#{@notice.id}/edit']", count: 0
          assert_no_difference "KomsilukSendIntent.count" do
            post "/admin/bih/board-notices/#{@notice.id}/correction-preview", params: { notice: correction }
          end
          assert_redirected_to "http://#{@organization.host}/admin/"
          assert_equal "Original public wording", @notice.reload.body
        end

        test "source changed panel and correction prefill remain limited to public report fields" do
          sign_in @admin
          report = reviewed_report
          notice = linked_post("report", report)
          report.update!(status: "u_obradi")
          get "/admin/bih/komsiluk-posts/#{notice.id}"
          assert_response :success
          assert_select "#board-source-review"
          assert_select "a[href='/biceriseno/prijave/#{report.reference}']"
          get "/admin/bih/board-notices/#{notice.id}/edit"
          assert_response :success
          assert_includes response.body, report.reference
          [report.description, report.ai_summary, report.internal_note, report.reporter_email, report.reporter_phone].each do |private_value|
            assert_not_includes response.body, private_value
          end
        end

        test "correction POST still requires CSRF protection" do
          original = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          post "/admin/bih/board-notices/#{@notice.id}/correction-preview", params: { notice: correction }
          assert_response :unprocessable_entity
          assert_equal "Original public wording", @notice.reload.body
        ensure
          ActionController::Base.allow_forgery_protection = original
        end

        private

        def correction
          { title: "Corrected staff notice", body: "Corrected public wording", category: "general",
            expires_at: @notice.expires_at.iso8601, notify: "0" }
        end
      end
    end
  end
end
