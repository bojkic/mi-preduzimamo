# frozen_string_literal: true

require "test_helper"
require "capybara"
require "csv"

module Decidim
  module Bih
    module Admin
      # R5 — admin "Goodwill economy" dashboard: read-mostly stats + the pending
      # volunteer-log verification queue (verify) and per-transaction reverse.
      class GoodwillDashboardTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @previous_cache = Rails.cache
          Rails.cache = ActiveSupport::Cache::MemoryStore.new
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @partner_profile = create_volunteer_partner_profile!(organization: @organization, slug: "udruzenje-goodwill")
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        teardown do
          Rails.cache = @previous_cache
        end

        test "a non-admin is denied access" do
          sign_in @citizen
          get "/admin/bih/goodwill"

          # Decidim's admin-area gate denies a non-admin before our superadmin
          # check runs — redirecting out of /admin rather than rendering the page.
          assert_response :redirect
          assert_not_includes [200], response.status
        end

        test "an admin sees the dashboard with total issued points and a top earner" do
          @ledger.award(@citizen, 40, reason: "proposal")
          sign_in @admin
          get "/admin/bih/goodwill", params: { tab: "overview" }

          assert_response :success
          assert_includes response.body, "40"
          assert_includes response.body, @citizen.name
          assert_includes response.body, "/admin/bih/volunteering"
        end

        test "admin dashboard workflow tabs focus the page sections" do
          sign_in @admin

          get "/admin/bih/goodwill"
          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='rewards']"
          assert_select "#goodwill-workflow-nav a[href='/admin/bih/goodwill?tab=rewards'][aria-current='page']"
          assert_select "#goodwill-workflow-nav a[href='/admin/bih/goodwill?tab=overview']"
          assert_select "#goodwill-workflow-nav a[href='/admin/bih/goodwill?tab=matched_giving']"
          assert_select "#goodwill-workflow-nav a[href='/admin/bih/goodwill?tab=organization_spending']"
          assert_select "#goodwill-workflow-nav a[href='/admin/bih/goodwill?tab=reports']"
          assert_select "#goodwill-workflow-nav a[href='/admin/bih/goodwill?tab=ledger']"
          assert_select "#goodwill-reward-fulfillments"
          assert_select "#goodwill-match-requests", count: 0
          assert_select "#goodwill-report-forwarding-failures", count: 0
          assert_select "#goodwill-transactions", count: 0

          get "/admin/bih/goodwill", params: { tab: "overview" }
          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='overview']"
          assert_select "#goodwill-metrics"
          assert_select "#goodwill-top-earners"
          assert_select "#goodwill-volunteering-handoff"
          assert_select "#goodwill-reward-fulfillments", count: 0

          get "/admin/bih/goodwill", params: { tab: "organization_spending" }
          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='organization_spending']"
          assert_select "#goodwill-organization-spending"
          assert_select "#goodwill-reward-fulfillments", count: 0

          get "/admin/bih/goodwill", params: { tab: "ledger" }
          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='ledger']"
          assert_select "#goodwill-redemptions"
          assert_select "#goodwill-transactions"
          assert_select "#goodwill-reward-fulfillments", count: 0

          get "/admin/bih/goodwill", params: { tab: "unknown" }
          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='rewards']"
          assert_select "#goodwill-reward-fulfillments"
        end

        test "cached summary refreshes when a new ledger transaction is posted" do
          @ledger.award(@citizen, 40, reason: "proposal")
          sign_in @admin

          get "/admin/bih/goodwill", params: { tab: "overview" }
          assert_response :success
          assert_includes response.body, @citizen.name

          second_citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(second_citizen, 75, reason: "proposal")

          get "/admin/bih/goodwill", params: { tab: "overview" }
          assert_response :success
          assert_includes response.body, second_citizen.name
          assert_includes response.body, "115"
        end

        test "volunteer queues are handed off to volunteering roster" do
          sign_in @admin

          get "/admin/bih/goodwill", params: { tab: "overview" }
          assert_response :success

          opportunity = VolunteerOpportunity.create!(
            organization: @organization, title: "Hitna smjena", active: true
          )
          create_legacy_volunteer_log!(
            organization: @organization,
            opportunity:,
            user: @citizen,
            hours: 1,
            status: "pending"
          )

          get "/admin/bih/goodwill", params: { tab: "overview" }
          assert_response :success
          assert_select "#goodwill-volunteering-handoff"
          assert_includes response.body, "/admin/bih/volunteering?subqueue=pending_logs"
          assert_not_includes response.body, "Hitna smjena"
          assert_select "#goodwill-pending-logs", count: 0
          assert_select "#goodwill-pending-opportunities", count: 0
        end

        test "admin dashboard does not show another organization's pending volunteer queues" do
          other = create_organization
          other_citizen = FactoryBot.create(:user, :confirmed, organization: other)
          other_opportunity = VolunteerOpportunity.create!(
            organization: other,
            author: other_citizen,
            title: "Tuđa prilika",
            category: "community_care",
            partner_profile: create_volunteer_partner_profile!(organization: other, slug: "tudje-udruzenje"),
            partner_name: "Tuđe udruženje",
            active: false,
            review_status: "pending"
          )
          create_legacy_volunteer_log!(
            organization: other,
            opportunity: other_opportunity,
            user: other_citizen,
            hours: 2,
            status: "pending"
          )

          sign_in @admin
          get "/admin/bih/goodwill", params: { tab: "overview" }

          assert_response :success
          assert_not_includes response.body, "Tuđa prilika"
        end

        test "admin sees sanitized report forwarding failures" do
          report = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Rupa ispred kuce",
            address: "Vidovdanska 3",
            reporter_email: "gradjanin@example.org",
            reporter_phone: "+387 65 123 456"
          )
          report.record_forwarding_failure!(
            StandardError.new(
              'SMTP failed for gradjanin@example.org +387 65 123 456 address: "Vidovdanska 3" description: "Rupa ispred kuce"'
            ),
            code: "smtp_421"
          )

          sign_in @admin
          get "/admin/bih/goodwill", params: { tab: "reports" }

          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='reports']"
          assert_select "#goodwill-report-forwarding-failures"
          assert_includes response.body, report.reference
          assert_includes response.body, "/admin/bih/reports/#{report.reference}"
          assert_not_includes response.body, "StandardError"
          assert_not_includes response.body, "smtp_421"
          assert_not_includes response.body, "[email]"
          assert_not_includes response.body, "[phone]"
          assert_not_includes response.body, "address: [redacted]"
          assert_not_includes response.body, "description: [redacted]"
          assert_not_includes response.body, "gradjanin@example.org"
          assert_not_includes response.body, "+387 65 123 456"
          assert_not_includes response.body, "Vidovdanska 3"
          assert_not_includes response.body, "Rupa ispred kuce"
        end

        test "dashboard does not render volunteer log queue rows" do
          opportunity = VolunteerOpportunity.create!(
            organization: @organization, title: "Velika akcija", active: true
          )
          51.times do
            create_legacy_volunteer_log!(
              organization: @organization,
              opportunity:,
              user: @citizen,
              hours: 1,
              status: "pending"
            )
          end

          sign_in @admin
          get "/admin/bih/goodwill", params: { tab: "overview" }

          assert_response :success
          assert_select "#goodwill-volunteering-handoff"
          assert_select "#goodwill-pending-logs", count: 0
          assert_not_includes response.body, "Velika akcija"
        end

        test "an admin verifies a pending volunteer log from the dashboard" do
          previous_unit = Decidim::Bih.volunteer_work_award_unit
          Decidim::Bih.volunteer_work_award_unit = :day
          opportunity = VolunteerOpportunity.create!(
            organization: @organization, title: "Čišćenje parka", active: true, review_status: "approved"
          )
          signup = VolunteerSignup.create!(
            organization: @organization, opportunity:, user: @citizen,
            status: "going", review_status: "automatic", review_source: "automatic"
          )
          zone = Time.find_zone!("Europe/Sarajevo")
          work_date = 2.days.ago.in_time_zone(zone).to_date
          worked_from_at = zone.parse("#{work_date.iso8601} 09:00")
          log = VolunteerLog.create!(
            organization: @organization, opportunity:, user: @citizen,
            work_date:, worked_from_at:, worked_until_at: worked_from_at + 2.hours,
            hours: 2, status: "pending"
          )
          sign_in @admin
          post "/admin/bih/goodwill/volunteer-log/#{log.id}/verify", params: { confirm_attendance: "1" }

          assert_response :redirect
          assert log.reload.approved?
          assert VolunteerAttendance.confirmed.exists?(signup:, work_date:)
          assert_equal 100, @ledger.account_for(@citizen).contribution_score
        ensure
          Decidim::Bih.volunteer_work_award_unit = previous_unit
        end

        test "an admin cannot verify another organization's volunteer log" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          opportunity = VolunteerOpportunity.create!(
            organization: other, title: "Tuđe čišćenje", active: true
          )
          log = create_legacy_volunteer_log!(
            organization: other, opportunity:, user: outsider, hours: 2, status: "pending"
          )

          sign_in @admin
          post "/admin/bih/goodwill/volunteer-log/#{log.id}/verify"

          assert_response :redirect
          assert log.reload.pending?
          assert_equal 0, @ledger.account_for(outsider).contribution_score
        end

        test "admin volunteer verification rejects missing CSRF token when forgery protection is enabled" do
          opportunity = VolunteerOpportunity.create!(
            organization: @organization, title: "Čišćenje parka", active: true
          )
          log = create_legacy_volunteer_log!(
            organization: @organization, opportunity:, user: @citizen, hours: 2, status: "pending"
          )

          sign_in @admin
          with_forgery_protection do
            assert_no_difference -> { @ledger.account_for(@citizen).contribution_score } do
              post "/admin/bih/goodwill/volunteer-log/#{log.id}/verify"
            end
          end

          assert_response :unprocessable_entity
          assert log.reload.pending?
        end

        test "an admin rejects a pending volunteer log from the dashboard" do
          opportunity = VolunteerOpportunity.create!(
            organization: @organization, title: "Čišćenje parka", active: true
          )
          log = create_legacy_volunteer_log!(
            organization: @organization, opportunity:, user: @citizen, hours: 2, status: "pending"
          )

          sign_in @admin
          post "/admin/bih/goodwill/volunteer-log/#{log.id}/reject",
               params: { rejection_reason: "Nema evidencije dolaska" }

          assert_response :redirect
          assert log.reload.rejected?
          assert_equal "Nema evidencije dolaska", log.rejection_reason
          assert_equal 0, @ledger.account_for(@citizen).contribution_score
        end

        test "an admin cannot reject another organization's volunteer log" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          opportunity = VolunteerOpportunity.create!(
            organization: other, title: "Tuđe čišćenje", active: true
          )
          log = create_legacy_volunteer_log!(
            organization: other, opportunity:, user: outsider, hours: 2, status: "pending"
          )

          sign_in @admin
          post "/admin/bih/goodwill/volunteer-log/#{log.id}/reject",
               params: { rejection_reason: "Nije naš zapis" }

          assert_response :redirect
          assert log.reload.pending?
          assert log.rejection_reason.blank?
        end

        test "an admin approves a pending volunteer opportunity from the dashboard" do
          opportunity = VolunteerOpportunity.create!(
            organization: @organization,
            author: @citizen,
            title: "Sadnja cvijeća",
            category: "environment",
            partner_profile: @partner_profile,
            partner_name: @partner_profile.display_name,
            active: false,
            review_status: "pending"
          )

          sign_in @admin
          post "/admin/bih/goodwill/volunteer-opportunity/#{opportunity.id}/approve",
               params: { confirm_partner: "1" }

          assert_response :redirect
          assert opportunity.reload.approved?
          assert opportunity.active?
          assert_equal @admin.id, opportunity.reviewed_by_id
          assert_equal 25, @ledger.account_for(@citizen).contribution_score
        end

        test "an admin cannot approve another organization's volunteer opportunity" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          opportunity = VolunteerOpportunity.create!(
            organization: other,
            author: outsider,
            title: "Tuđa sadnja",
            category: "environment",
            partner_profile: create_volunteer_partner_profile!(organization: other, slug: "tudja-sadnja"),
            partner_name: "Tuđa sadnja",
            active: false,
            review_status: "pending"
          )

          sign_in @admin
          post "/admin/bih/goodwill/volunteer-opportunity/#{opportunity.id}/approve"

          assert_response :redirect
          assert opportunity.reload.pending_review?
          assert_not opportunity.active?
          assert_equal 0, @ledger.account_for(outsider).contribution_score
        end

        test "an admin rejects a pending volunteer opportunity from the dashboard" do
          opportunity = VolunteerOpportunity.create!(
            organization: @organization,
            author: @citizen,
            title: "Sadnja cvijeća",
            category: "environment",
            partner_profile: @partner_profile,
            partner_name: @partner_profile.display_name,
            active: false,
            review_status: "pending"
          )

          sign_in @admin
          post "/admin/bih/goodwill/volunteer-opportunity/#{opportunity.id}/reject",
               params: { rejection_reason: "Termin nije potvrđen" }

          assert_response :redirect
          assert opportunity.reload.rejected?
          assert_not opportunity.active?
          assert_equal "Termin nije potvrđen", opportunity.rejection_reason
          assert_equal 0, @ledger.account_for(@citizen).contribution_score
        end

        test "an admin reverses a transaction (append-only correction)" do
          txn = @ledger.award(@citizen, 30, reason: "proposal")
          assert_equal 30, @ledger.account_for(@citizen).balance

          sign_in @admin
          post "/admin/bih/goodwill/transaction/#{txn.id}/reverse",
               params: { private_reason: "Ispravka pogrešno dodijeljenih bodova" }

          assert_response :redirect
          assert_redirected_to "/admin/bih/goodwill?tab=ledger#goodwill-transactions"
          # Revoking the source removes both its wallet credit and recognition.
          assert_equal 0, @ledger.account_for(@citizen).balance
          assert_equal 0, @ledger.account_for(@citizen).contribution_score
          assert_equal(-30, Decidim::Bih::Goodwill::CreditCorrection.find_by!(original_transaction: txn).recognition_delta)
        end

        test "an admin sees and fulfills reward redemptions" do
          @ledger.award(@citizen, 600, reason: "proposal")
          Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last

          sign_in @admin
          get "/admin/bih/goodwill"

          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.goodwill.rewards.majica", locale: :sr)
          assert_includes response.body, @citizen.name

          assert_difference -> { fulfillment.events.where(event_type: "fulfilled").count }, 1 do
            post "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/fulfilled"
          end

          assert_response :redirect
          assert_redirected_to "/admin/bih/goodwill?tab=rewards#goodwill-reward-fulfillments"
          assert_equal "fulfilled", fulfillment.reload.status
          assert_equal @admin.id, fulfillment.handled_by_id

          assert_equal %w(requested fulfilled), fulfillment.events.chronological.pluck(:event_type)
          event = fulfillment.events.where(event_type: "fulfilled").last
          assert_equal @admin, event.actor
          assert_equal "single", event.metadata["action"]
          assert_equal "requested", event.metadata["from_status"]
          assert_equal "fulfilled", event.metadata["to_status"]
        end

        test "reward fulfillment filters by status and reward and shows stock context" do
          reward = create_reward!("vip_kupon", "VIP kupon", cost: 200, stock: 2)
          other_reward = create_reward!("druga", "Druga nagrada", cost: 100, stock: 3)
          fulfilled = create_reward_fulfillment!(reward_key: reward.key, cost: reward.cost, status: "fulfilled")
          create_reward_fulfillment!(reward_key: other_reward.key, cost: other_reward.cost, status: "requested")

          sign_in @admin
          get "/admin/bih/goodwill", params: {
            tab: "rewards",
            reward_fulfillment_status: "fulfilled",
            reward_key: reward.key
          }

          assert_response :success
          assert_select "#goodwill-stats[data-goodwill-active-tab='rewards']"
          assert_select "#goodwill-reward-fulfillments tbody tr", count: 1
          assert_select "#goodwill-reward-fulfillments input[name='tab'][value='rewards']"
          assert_select "#goodwill-reward-fulfillments tbody tr td", text: "VIP kupon"
          assert_select "#goodwill-reward-fulfillments tbody tr td", text: fulfilled.user.name
          assert_select "#goodwill-reward-fulfillments tbody tr td", text: /Preostalo 1 od 2/
          assert_select "#goodwill-reward-fulfillments tbody tr td", text: "Druga nagrada", count: 0
        end

        test "reward fulfillment csv export is filtered and organization scoped" do
          reward = create_reward!("vip_kupon", "VIP kupon", cost: 200, stock: 2)
          exported = create_reward_fulfillment!(reward_key: reward.key, cost: reward.cost, status: "reserved")
          create_reward_fulfillment!(reward_key: "druga", cost: 100, status: "requested")
          other = create_organization
          other_user = FactoryBot.create(:user, :confirmed, organization: other, name: "Tuđi dobitnik")
          other_ledger = Decidim::Bih::Goodwill::Ledger.new
          other_ledger.award(other_user, 200, reason: "seed")
          other_txn = other_ledger.spend(owner: other_user, amount: 200, kind: "redeem", reason: "reward:vip_kupon")
          Decidim::Bih::Goodwill::RewardFulfillment.create!(
            organization: other,
            ledger_transaction: other_txn,
            user: other_user,
            reward_key: reward.key,
            cost: reward.cost,
            status: "reserved"
          )

          sign_in @admin
          get "/admin/bih/goodwill/reward-fulfillments/export.csv", params: {
            reward_fulfillment_status: "reserved",
            reward_key: reward.key
          }

          assert_response :success
          assert_equal "text/csv", response.media_type
          rows = CSV.parse(response.body, headers: true)
          assert_equal 1, rows.size
          assert_equal exported.id.to_s, rows.first["id"]
          assert_equal "VIP kupon", rows.first["reward_name"]
          assert_equal "1", rows.first["stock_remaining"]
          assert_not_includes response.body, "Tuđi dobitnik"
        end

        test "admin batch updates selected open reward fulfillments" do
          selected = create_reward_fulfillment!(reward_key: "majica", cost: 500, status: "requested")
          untouched = create_reward_fulfillment!(reward_key: "torba", cost: 300, status: "requested")

          sign_in @admin
          post "/admin/bih/goodwill/reward-fulfillments/batch",
               params: { fulfillment_ids: [selected.id], batch_status: "reserved" }

          assert_response :redirect
          assert_redirected_to "/admin/bih/goodwill?tab=rewards#goodwill-reward-fulfillments"
          assert_equal "reserved", selected.reload.status
          assert_equal @admin.id, selected.handled_by_id
          assert_equal "requested", untouched.reload.status

          event = selected.events.where(event_type: "reserved").last
          assert_equal "batch", event.metadata["action"]
          assert_equal 1, event.metadata["selected_count"]
          assert_equal @admin, event.actor
        end

        test "batch reward fulfillment update is organization scoped" do
          other = create_organization
          other_user = FactoryBot.create(:user, :confirmed, organization: other)
          other_ledger = Decidim::Bih::Goodwill::Ledger.new
          other_ledger.award(other_user, 500, reason: "seed")
          other_txn = other_ledger.spend(owner: other_user, amount: 500, kind: "redeem", reason: "reward:majica")
          other_fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.create!(
            organization: other,
            ledger_transaction: other_txn,
            user: other_user,
            reward_key: "majica",
            cost: 500,
            status: "requested"
          )

          sign_in @admin
          post "/admin/bih/goodwill/reward-fulfillments/batch",
               params: { fulfillment_ids: [other_fulfillment.id], batch_status: "reserved" }

          assert_response :redirect
          assert_equal "requested", other_fulfillment.reload.status
          assert_nil other_fulfillment.handled_by_id
        end

        test "batch reward fulfillment update rejects missing CSRF token" do
          fulfillment = create_reward_fulfillment!(reward_key: "majica", cost: 500, status: "requested")

          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::RewardFulfillmentEvent.count" do
            with_forgery_protection do
              post "/admin/bih/goodwill/reward-fulfillments/batch",
                   params: { fulfillment_ids: [fulfillment.id], batch_status: "reserved" }
            end
          end

          assert_response :unprocessable_entity
          assert_equal "requested", fulfillment.reload.status
        end

        test "admin dashboard does not show another organization's reward fulfillments" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other, name: "Tuđi dobitnik")
          @ledger.award(outsider, 600, reason: "proposal")
          Decidim::Bih::Goodwill::RedeemReward.call(outsider, "majica")

          sign_in @admin
          get "/admin/bih/goodwill"

          assert_response :success
          assert_select "#goodwill-reward-fulfillments"
          assert_not_includes response.body, "Tuđi dobitnik"
        end

        test "an admin cannot fulfill another organization's reward redemption" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          @ledger.award(outsider, 600, reason: "proposal")
          Decidim::Bih::Goodwill::RedeemReward.call(outsider, "majica")
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last

          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::RewardFulfillmentEvent.count" do
            post "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/fulfilled"
          end

          assert_response :redirect
          assert_equal "requested", fulfillment.reload.status
          assert_nil fulfillment.handled_by_id
          assert_equal 100, @ledger.account_for(outsider).balance
        end

        test "direct status update cannot reverse a reward redemption without ledger reversal" do
          @ledger.award(@citizen, 600, reason: "proposal")
          Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last

          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::RewardFulfillmentEvent.count" do
            assert_no_difference "Decidim::Bih::Goodwill::Transaction.count" do
              post "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/reversed"
            end
          end

          assert_response :redirect
          assert_equal "requested", fulfillment.reload.status
          assert_not Decidim::Bih::Goodwill::Transaction
            .exists?(organization: @organization, idempotency_key: "reversal_of:#{fulfillment.ledger_transaction.id}")
        end

        test "canceling a reward fulfillment refunds points through a ledger reversal" do
          @ledger.award(@citizen, 600, reason: "proposal")
          Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last
          assert_equal 100, @ledger.account_for(@citizen).balance

          sign_in @admin
          assert_difference -> { fulfillment.events.where(event_type: "canceled").count }, 1 do
            post "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/canceled",
                 params: { private_reason: "Nagrada nije dostupna za preuzimanje" }
          end

          assert_response :redirect
          assert_equal "canceled", fulfillment.reload.status
          assert_equal 600, @ledger.account_for(@citizen).balance
          assert Decidim::Bih::Goodwill::Transaction
            .exists?(organization: @organization, idempotency_key: "reversal_of:#{fulfillment.ledger_transaction.id}")

          event = fulfillment.events.where(event_type: "canceled").last
          assert_equal "single", event.metadata["action"]
          assert event.metadata["reversal_transaction_id"].present?
        end

        test "reversing a redemption marks its fulfillment as reversed" do
          @ledger.award(@citizen, 600, reason: "proposal")
          Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last
          fulfillment.mark!("fulfilled", by: @admin)

          sign_in @admin
          assert_difference -> { fulfillment.events.where(event_type: "reversed").count }, 1 do
            post "/admin/bih/goodwill/transaction/#{fulfillment.ledger_transaction.id}/reverse",
                 params: { private_reason: "Ispravka realizacije nagrade" }
          end

          assert_response :redirect
          assert_equal "reversed", fulfillment.reload.status

          event = fulfillment.events.where(event_type: "reversed").last
          assert_equal "ledger_reverse", event.metadata["action"]
          assert event.metadata["reversal_transaction_id"].present?
        end

        test "reversing the same transaction twice cannot double-debit (B1)" do
          txn = @ledger.award(@citizen, 30, reason: "proposal")
          sign_in @admin

          post "/admin/bih/goodwill/transaction/#{txn.id}/reverse",
               params: { private_reason: "Prva ispravka" }
          assert_equal 0, @ledger.account_for(@citizen).balance

          # A second click must be a no-op, not another -30 mirror debit.
          post "/admin/bih/goodwill/transaction/#{txn.id}/reverse",
               params: { private_reason: "Ponovljena ispravka" }
          assert_response :redirect
          assert_equal 0, @ledger.account_for(@citizen).balance # still 0, not -30
        end

        test "a non-admin cannot reverse a transaction" do
          txn = @ledger.award(@citizen, 30, reason: "proposal")
          sign_in @citizen
          post "/admin/bih/goodwill/transaction/#{txn.id}/reverse"

          # Denied by the admin-area gate (redirect), and crucially no reversal
          # was posted — the balance is untouched.
          assert_response :redirect
          assert_equal 30, @ledger.account_for(@citizen).balance
        end

        # Fix 3: double-submit on "fulfilled" must not fire a second notification
        test "double-submit on fulfill does not fire a second notification" do
          @ledger.award(@citizen, 600, reason: "proposal")
          Decidim::Bih::Goodwill::RedeemReward.call(@citizen, "majica")
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.last

          notification_count = 0
          allow_any_stub = lambda do |event:, **|
            notification_count += 1 if event == "decidim.events.bih.goodwill.reward_fulfilled"
          end

          sign_in @admin
          # Stub at the EventsManager level to count publish calls
          Decidim::EventsManager.stub(:publish, allow_any_stub) do
            post "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/fulfilled"
            assert_equal "fulfilled", fulfillment.reload.status

            # Second identical POST — mark! returns false, no notification
            post "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/fulfilled"
          end

          assert_equal 1, notification_count, "Expected exactly 1 fulfillment notification"
          assert_equal 1, fulfillment.events.where(event_type: "fulfilled").count
        end

        # Fix 6: approve/reject match request notifies the owner
        test "approving a match request notifies the owner" do
          group = FactoryBot.create(:user, :confirmed,
                                    organization: @organization,
                                    extended_data: { "group" => true })
          group.update!(name: "Udruženje A", nickname: "udruzenje_a")
          req = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: group, points: 50,
            status: "pending", created_by: @admin
          )

          notifications_published = []
          sign_in @admin
          Decidim::EventsManager.stub(:publish, ->(event:, **) { notifications_published << event }) do
            post "/admin/bih/goodwill/match-request/#{req.id}/decide", params: { decision: "approved" }
          end

          assert_equal "approved", req.reload.status
          assert_includes notifications_published, "decidim.events.bih.goodwill.match_request_decided"
        end

        test "rejecting a match request notifies the owner" do
          group = FactoryBot.create(:user, :confirmed,
                                    organization: @organization,
                                    extended_data: { "group" => true })
          group.update!(name: "Udruženje B", nickname: "udruzenje_b")
          req = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: group, points: 30,
            status: "pending", created_by: @admin
          )

          notifications_published = []
          sign_in @admin
          Decidim::EventsManager.stub(:publish, ->(event:, **) { notifications_published << event }) do
            post "/admin/bih/goodwill/match-request/#{req.id}/decide", params: { decision: "rejected" }
          end

          assert_equal "rejected", req.reload.status
          assert_includes notifications_published, "decidim.events.bih.goodwill.match_request_decided"
        end

        test "deciding an already-decided request fires no notification" do
          group = FactoryBot.create(:user, :confirmed,
                                    organization: @organization,
                                    extended_data: { "group" => true })
          group.update!(name: "Udruženje C", nickname: "udruzenje_c")
          req = Decidim::Bih::Goodwill::MatchRequest.create!(
            organization: @organization, owner: group, points: 20,
            status: "approved", created_by: @admin, decided_by: @admin,
            decided_at: Time.current
          )

          notifications_published = []
          sign_in @admin
          Decidim::EventsManager.stub(:publish, ->(event:, **) { notifications_published << event }) do
            post "/admin/bih/goodwill/match-request/#{req.id}/decide", params: { decision: "approved" }
          end

          assert_not_includes notifications_published, "decidim.events.bih.goodwill.match_request_decided"
        end

        private

        def with_forgery_protection
          previous = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          yield
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end

        def create_reward!(key, title, cost:, stock:)
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key:,
            cost:,
            stock:,
            active: true,
            title: { "sr" => title, "en" => title }
          )
        end

        def create_reward_fulfillment!(reward_key:, cost:, status:, user: @citizen)
          @ledger.award(user, cost, reason: "seed")
          txn = @ledger.spend(owner: user, amount: cost, kind: "redeem", reason: "reward:#{reward_key}")
          Decidim::Bih::Goodwill::RewardFulfillment.create!(
            organization: @organization,
            ledger_transaction: txn,
            user:,
            reward_key:,
            cost:,
            status:,
            handled_by: (%w(fulfilled canceled reversed).include?(status) ? @admin : nil),
            handled_at: (%w(fulfilled canceled reversed).include?(status) ? Time.current : nil)
          )
        end

        def create_volunteer_partner_profile!(organization:, slug:)
          PartnerProfile.create!(
            organization:,
            display_name: slug.tr("-", " ").titleize,
            slug:,
            kind: "association",
            verification_status: "verified",
            verified_at: Time.current
          )
        end
      end
    end
  end
end
