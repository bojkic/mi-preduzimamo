# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 25 — admin CRUD for the table-backed rewards catalog. Global-admin
      # gated; CSRF-protected; persists cost/stock/expiry/active.
      class RewardsAdminTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "catalog creation rolls back reward and adoption when audit fails" do
          sign_in @admin
          audit_attempted = false
          assert_no_difference -> { Goodwill::Reward.count } do
            OperatorAuditEvent.stub(:record!, ->(**) { audit_attempted = true; raise ActiveRecord::RecordInvalid }) do
              post "/admin/bih/rewards", params: { reward: { key: "audit_test", title_sr: "Test", cost: "20", active: "1" }, approval_rationale: "Test atomicity" }
            end
          end
          assert audit_attempted
          assert_response :unprocessable_entity
          assert_nil Setting.find_by(organization: @organization, namespace: Goodwill::RewardsCatalog::NAMESPACE, key: "mode")
        end

        test "a non-admin is denied access to the rewards index" do
          sign_in @citizen
          get "/admin/bih/rewards"

          assert_response :redirect
          assert_not_includes [200], response.status
        end

        test "an admin sees the rewards index" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: "majica", title: { "sr" => "Majica" }, cost: 500
          )
          sign_in @admin
          get "/admin/bih/rewards"

          assert_response :success
          assert_select "#admin-rewards-header[data-rewards-active-tab='catalog']"
          assert_select "#admin-rewards-workflow-nav a[aria-current='page'][href='/admin/bih/rewards?tab=catalog']"
          assert_select "#admin-rewards-workflow-nav a[href='/admin/bih/rewards?tab=stock']"
          assert_select "#admin-rewards-workflow-nav a[href='/admin/bih/rewards?tab=diagnostics']"
          assert_select "#admin-rewards-list"
          assert_select "#admin-rewards-stock-review", false
          assert_select "#admin-rewards-diagnostics", false
          assert_includes response.body, "Majica"
          assert_includes response.body, I18n.t("decidim.bih.admin.rewards.index.deactivate_confirm")
          assert_select "form[action='/admin/bih/rewards/#{reward.id}/deactivate'] .mi-admin-action--danger"
          assert_select "form[action='/admin/bih/rewards/#{reward.id}/deactivate'] input[name='approval_rationale']"
        end

        test "reward workflow tabs split catalog stock and diagnostics" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key: "majica",
            title: { "sr" => "Majica" },
            cost: 500,
            stock: 3,
            active: true
          )
          create_reward_fulfillment!(reward_key: reward.key, cost: reward.cost, status: "requested")
          create_reward_fulfillment!(reward_key: reward.key, cost: reward.cost, status: "fulfilled")
          create_reward_fulfillment!(reward_key: reward.key, cost: reward.cost, status: "canceled")

          sign_in @admin

          get "/admin/bih/rewards", params: { tab: "stock" }

          assert_response :success
          assert_select "#admin-rewards-header[data-rewards-active-tab='stock']"
          assert_select "#admin-rewards-workflow-nav a[aria-current='page'][href='/admin/bih/rewards?tab=stock']"
          assert_select "#admin-rewards-stock-review"
          assert_select "#admin-rewards-list", false
          assert_select "#admin-rewards-diagnostics", false
          assert_select "#admin-rewards-stock-review td", text: /Majica/
          assert_select "#admin-rewards-stock-review td", text: "2"
          assert_select "#admin-rewards-stock-review td", text: "1"
          assert_select "form[action='/admin/bih/rewards/#{reward.id}/deactivate']", false
          assert_select "a[href='/admin/bih/rewards/#{reward.id}/edit']"

          get "/admin/bih/rewards", params: { tab: "diagnostics" }

          assert_response :success
          assert_select "#admin-rewards-header[data-rewards-active-tab='diagnostics']"
          assert_select "#admin-rewards-diagnostics"
          assert_select "#admin-rewards-list", false
          assert_select "#admin-rewards-stock-review", false
          assert_includes response.body, "decidim_bih:goodwill:import_rewards_catalog"

          get "/admin/bih/rewards", params: { tab: "unknown" }

          assert_response :success
          assert_select "#admin-rewards-header[data-rewards-active-tab='catalog']"
          assert_select "#admin-rewards-list"
        end

        test "an admin sees the new reward form" do
          sign_in @admin
          get "/admin/bih/rewards/new"
          assert_response :success
          assert_select "input[name='reward[key]']"
          assert_select "input[name='reward[title_sr]']"
          assert_select "input[name='approval_rationale']"
        end

        test "an admin sees the edit reward form prefilled" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: "majica", title: { "sr" => "Majica" }, cost: 500
          )
          sign_in @admin
          get "/admin/bih/rewards/#{reward.id}/edit"
          assert_response :success
          assert_includes response.body, "majica"
          assert_includes response.body, "Majica"
          assert_select "input[name='approval_rationale']"
        end

        test "editing a non-existent reward redirects (no 500/DoubleRender)" do
          sign_in @admin
          get "/admin/bih/rewards/999999/edit"
          assert_response :redirect
          assert_redirected_to "/admin/bih/rewards"
        end

        test "editing another organization's reward redirects, not 500" do
          other = create_organization
          foreign = Decidim::Bih::Goodwill::Reward.create!(
            organization: other, key: "tudja", title: { "sr" => "Tuđa" }, cost: 100
          )
          sign_in @admin
          get "/admin/bih/rewards/#{foreign.id}/edit"
          assert_response :redirect
          assert_redirected_to "/admin/bih/rewards"
        end

        test "an admin creates a reward" do
          sign_in @admin
          assert_difference "Decidim::Bih::Goodwill::Reward.count", 1 do
            post "/admin/bih/rewards", params: {
              reward: {
                key: "nova",
                cost: "350",
                stock: "10",
                active: "1",
                title_sr: "Nova nagrada",
                title_bs: "Nova nagrada",
                title_hr: "Nova nagrada"
              },
              approval_rationale: "Board approved the new reward catalogue item"
            }
          end

          assert_response :redirect
          reward = Decidim::Bih::Goodwill::Reward.find_by(organization: @organization, key: "nova")
          assert_equal 350, reward.cost
          assert_equal 10, reward.stock
          assert reward.active?
          assert_equal "Nova nagrada", reward.title["sr"]
          assert_equal "Board approved the new reward catalogue item",
                       Decidim::Bih::OperatorAuditEvent.where(event_type: "reward_created").last.metadata["approval_rationale"]
        end

        test "creating a reward requires an approval rationale" do
          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::Reward.count" do
            post "/admin/bih/rewards", params: {
              reward: { key: "bez-odobrenja", cost: "350", active: "1", title_sr: "Bez odobrenja" }
            }
          end

          assert_response :unprocessable_entity
          assert_includes response.body, I18n.t("decidim.bih.admin.rewards.create.approval_rationale_required")
        end

        test "creating with an invalid cost re-renders without persisting" do
          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::Reward.count" do
            post "/admin/bih/rewards", params: {
              reward: { key: "loša", cost: "0", title_sr: "Loša" },
              approval_rationale: "Invalid cost coverage"
            }
          end
          assert_response :unprocessable_entity
        end

        test "an admin edits a reward's cost and stock" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: "torba", title: { "sr" => "Torba" }, cost: 300, stock: 5
          )
          sign_in @admin
          patch "/admin/bih/rewards/#{reward.id}", params: {
            reward: { key: "torba", cost: "450", stock: "", title_sr: "Torba" },
            approval_rationale: "Stock is now handled manually"
          }

          assert_response :redirect
          reward.reload
          assert_equal 450, reward.cost
          assert_nil reward.stock # blank stock => unlimited
          audit = Decidim::Bih::OperatorAuditEvent.where(event_type: "reward_updated").last
          assert_equal "Stock is now handled manually", audit.metadata["approval_rationale"]
          assert_includes audit.metadata["changed_fields"], "stock"
        end

        test "editing a reward requires an approval rationale" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: "torba", title: { "sr" => "Torba" }, cost: 300, stock: 5
          )
          sign_in @admin
          patch "/admin/bih/rewards/#{reward.id}", params: {
            reward: { key: "torba", cost: "450", stock: "5", title_sr: "Torba" }
          }

          assert_response :unprocessable_entity
          assert_includes response.body, I18n.t("decidim.bih.admin.rewards.update.approval_rationale_required")
          assert_equal 300, reward.reload.cost
        end

        test "a no-op reward edit does not require an approval rationale" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key: "torba",
            title: {
              "sr" => "Torba",
              "sr-Cyrl" => Decidim::Bih::Transliterator.call("Torba")
            },
            cost: 300,
            stock: 5,
            active: true
          )
          sign_in @admin
          patch "/admin/bih/rewards/#{reward.id}", params: {
            reward: { key: "torba", cost: "300", stock: "5", active: "1", title_sr: "Torba" }
          }

          assert_response :redirect
          assert_equal 300, reward.reload.cost
        end

        test "an admin deactivates and reactivates a reward with approval rationale" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: "termos", title: { "sr" => "Termos" }, cost: 800, active: true
          )
          sign_in @admin

          post "/admin/bih/rewards/#{reward.id}/deactivate", params: {
            approval_rationale: "Seasonal stock ended"
          }
          assert_response :redirect
          assert_not reward.reload.active?
          assert_equal "Seasonal stock ended",
                       Decidim::Bih::OperatorAuditEvent.where(event_type: "reward_deactivated").last.metadata["approval_rationale"]

          post "/admin/bih/rewards/#{reward.id}/activate", params: {
            approval_rationale: "Stock confirmed again"
          }
          assert_response :redirect
          assert reward.reload.active?
          assert_equal "Stock confirmed again",
                       Decidim::Bih::OperatorAuditEvent.where(event_type: "reward_activated").last.metadata["approval_rationale"]
        end

        test "failed activation keeps the stored state, audit and entered rationale" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: "old-entry", title: { "sr" => "Stara nagrada" }, cost: 100, active: false
          )
          reward.update_columns(cost: -1)
          sign_in @admin

          assert_no_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "reward_activated").count } do
            post "/admin/bih/rewards/#{reward.id}/activate", params: { approval_rationale: "Catalog review" }
          end

          assert_response :unprocessable_entity
          assert_not reward.reload.active?
          assert_select "form[action='/admin/bih/rewards/#{reward.id}/activate'] input[name='approval_rationale'][value='Catalog review']"
        end

        test "reward activation changes require approval rationale" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: "termos", title: { "sr" => "Termos" }, cost: 800, active: true
          )
          sign_in @admin

          post "/admin/bih/rewards/#{reward.id}/deactivate"

          assert_response :redirect
          assert reward.reload.active?
          follow_redirect!
          assert_includes response.body, I18n.t("decidim.bih.admin.rewards.deactivate.approval_rationale_required")
        end

        test "an admin cannot edit another organization's reward" do
          other = create_organization
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: other, key: "tudja", title: { "sr" => "Tuđa" }, cost: 100
          )
          sign_in @admin
          patch "/admin/bih/rewards/#{reward.id}", params: {
            reward: { key: "tudja", cost: "999", title_sr: "Tuđa" },
            approval_rationale: "Should not pass scoping"
          }

          # Scoped lookup => not found => redirect to index, no mutation.
          assert_response :redirect
          assert_equal 100, reward.reload.cost
        end

        test "create rejects a missing CSRF token when forgery protection is on" do
          sign_in @admin
          with_forgery_protection do
            assert_no_difference "Decidim::Bih::Goodwill::Reward.count" do
              post "/admin/bih/rewards", params: {
                reward: { key: "csrf", cost: "100", title_sr: "CSRF" }
              }
            end
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

        def create_reward_fulfillment!(reward_key:, cost:, status:)
          ledger = Decidim::Bih::Goodwill::Ledger.new
          ledger.award(@citizen, cost, reason: "test-seed")
          transaction = ledger.spend(
            owner: @citizen,
            amount: cost,
            kind: "redeem",
            reason: "reward:#{reward_key}"
          )

          Decidim::Bih::Goodwill::RewardFulfillment.create!(
            organization: @organization,
            ledger_transaction: transaction,
            user: @citizen,
            reward_key:,
            cost:,
            status:,
            handled_by: (%w(fulfilled canceled reversed).include?(status) ? @admin : nil),
            handled_at: (%w(fulfilled canceled reversed).include?(status) ? Time.current : nil)
          )
        end
      end
    end
  end
end
