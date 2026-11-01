# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 25 (W4.2) — admin editor for the Goodwill earning schedule / daily
      # caps / season. Global-admin gated; CSRF-protected; persists overrides in
      # Decidim::Bih::Setting with strict fallback discipline.
      class GoodwillSettingsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "a non-admin is denied access" do
          sign_in @citizen
          get "/admin/bih/goodwill-settings"

          assert_response :redirect
        end

        test "an admin sees the settings form with current values" do
          report_default = Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE
                           .merge(Decidim::Bih.goodwill_earning_schedule.to_h.symbolize_keys)
                           .fetch(:report)
          sign_in @admin
          get "/admin/bih/goodwill-settings"

          assert_response :success
          assert_select "input[name='schedule[report]']"
          assert_select "input[name='caps[report]']"
          assert_select "input[name='settings[season_started_at]']"
          assert_select "input[name='approval_rationale']"
          assert_select ".mi-admin-setting__values", minimum: 3
          assert_includes response.body, I18n.t("decidim.bih.admin.settings_values.default", value: report_default)
          assert_includes response.body, I18n.t("decidim.bih.admin.settings_values.none")
        end

        test "with no overrides the form shows the default as a placeholder, not a value" do
          default = Decidim::Bih::Goodwill::EarningRules.new(organization: @organization).points_for(:report)
          sign_in @admin
          get "/admin/bih/goodwill-settings"

          assert_response :success
          # The effective default is the placeholder (a hint), never a pre-filled
          # value — so a no-op save submits a blank and writes nothing.
          assert_select "input[name='schedule[report]'][placeholder=?][value='']", default.to_s
        end

        test "a no-op save with no existing overrides writes nothing to the DB" do
          # Re-submitting the freshly-rendered form (all fields blank, since there
          # are no overrides) must not bake defaults into the store. An empty store
          # stays empty — byte-identical to the pre-table behavior.
          sign_in @admin
          assert_no_difference "Decidim::Bih::Setting.count" do
            patch "/admin/bih/goodwill-settings", params: {
              schedule: { report: "" },
              caps: { report: "" },
              settings: { season_started_at: "" }
            }
          end

          assert_response :redirect
        end

        test "an admin saves a schedule override" do
          sign_in @admin
          assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "goodwill_settings_updated").count }, 1 do
            patch "/admin/bih/goodwill-settings", params: {
              schedule: { report: "99" },
              approval_rationale: "Board approved report points trial"
            }
          end

          assert_response :redirect
          value = Decidim::Bih::Setting.namespace_for(
            @organization, Decidim::Bih::Goodwill::EarningRules::SCHEDULE_NAMESPACE
          )["report"]
          assert_equal 99, value
          assert_equal "Board approved report points trial",
                       Decidim::Bih::OperatorAuditEvent.where(event_type: "goodwill_settings_updated").last.metadata["approval_rationale"]
        end

        test "ordinary report amount cannot undercut the duplicate amount" do
          sign_in @admin
          assert_no_difference -> { Decidim::Bih::Setting.count } do
            patch "/admin/bih/goodwill-settings", params: { schedule: { report: "4" }, approval_rationale: "Invalid scale" }
          end
          assert_response :unprocessable_entity
        end

        test "an admin saves a cap override" do
          sign_in @admin
          patch "/admin/bih/goodwill-settings", params: {
            caps: { report: "2" },
            approval_rationale: "Reduce report farming risk"
          }

          assert_response :redirect
          value = Decidim::Bih::Setting.namespace_for(
            @organization, Decidim::Bih::Goodwill::EarningRules::CAPS_NAMESPACE
          )["report"]
          assert_equal 2, value
        end

        test "an admin saves a season start" do
          sign_in @admin
          patch "/admin/bih/goodwill-settings", params: {
            settings: { season_started_at: "2026-04-01" },
            approval_rationale: "Q2 season reset"
          }

          assert_response :redirect
          assert_equal Time.zone.parse("2026-04-01"),
                       Decidim::Bih::Goodwill::EarningRules.season_started_at(@organization)
        end

        test "a blank field clears its override and restores the default" do
          Decidim::Bih::Setting.put(
            @organization, Decidim::Bih::Goodwill::EarningRules::SCHEDULE_NAMESPACE, "report", 99
          )
          sign_in @admin
          patch "/admin/bih/goodwill-settings", params: {
            schedule: { report: "" },
            approval_rationale: "Restore default report points"
          }

          assert_response :redirect
          overrides = Decidim::Bih::Setting.namespace_for(
            @organization, Decidim::Bih::Goodwill::EarningRules::SCHEDULE_NAMESPACE
          )
          assert_not overrides.has_key?("report")
        end

        test "a changing save requires an approval rationale" do
          sign_in @admin
          assert_no_difference "Decidim::Bih::Setting.count" do
            patch "/admin/bih/goodwill-settings", params: {
              schedule: { report: "42" }
            }
          end

          assert_response :unprocessable_entity
          assert_includes response.body, I18n.t("decidim.bih.admin.goodwill_settings.update.approval_rationale_required")
        end

        test "an unknown action param cannot inject a setting" do
          sign_in @admin
          patch "/admin/bih/goodwill-settings", params: {
            schedule: { totally_made_up: "500" }
          }

          assert_response :unprocessable_entity
          overrides = Decidim::Bih::Setting.namespace_for(
            @organization, Decidim::Bih::Goodwill::EarningRules::SCHEDULE_NAMESPACE
          )
          assert_not overrides.has_key?("totally_made_up")
        end

        test "update rejects a missing CSRF token when forgery protection is on" do
          sign_in @admin
          with_forgery_protection do
            patch "/admin/bih/goodwill-settings", params: { schedule: { report: "50" } }
          end
          assert_response :unprocessable_entity
        end

        test "partial updates preserve omitted actions caps and season" do
          rules = Decidim::Bih::Goodwill::EarningRules
          Decidim::Bih::Setting.put(@organization, rules::SCHEDULE_NAMESPACE, "like", 4)
          Decidim::Bih::Setting.put(@organization, rules::CAPS_NAMESPACE, "report", 2)
          Decidim::Bih::Setting.put(@organization, rules::SEASON_NAMESPACE, rules::SEASON_KEY, "2026-01-01")
          sign_in @admin
          patch "/admin/bih/goodwill-settings", params: { schedule: { report: "30" }, approval_rationale: "Approved change" }
          assert_response :redirect
          assert_equal 4, Decidim::Bih::Setting.namespace_for(@organization, rules::SCHEDULE_NAMESPACE)["like"]
          assert_equal 2, Decidim::Bih::Setting.namespace_for(@organization, rules::CAPS_NAMESPACE)["report"]
          assert_equal "2026-01-01", Decidim::Bih::Setting.namespace_for(@organization, rules::SEASON_NAMESPACE)[rules::SEASON_KEY]
        end

        test "empty request is a safe no-op with existing overrides" do
          rules = Decidim::Bih::Goodwill::EarningRules
          Decidim::Bih::Setting.put(@organization, rules::SCHEDULE_NAMESPACE, "report", 30)
          sign_in @admin
          patch "/admin/bih/goodwill-settings", params: { caps: {} }
          assert_response :redirect
          assert_equal 30, Decidim::Bih::Setting.namespace_for(@organization, rules::SCHEDULE_NAMESPACE)["report"]
        end

        test "invalid values reject the complete request without partial writes" do
          sign_in @admin
          ["garbage", "2.5", "-1", "100001", ["2"], { nested: "2" }].each do |value|
            assert_no_difference "Decidim::Bih::Setting.count" do
              patch "/admin/bih/goodwill-settings", params: { schedule: { report: value }, caps: { report: "2" }, approval_rationale: "Review" }
            end
            assert_response :unprocessable_entity
          end
        end

        test "invalid season date does not save otherwise valid schedule" do
          sign_in @admin
          assert_no_difference "Decidim::Bih::Setting.count" do
            patch "/admin/bih/goodwill-settings", params: { schedule: { report: "30" }, settings: { season_started_at: "2026-02-31" }, approval_rationale: "Review" }
          end
          assert_response :unprocessable_entity
        end

        test "proposal monthly cap is stored separately and daily key rejected" do
          sign_in @admin
          patch "/admin/bih/goodwill-settings", params: { monthly_caps: { proposal: "1" }, approval_rationale: "Owner rule" }
          assert_response :redirect
          rules = Decidim::Bih::Goodwill::EarningRules
          assert_equal 1, Decidim::Bih::Setting.namespace_for(@organization, rules::MONTHLY_CAPS_NAMESPACE)["proposal"]
          patch "/admin/bih/goodwill-settings", params: { caps: { proposal: "1" }, approval_rationale: "Wrong period" }
          assert_response :unprocessable_entity
        end

        test "registration invariant violation rolls back every section" do
          sign_in @admin
          assert_no_difference "Decidim::Bih::Setting.count" do
            patch "/admin/bih/goodwill-settings", params: { schedule: { verification: "15", report: "30" }, approval_rationale: "Invalid total" }
          end
          assert_response :unprocessable_entity
        end

        test "audit failure rolls back settings changes" do
          sign_in @admin
          audit_attempted = false
          Decidim::Bih::OperatorAuditEvent.stub(:record!, ->(**) { audit_attempted = true; raise ActiveRecord::RecordInvalid }) do
            patch "/admin/bih/goodwill-settings", params: { schedule: { report: "30" }, approval_rationale: "Approved" }
          end
          assert audit_attempted
          assert_response :unprocessable_entity
          assert_empty Decidim::Bih::Setting.where(organization: @organization)
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
