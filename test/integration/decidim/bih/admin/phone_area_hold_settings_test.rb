# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      class PhoneAreaHoldSettingsTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = create(:user, :admin, :confirmed, organization: @organization)
          @north = area(@organization, "north", "Sjeverna tabla")
          @south = area(@organization, "south", "Južna tabla")
          @mz = area(@organization, "district", "MZ nije tabla", kind: "mz")
          @foreign_organization = create_organization
          @foreign_area = area(@foreign_organization, "foreign", "Tuđa tabla")
          sign_in @admin
        end

        test "settings show scoped searchable boards and keep earlier muted areas read only" do
          Setting.put(@organization, Komsiluk::UrgentNotificationPolicy::NAMESPACE, "muted_komsiluk_ids", [@north.id.to_s, @foreign_area.id.to_s])
          get settings_path
          assert_response :success
          assert_select "#board-phone-area-holds-form [data-board-area-picker] input[data-area-search]", count: 1
          assert_select "input[type=checkbox][name='phone_policy[area_ids][]']", count: 2
          assert_select "input[type=checkbox][name='phone_policy[area_ids][]'][checked]", count: 0
          assert_select "#board-legacy-area-holds", text: /Sjeverna tabla/
          assert_select "#board-legacy-area-holds input", count: 0
          assert_select "input[name='categories[]']", count: 0
          assert_not_includes response.body, @foreign_area.translated_name
          assert_not_includes response.body, @mz.translated_name
          assert_equal({ komsiluk_ids: [], version: "" }, policy)
        end

        test "saving is audited and versioned without changing SMS policy or creating delivery work" do
          Setting.put(@organization, Komsiluk::NoticePhonePolicy::NAMESPACE, "sms_tariff_version", "retained-tariff")
          sms_before = Komsiluk::NoticePhonePolicy.sms_config(@organization)
          assert_no_difference ["KomsilukPost.count", "KomsilukPhoneDelivery.count", "KomsilukSendIntent.count"] do
            patch settings_path, params: { phone_policy: { area_ids: ["", @south.id.to_s, @north.id.to_s, @south.id.to_s] } }
          end
          assert_redirected_to settings_path
          saved = policy
          assert_equal [@north.id, @south.id].sort, saved[:komsiluk_ids]
          assert_match(/\A[0-9a-f]{32}\z/, saved[:version])
          assert_equal sms_before, Komsiluk::NoticePhonePolicy.sms_config(@organization)
          event = hold_audits.sole
          assert_equal @admin, event.user
          assert_equal "komsiluk_notification_policy_manage", event.permission
          assert_empty event.metadata["previous_held_komsiluk_ids"]
          assert_equal saved[:komsiluk_ids], event.metadata["held_komsiluk_ids"]
          assert_equal saved[:version], event.metadata["version"]
          get settings_path
          assert_select "input[name='phone_policy[area_ids][]'][checked]", count: 2
          assert_select "[data-area-selected]", text: /Sjeverna tabla/
          assert_select "[data-area-selected]", text: /Južna tabla/
        end

        test "repeated save is idempotent and clearing holds changes the confirmation version" do
          legacy = [@north.id.to_s]
          Setting.put(@organization, Komsiluk::UrgentNotificationPolicy::NAMESPACE, "muted_komsiluk_ids", legacy)
          Komsiluk::PhoneAreaHolds.save!(organization: @organization, actor: @admin, komsiluk_ids: [@north.id])
          saved = policy
          assert_no_difference -> { hold_audits.count } do
            patch settings_path, params: { phone_policy: { area_ids: ["", @north.id.to_s, @north.id.to_s] } }
          end
          assert_redirected_to settings_path
          assert_equal saved, policy
          assert_difference -> { hold_audits.count }, 1 do
            patch settings_path, params: { phone_policy: { area_ids: [""] } }
          end
          assert_redirected_to settings_path
          assert_empty policy[:komsiluk_ids]
          assert_not_equal saved[:version], policy[:version]
          assert_equal legacy, Komsiluk::UrgentNotificationPolicy.muted_komsiluk_ids_for(@organization)
        end

        test "foreign district and malformed selections are rejected without partial writes" do
          Komsiluk::PhoneAreaHolds.save!(organization: @organization, actor: @admin, komsiluk_ids: [@north.id])
          saved = policy
          [[@south.id, @foreign_area.id], [@south.id, @mz.id], [@south.id, "invalid"], "scalar"].each do |ids|
            assert_no_difference -> { hold_audits.count } do
              patch settings_path, params: { phone_policy: { area_ids: ids } }
            end
            assert_response :unprocessable_entity
            assert_equal saved, policy
            assert_select "#board-phone-area-holds-form"
          end
        end

        test "moderators and publishers cannot view or save administrator delivery policy" do
          %w(komsiluk_moderator broadcast_operator).each do |role|
            operator = create(:user, :confirmed, organization: @organization)
            OperatorRole.create!(organization: @organization, user: operator, role:, created_by: @admin,
                                 expires_at: 1.month.from_now)
            sign_in operator
            get settings_path
            assert_redirected_to "http://#{@organization.host}/admin/"
            assert_no_difference -> { hold_audits.count } do
              patch settings_path, params: { phone_policy: { area_ids: [@north.id] } }
            end
            assert_redirected_to "http://#{@organization.host}/admin/"
            assert_empty policy[:komsiluk_ids]
          end
        end

        test "service rejects an administrator from a different organization" do
          foreign_admin = create(:user, :admin, :confirmed, organization: @foreign_organization)
          error = assert_raises(Komsiluk::NoticeComposer::Refused) do
            Komsiluk::PhoneAreaHolds.save!(organization: @organization, actor: foreign_admin, komsiluk_ids: [@north.id])
          end
          assert_equal "permission_required", error.message
          assert_empty policy[:komsiluk_ids]
          assert_empty hold_audits
        end

        private

        def area(organization, slug, name, kind: "komsiluk")
          LocalArea.create!(organization:, kind:, slug: "phone-hold-#{slug}", name: { sr: name })
        end

        def settings_path
          "/admin/bih/board-notices/settings"
        end

        def policy
          Komsiluk::PhoneAreaHolds.snapshot(@organization)
        end

        def hold_audits
          OperatorAuditEvent.where(organization: @organization, event_type: "komsiluk_phone_area_holds_updated")
        end
      end
    end
  end
end
