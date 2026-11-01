# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 25 (W4.4) — admin editor for Sistem 48 forwarding targets.
      # Global-admin gated; org-scoped; CSRF-protected. Empty store forwards as
      # before (ENV/default).
      class Sistem48SettingsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        ROUTING = Decidim::Bih::Sistem48::DepartmentRouting

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "a non-admin is denied access" do
          sign_in @citizen
          get "/admin/bih/sistem48-settings"

          assert_response :redirect
        end

        test "an admin sees the routing form" do
          sign_in @admin
          get "/admin/bih/sistem48-settings"

          assert_response :success
          assert_select "input[name='settings[central_intake]']"
          assert_select "input[name='categories[putevi]']"
          assert_select "input[name='approval_rationale']"
          assert_select ".mi-admin-setting__values", minimum: 2
          assert_includes response.body, I18n.t("decidim.bih.admin.settings_values.none")
        end

        test "an admin saves a per-category override" do
          sign_in @admin
          assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "sistem48_settings_updated").count }, 1 do
            patch "/admin/bih/sistem48-settings", params: {
              categories: { putevi: "putevi@grad.example" },
              approval_rationale: "City roads department confirmed mailbox"
            }
          end

          assert_response :redirect
          assert_equal "putevi@grad.example", ROUTING.email_for(:putevi, @organization)
          assert_equal "City roads department confirmed mailbox",
                       Decidim::Bih::OperatorAuditEvent.where(event_type: "sistem48_settings_updated").last.metadata["approval_rationale"]
        end

        test "an admin saves a central intake override" do
          sign_in @admin
          patch "/admin/bih/sistem48-settings", params: {
            settings: { central_intake: "intake@grad.example" },
            approval_rationale: "Central intake mailbox changed by city"
          }

          assert_response :redirect
          assert_equal "intake@grad.example", ROUTING.central_intake(@organization)
        end

        test "a blank field clears its override and restores the default" do
          Decidim::Bih::Setting.put(@organization, ROUTING::NAMESPACE, "putevi", "old@grad.example")
          sign_in @admin
          patch "/admin/bih/sistem48-settings", params: {
            categories: { putevi: "" },
            approval_rationale: "Restore central routing"
          }

          assert_response :redirect
          assert_equal ROUTING.central_intake(@organization), ROUTING.email_for(:putevi, @organization)
        end

        test "the override is org-scoped" do
          other = create_organization
          sign_in @admin
          patch "/admin/bih/sistem48-settings", params: {
            categories: { putevi: "putevi@grad.example" },
            approval_rationale: "Scoped routing test"
          }

          assert_equal ROUTING.central_intake(other), ROUTING.email_for(:putevi, other)
        end

        test "a routing change requires an approval rationale" do
          sign_in @admin
          assert_no_difference "Decidim::Bih::Setting.count" do
            patch "/admin/bih/sistem48-settings", params: {
              categories: { putevi: "putevi@grad.example" }
            }
          end

          assert_response :unprocessable_entity
          assert_includes response.body, I18n.t("decidim.bih.admin.sistem48_settings.update.approval_rationale_required")
        end

        test "update rejects a missing CSRF token when forgery protection is on" do
          sign_in @admin
          with_forgery_protection do
            patch "/admin/bih/sistem48-settings", params: {
              categories: { putevi: "x@y.example" }
            }
          end
          assert_response :unprocessable_entity
        end

        private

        def with_forgery_protection
          previous = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          yield
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end
      end
    end
  end
end
