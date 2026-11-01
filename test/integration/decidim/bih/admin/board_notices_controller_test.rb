# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      class BoardNoticesControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = create(:user, :admin, :confirmed, organization: @organization)
          @member = create(:user, :confirmed, organization: @organization)
          @board = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-compose", name: { sr: "Test tabla" })
          CitizenProfile.for_user(@member, organization: @organization).assign_komsiluk!(@board, source: "map")
          sign_in @admin
        end

        test "new publication keeps optional phone channels explicit and unselected" do
          get "/admin/bih/board-notices/new"
          assert_response :success
          assert_select "select[name='notice[category]'] option[selected][value=general]", 1
          assert_select "input[name='notice[channels][]']", 3
          assert_select "input[name='notice[channels][]'][checked]", 0
          assert_select "input[name='channels[automatic]']", 0
          assert_select "[data-board-area-picker] input[type=search][data-area-search]", 1
          assert_select "input[type=checkbox][name='notice[area_ids][]'][value='#{@board.id}']", 1
        end

        test "preview and one confirmation make durable board records without exposing recipients" do
          assert_no_difference "KomsilukPost.count" do
            post "/admin/bih/board-notices/preview", params: { notice: attributes }
          end
          assert_response :success
          assert_select "#board-notice-preview", 1
          assert_includes response.body, "Test tabla"
          assert_not_includes response.body, @member.email
          token = css_select("input[name=confirmation_token]").first["value"]
          assert_difference "KomsilukPost.count", 1 do
            2.times { post "/admin/bih/board-notices/confirm", params: { confirmation_token: token, notice: { body: "tampered" } } }
          end
          created = KomsilukPost.find_by!(organization: @organization)
          assert_equal attributes[:body], created.body
          assert_equal "staff", created.origin
          assert_redirected_to "/admin/bih/komsiluk-posts/#{created.id}"
          assert_empty KomsilukPhoneDelivery.all
        end

        test "invalid publication preserves fields and does not publish" do
          post "/admin/bih/board-notices/preview", params: { notice: attributes.merge(title: "") }
          assert_response :unprocessable_entity
          assert_select "textarea[name='notice[body]']", text: attributes[:body]
          assert_empty KomsilukPost.all
        end

        test "confirmation belongs to its actor and organization" do
          post "/admin/bih/board-notices/preview", params: { notice: attributes }
          token = css_select("input[name=confirmation_token]").first["value"]
          other_admin = create(:user, :admin, :confirmed, organization: @organization)
          sign_in other_admin
          assert_no_difference "KomsilukPost.count" do
            post "/admin/bih/board-notices/confirm", params: { confirmation_token: token }
          end
          assert_response :redirect
        end

        test "source prefill accepts only canonical references and ignores arbitrary details" do
          source = { title: "Odobren izvor", body: "Javni sažetak", area_ids: [@board.id], details: { source_record: { kind: "report", id: 1, revision: "r1" } } }
          old = Komsiluk::NoticeComposer.source_provider
          Komsiluk::NoticeComposer.source_provider = ->(**) { source }
          get "/admin/bih/board-notices/new", params: { source_kind: "report", source_id: 1, body: "private injected body" }
          assert_response :success
          assert_select "textarea[name='notice[body]']", text: "Javni sažetak"
          post "/admin/bih/board-notices/preview", params: { notice: attributes.merge(source_kind: "report", source_id: 1, details: { secret: "injected" }) }
          intent = KomsilukSendIntent.find_by!(organization: @organization)
          assert_nil intent.payload[:details][:secret]
          assert_equal "r1", intent.payload[:details][:source_record][:revision]
        ensure
          Komsiluk::NoticeComposer.source_provider = old
        end

        test "SMS setting is a single switch and forged tariff fields are ignored" do
          get "/admin/bih/board-notices/settings"
          assert_response :success
          assert_select "input[name='sms[enabled]']"
          assert_select "input[name='sms[price_minor]']", count: 0
          assert_select "input[name='sms[daily_limit_minor]']", count: 0
          assert_select "#board-channel-settings"

          assert_no_difference "KomsilukPhoneDelivery.count" do
            patch "/admin/bih/board-notices/settings", params: { sms: { enabled: "1", price_minor: "1", daily_limit_minor: "100000000", currency: "BAM", tariff_version: "forged" } }
          end
          assert_redirected_to "/admin/bih/board-notices/settings"
          assert_equal({ enabled: true }, Komsiluk::NoticePhonePolicy.sms_config(@organization))
          patch "/admin/bih/board-notices/settings", params: { sms: { enabled: "0" } }
          assert_redirected_to "/admin/bih/board-notices/settings"
          assert_equal({ enabled: false }, Komsiluk::NoticePhonePolicy.sms_config(@organization))
        end

        private

        def attributes
          { title: "Obavještenje", body: "Sadržaj objave", category: "general", expires_at: 1.day.from_now.iso8601, area_ids: [@board.id] }
        end
      end
    end
  end
end
