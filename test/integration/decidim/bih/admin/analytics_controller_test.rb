# frozen_string_literal: true

require "test_helper"
require "capybara"
require "csv"
require "securerandom"

module Decidim
  module Bih
    module Admin
      class AnalyticsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        FakeDonationTotals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride
        FakeDonationProvider = Struct.new(:totals, :currency_label, :project_mappings, keyword_init: true)

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @original_donations_provider = Decidim::Bih.donations_provider
          Decidim::Bih.donations_provider = fake_donations_provider
          @komsiluk = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "analytics-k",
            name: { "sr" => "Analitika K" }
          )
          create_analytics_data!
        end

        teardown do
          Decidim::Bih.donations_provider = @original_donations_provider
        end

        test "admin can view the analytics page" do
          Decidim::Bih::ConciergeFeedback.create!(
            organization: @organization,
            reply_id: "12121212-1212-4212-8212-121212121212",
            session_digest: "request-panel-private-session",
            value: "not_helpful",
            locale: "sr",
            citizen_message: "Private panel prompt",
            bot_reply_text: "Private panel reply",
            metadata: {
              "outcome" => "fallback",
              "answer_intent" => "fallback",
              "reply_length" => 45,
              "quick_replies_count" => 1,
              "raw_message" => "Private panel prompt",
              "raw_reply" => "Private panel reply",
              "token" => "request-panel-private-token"
            }
          )

          sign_in @admin
          get "/admin/bih/analytics"

          assert_response :success
          assert_includes response.body, "LFBN"
          assert_includes response.body, "admin-analytics-workflow-nav"
          assert_select "#admin-analytics-header[data-analytics-active-tab='exports']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=exports'][aria-current='page']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=mi_bot_review']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=examples']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=trends']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=previews']"
          assert_select "#admin-analytics-exports"
          assert_select "#admin-mi-bot-answer-review", count: 0
          assert_select "#admin-mi-bot-review-comparison", count: 0
          assert_select "#admin-mi-bot-feedback-examples", count: 0
          assert_select "#admin-analytics-preview", count: 0
          assert_includes response.body, "donations"
          assert_includes response.body, "reports"
          assert_includes response.body, "report_triage"
          assert_includes response.body, "goodwill"
          assert_includes response.body, "reward_fulfillment_review"
          assert_includes response.body, "onboarding"
          assert_includes response.body, "volunteering"
          assert_includes response.body, "komsiluk"
          assert_includes response.body, "komsiluk_activity_review"
          assert_includes response.body, "mi_bot_usage"
          assert_includes response.body, "mi_bot_feedback"
          assert_includes response.body, "mi_bot_review"
          assert_includes response.body, "mi_bot_review_comparison"
          assert_includes response.body, "trends"
          assert_includes response.body, "/admin/bih/analytics/export/donations.csv"
          assert_includes response.body, "/admin/bih/analytics/export/reports.csv"
          assert_includes response.body, "/admin/bih/analytics/export/report_triage.csv"
          assert_includes response.body, "/admin/bih/analytics/export/reward_fulfillment_review.csv"
          assert_includes response.body, "/admin/bih/analytics/export/onboarding.csv"
          assert_includes response.body, "/admin/bih/analytics/export/komsiluk_activity_review.csv"
          assert_includes response.body, "/admin/bih/analytics/export/mi_bot_usage.csv"
          assert_includes response.body, "/admin/bih/analytics/export/mi_bot_feedback.csv"
          assert_includes response.body, "/admin/bih/analytics/export/mi_bot_review.csv"
          assert_includes response.body, "/admin/bih/analytics/export/mi_bot_review_comparison.csv"
          assert_includes response.body, "/admin/bih/analytics/export/trends.csv"
          assert_not_includes response.body, "request-panel-private-session"
          assert_not_includes response.body, "request-panel-private-token"
          assert_not_includes response.body, "12121212-1212-4212-8212-121212121212"
          assert_not_includes response.body, "Private panel prompt"
          assert_not_includes response.body, "Private panel reply"
          assert_not_includes response.body, @citizen.email
          assert_not_includes response.body, @citizen.name
        end

        test "admin analytics workflow tabs render one focused panel at a time" do
          Decidim::Bih::ConciergeFeedback.create!(
            organization: @organization,
            reply_id: "12121212-1212-4212-8212-121212121212",
            session_digest: "workflow-panel-private-session",
            value: "not_helpful",
            locale: "sr",
            citizen_message: "Workflow panel prompt",
            bot_reply_text: "Workflow panel reply",
            metadata: {
              "outcome" => "fallback",
              "answer_intent" => "fallback",
              "reply_length" => 45,
              "quick_replies_count" => 1,
              "raw_message" => "Workflow panel prompt",
              "raw_reply" => "Workflow panel reply",
              "token" => "workflow-panel-private-token"
            }
          )

          sign_in @admin

          get "/admin/bih/analytics", params: { tab: "mi_bot_review" }
          assert_response :success
          assert_select "#admin-analytics-header[data-analytics-active-tab='mi_bot_review']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=mi_bot_review'][aria-current='page']"
          assert_select "#admin-mi-bot-answer-review"
          assert_select "#admin-analytics-exports", count: 0
          assert_select "#admin-mi-bot-feedback-examples", count: 0
          assert_includes response.body, "/admin/bih/analytics/export/mi_bot_review.csv"
          assert_not_includes response.body, "workflow-panel-private-session"
          assert_not_includes response.body, "workflow-panel-private-token"

          get "/admin/bih/analytics", params: { tab: "examples" }
          assert_response :success
          assert_select "#admin-analytics-header[data-analytics-active-tab='examples']"
          assert_select "#admin-mi-bot-feedback-examples"
          assert_select "#admin-mi-bot-answer-review", count: 0
          assert_includes response.body, "Workflow panel prompt"
          assert_includes response.body, "Workflow panel reply"

          get "/admin/bih/analytics", params: { tab: "trends" }
          assert_response :success
          assert_select "#admin-analytics-header[data-analytics-active-tab='trends']"
          assert_select "#admin-mi-bot-review-comparison"
          assert_includes response.body, "/admin/bih/analytics/export/mi_bot_review_comparison.csv"

          get "/admin/bih/analytics", params: { tab: "previews" }
          assert_response :success
          assert_select "#admin-analytics-header[data-analytics-active-tab='previews']"
          assert_select "#admin-analytics-preview"
          assert_includes response.body, "Trendovi 30 dana"

          get "/admin/bih/analytics", params: { tab: "unknown" }
          assert_response :success
          assert_select "#admin-analytics-header[data-analytics-active-tab='exports']"
          assert_select "#admin-analytics-exports"
        end

        test "non-admin is denied analytics access" do
          sign_in @citizen
          get "/admin/bih/analytics"

          assert_response :redirect
        end

        test "analytics operator can review aggregate tabs but not clicked examples" do
          analytics_operator = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::OperatorRole.create!(
            organization: @organization,
            user: analytics_operator,
            role: "analytics_viewer",
            created_by: @admin,
            expires_at: 30.days.from_now
          )

          sign_in analytics_operator
          get "/admin/bih/analytics"

          assert_response :success
          assert_select "#admin-analytics-header[data-analytics-active-tab='exports']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=mi_bot_review']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=examples']", count: 0
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=trends']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=previews']"
          assert_select "#admin-mi-bot-feedback-examples", count: 0

          get "/admin/bih/analytics", params: { tab: "mi_bot_review" }
          assert_response :success
          assert_select "#admin-analytics-header[data-analytics-active-tab='mi_bot_review']"
          assert_select "#admin-mi-bot-answer-review"
          assert_select "#admin-mi-bot-feedback-examples", count: 0

          get "/admin/bih/analytics", params: { tab: "examples" }
          assert_response :redirect
          assert_equal "http://#{@organization.host}/admin/", response.location
        end

        test "report export is aggregate and does not expose report PII" do
          sign_in @admin
          get "/admin/bih/analytics/export/reports.csv"

          assert_response :success
          assert_equal "text/csv", response.media_type
          parsed = CSV.parse(response.body, headers: true)
          assert_equal "mz-centar", parsed.first["mz_slug"]
          assert_equal "putevi", parsed.first["category"]
          assert_equal "1", parsed.first["count"]
          assert_no_private_values(response.body)
        end

        test "report triage export is aggregate and does not expose report PII" do
          old_report = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private request report triage body",
            address: "Private request report triage address",
            reporter_email: "request-triage@example.org",
            created_at: 3.days.ago,
            updated_at: 3.days.ago
          )

          sign_in @admin
          get "/admin/bih/analytics/export/report_triage.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("report_triage"), parsed.headers
          received = parsed.find { |row| row["bucket"] == "received_over_sla" }
          assert_equal "1", received["count"]
          assert_equal "high", received["review_priority"]
          assert_equal "forward_received_report", received["review_action"]
          assert_equal "2", received["forwarding_sla_days"]
          assert_equal Decidim::Bih::Report::STALE_DAYS.to_s, received["stale_days"]
          assert_no_private_values(response.body)
          assert_not_includes response.body, "Private request report triage"
          assert_not_includes response.body, "request-triage@example.org"
          assert_not_includes response.body, old_report.reference
        end

        test "goodwill export includes only aggregate point movement" do
          sign_in @admin
          get "/admin/bih/analytics/export/goodwill.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          earn = parsed.find { |row| row["kind"] == "earn" }
          assert_equal "1", earn["transactions_count"]
          assert_equal "30", earn["positive_points"]
          assert_equal "30", earn["negative_points"]
          assert_no_private_values(response.body)
        end

        test "reward fulfillment review export is aggregate and organization scoped" do
          now = Time.zone.local(2026, 6, 18, 12, 0, 0)
          travel_to now do
            create_reward!("review_formula_reward", "=Formula review reward", cost: 40, stock: 1, expires_at: now + 5.days)
            fulfillment = create_reward_fulfillment!(
              reward_key: "review_formula_reward",
              cost: 40,
              status: "requested",
              notes: "Private request reward pickup note",
              reward_expires_at: now - 1.day,
              created_at: now - 3.days,
              updated_at: now - 3.days
            )
            fulfillment.record_event!(
              "requested",
              source: "public",
              metadata: {
                reward_key: "review_formula_reward",
                note: "Private request event note",
                phone: "+387 65 777 999"
              }
            )
            create_reward_fulfillment!(
              reward_key: "review_canceled_reward",
              cost: 20,
              status: "canceled",
              created_at: now - 5.days,
              updated_at: now - 1.day,
              handled_at: now - 1.day
            )

            other_org = create_organization
            other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
            create_reward_fulfillment!(
              organization: other_org,
              user: other_user,
              reward_key: "other_private_review_reward",
              cost: 15,
              status: "requested"
            )
          end

          sign_in @admin
          get "/admin/bih/analytics/export/reward_fulfillment_review.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("reward_fulfillment_review"), parsed.headers
          formula = parsed.find { |row| row["reward_key"] == "review_formula_reward" }
          canceled = parsed.find { |row| row["reward_key"] == "review_canceled_reward" }
          assert_equal "'=Formula review reward", formula["reward_name"]
          assert_equal "high", formula["review_priority"]
          assert_equal "check_expired_open_requests", formula["review_action"]
          assert_equal "1", formula["open_count"]
          assert_equal "1", formula["expired_open_count"]
          assert_equal "1", formula["events_count"]
          assert_equal "requested", formula["latest_event_type"]
          assert_equal "watch", canceled["review_priority"]
          assert_equal "review_recent_cancellations", canceled["review_action"]
          assert_not_includes response.body, "other_private_review_reward"
          assert_not_includes response.body, "Private request"
          assert_not_includes response.body, "+387 65 777 999"
          assert_no_private_values(response.body)
        end

        test "donations export includes aggregate totals without donor fields" do
          sign_in @admin
          get "/admin/bih/analytics/export/donations.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          general = parsed.find { |row| row["scope"] == "general" }
          project = parsed.find { |row| row["scope"] == "project" }
          assert_equal "825.0", general["total_amount"]
          assert_equal "6", general["donation_orders_count"]
          assert_equal "99", project["decidim_project_id"]
          assert_equal "campaign-safe", project["campaign"]
          assert_no_private_values(response.body)
        end

        test "onboarding export summarizes the setup funnel without user identity" do
          other_org = create_organization
          other_user = FactoryBot.create(
            :user,
            :confirmed,
            organization: other_org,
            name: "Private onboarding outsider",
            email: "private-onboarding@example.org"
          )
          Decidim::Authorization.create!(
            user: other_user,
            name: "sms",
            unique_id: "private-onboarding-sms",
            granted_at: Time.current,
            verification_metadata: {}
          )

          sign_in @admin
          get "/admin/bih/analytics/export/onboarding.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("onboarding"), parsed.headers
          rows = parsed.map { |row| [row["metric"], row["status"], row["count"]] }
          assert_includes rows, %w(registrations created 2)
          assert_includes rows, %w(registrations email_confirmed 2)
          assert_includes rows, %w(verification sms_granted 1)
          assert_includes rows, %w(verification postal_granted 1)
          assert_includes rows, %w(localization komsiluk_assigned 1)
          assert_includes rows, %w(messaging viber_linked 1)
          assert_includes rows, %w(first_action submitted_report 1)
          assert_includes rows, %w(first_action volunteer_signup 1)
          assert_includes rows, %w(first_action volunteer_availability 1)
          assert_includes rows, %w(first_action reward_requested 1)
          assert_not_includes response.body, "Private onboarding outsider"
          assert_not_includes response.body, "private-onboarding@example.org"
          assert_not_includes response.body, "private-onboarding-sms"
          assert_no_private_values(response.body)
        end

        test "mi bot feedback export is aggregate and does not expose conversation data" do
          Decidim::Bih::ConciergeFeedback.create!(
            organization: create_organization,
            reply_id: "77777777-7777-4777-8777-777777777777",
            session_digest: "request-other-org-session",
            value: "helpful",
            locale: "sr",
            metadata: {
              "outcome" => "request-other-org-outcome",
              "answer_intent" => "request-other-org-private-intent",
              "reply_length" => 500,
              "quick_replies_count" => 5
            }
          )

          sign_in @admin
          get "/admin/bih/analytics/export/mi_bot_feedback.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("mi_bot_feedback"), parsed.headers
          row = parsed.find do |candidate|
            candidate["rating"] == "helpful" && candidate["outcome"] == "success" &&
              candidate["answer_intent"] == "waste"
          end
          assert_equal "1", row["count"]
          assert_equal "waste", row["answer_intent"]
          assert_equal "42.0", row["average_reply_length"]
          assert_equal "2.0", row["average_quick_replies_count"]
          assert_not_includes response.body, "request-other-org"
          assert_no_private_values(response.body)
        end

        test "mi bot usage export is aggregate and does not expose conversation data" do
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: create_organization,
            bucket_on: Date.current,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            requests_count: 99,
            message_length_total: 999,
            reply_length_total: 999,
            quick_replies_total: 99
          )

          sign_in @admin
          get "/admin/bih/analytics/export/mi_bot_usage.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("mi_bot_usage"), parsed.headers
          row = parsed.find { |candidate| candidate["channel"] == "web_chat" && candidate["answer_intent"] == "waste" }
          assert_equal "2", row["count"]
          assert_equal "32.0", row["average_message_length"]
          assert_equal "96.0", row["average_reply_length"]
          assert_equal "1.5", row["average_quick_replies_count"]
          assert_equal "1", row["sticker_count"]
          assert_no_private_values(response.body)
          assert_not_includes response.body, "999"
        end

        test "mi bot review export prioritizes answer-quality buckets without conversation data" do
          Decidim::Bih::ConciergeFeedback.create!(
            organization: @organization,
            user: @citizen,
            reply_id: "99999999-9999-4999-8999-999999999999",
            session_digest: "request-private-review-session",
            value: "not_helpful",
            locale: "sr",
            metadata: {
              "outcome" => "success",
              "answer_intent" => "waste",
              "reply_length" => 84,
              "quick_replies_count" => 1,
              "raw_message" => "Private request review prompt",
              "raw_reply" => "Private request review answer",
              "token" => "request-private-review-token"
            }
          )
          Decidim::Bih::ConciergeFeedback.create!(
            organization: @organization,
            reply_id: "aaaaaaaa-1111-4aaa-8aaa-111111111111",
            session_digest: "request-private-fallback-session",
            value: "not_helpful",
            locale: "en",
            metadata: {
              "outcome" => "fallback",
              "answer_intent" => "fallback",
              "reply_length" => 30,
              "quick_replies_count" => 4
            }
          )

          sign_in @admin
          get "/admin/bih/analytics/export/mi_bot_review.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("mi_bot_review"), parsed.headers
          fallback = parsed.find do |row|
            row["outcome"] == "fallback" && row["answer_intent"] == "fallback" && row["locale"] == "en"
          end
          success = parsed.find do |row|
            row["outcome"] == "success" && row["answer_intent"] == "waste" && row["locale"] == "sr"
          end
          assert_equal "high", fallback["review_priority"]
          assert_equal "check_resolver_and_city_data", fallback["review_action"]
          assert_equal "2", success["feedback_count"]
          assert_equal "waste", success["answer_intent"]
          assert_equal "1", success["not_helpful_count"]
          assert_equal "50.0", success["not_helpful_rate"]
          assert_equal "sample_common_intents", success["review_action"]
          assert_no_private_values(response.body)
          assert_not_includes response.body, "Private request review"
          assert_not_includes response.body, "request-private-review-session"
          assert_not_includes response.body, "request-private-review-token"
          assert_not_includes response.body, "99999999-9999-4999-8999-999999999999"
        end

        test "mi bot review comparison export compares same buckets without conversation data" do
          previous_at = 45.days.ago
          current_at = 5.days.ago
          2.times do
            Decidim::Bih::ConciergeFeedback.create!(
              organization: @organization,
              user: @citizen,
              reply_id: SecureRandom.uuid,
              session_digest: "request-private-comparison-previous-session",
              value: "not_helpful",
              locale: "sr",
              citizen_message: "Private request previous comparison prompt",
              bot_reply_text: "Private request previous comparison answer",
              created_at: previous_at,
              updated_at: previous_at,
              metadata: {
                "outcome" => "success",
                "answer_intent" => "location_transit",
                "raw_message" => "Private request previous comparison prompt"
              }
            )
          end
          Decidim::Bih::ConciergeFeedback.create!(
            organization: @organization,
            user: @citizen,
            reply_id: SecureRandom.uuid,
            session_digest: "request-private-comparison-current-session",
            value: "not_helpful",
            locale: "sr",
            citizen_message: "Private request current comparison prompt",
            bot_reply_text: "Private request current comparison answer",
            created_at: current_at,
            updated_at: current_at,
            metadata: {
              "outcome" => "success",
              "answer_intent" => "location_transit",
              "raw_reply" => "Private request current comparison answer"
            }
          )

          sign_in @admin
          get "/admin/bih/analytics/export/mi_bot_review_comparison.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("mi_bot_review_comparison"), parsed.headers
          row = parsed.find { |candidate| candidate["answer_intent"] == "location_transit" }
          assert_equal "1", row["current_not_helpful_count"]
          assert_equal "2", row["previous_not_helpful_count"]
          assert_equal "-1", row["change_value"]
          assert_equal "'-50.0", row["change_percent"]
          assert_equal "true", row["decreased"]
          assert_no_private_values(response.body)
          assert_not_includes response.body, "Private request"
          assert_not_includes response.body, "request-private-comparison"
        end

        test "trends export compares aggregate activity windows without PII" do
          sign_in @admin
          get "/admin/bih/analytics/export/trends.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("trends"), parsed.headers
          report_row = parsed.find { |row| row["metric"] == "reports_created" }
          feedback_row = parsed.find { |row| row["metric"] == "mi_bot_feedback" }
          assert_equal "1", report_row["current_value"]
          assert_equal "1", feedback_row["current_value"]
          assert_equal "30", report_row["window_days"]
          assert_no_private_values(response.body)
        end

        test "komsiluk export is organization scoped" do
          other_org = create_organization
          other_area = Decidim::Bih::LocalArea.create!(
            organization: other_org,
            kind: "komsiluk",
            slug: "other-analytics-k",
            name: { "sr" => "Other analytics" }
          )
          other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
          Decidim::Bih::KomsilukPost.create!(
            organization: other_org,
            author: other_user,
            komsiluk: other_area,
            category: "general",
            title: "Other private title",
            body: "Other private body"
          )

          sign_in @admin
          get "/admin/bih/analytics/export/komsiluk.csv"

          assert_response :success
          assert_includes response.body, "analytics-k"
          assert_not_includes response.body, "other-analytics-k"
          assert_not_includes response.body, "Other private"
        end

        test "komsiluk activity review export is aggregate and organization scoped" do
          other_org = create_organization
          other_area = Decidim::Bih::LocalArea.create!(
            organization: other_org,
            kind: "komsiluk",
            slug: "other-activity-review-k",
            name: { "sr" => "Other activity review" }
          )
          other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
          Decidim::Bih::KomsilukPost.create!(
            organization: other_org,
            author: other_user,
            komsiluk: other_area,
            category: "safety",
            title: "Other activity review title",
            body: "Other activity review body",
            flagged_count: 5
          )

          sign_in @admin
          get "/admin/bih/analytics/export/komsiluk_activity_review.csv"

          assert_response :success
          parsed = CSV.parse(response.body, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("komsiluk_activity_review"), parsed.headers
          row = parsed.find { |candidate| candidate["area_slug"] == "analytics-k" }
          assert_equal "watch", row["review_priority"]
          assert_equal "review_moderation_queue", row["review_action"]
          assert_equal "1", row["posts_count"]
          assert_equal "1", row["flagged_posts_count"]
          assert_equal "1", row["total_flags"]
          assert_equal "1", row["broadcasts_count"]
          assert_equal "1", row["viber_broadcasts_count"]
          assert_equal "5", row["total_recipients"]
          assert_not_includes response.body, "other-activity-review-k"
          assert_not_includes response.body, "Other activity review"
          assert_no_private_values(response.body)
        end

        test "unknown export redirects without raising" do
          sign_in @admin
          get "/admin/bih/analytics/export/unknown.csv"

          assert_response :redirect
          assert_redirected_to "/admin/bih/analytics"
        end

        test "chat health tab renders resolution counters, inbound receipts and unknown markers" do
          require "sidekiq/api"
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: @organization, bucket_on: Date.current, channel: "web_chat", outcome: "success",
            answer_intent: "budget", locale: "sr", requests_count: 4,
            resolution_answered_count: 3, resolution_clarification_count: 1
          )
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: @organization, bucket_on: Date.current, channel: "viber_bm", outcome: "fallback",
            answer_intent: "fallback", locale: "sr", requests_count: 2
          )
          Decidim::Bih::Viber::InboundDelivery.create!(
            organization: @organization, channel: "whatsapp", state: "processed", phase: "complete",
            provider_message_key: SecureRandom.hex(32), received_at: 1.hour.ago, expires_at: 6.days.from_now
          )
          unknown = I18n.t("decidim.bih.admin.analytics.chat_health.unknown", locale: :sr)

          sign_in @admin
          Sidekiq::DeadSet.stub(:new, ->(*) { raise IOError, "redis down" }) do
            get "/admin/bih/analytics", params: { tab: "chat_health" }
          end

          assert_response :success
          assert_select "#admin-analytics-header[data-analytics-active-tab='chat_health']"
          assert_select "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=chat_health'][aria-current='page']"
          assert_select "#admin-chat-health[data-chat-health-period='7']"
          assert_select "#admin-analytics-exports", count: 0
          assert_select "h2", text: I18n.t("decidim.bih.admin.analytics.chat_health.title", locale: :sr)

          assert_select "[data-chat-health-resolution='answered'] strong", text: "3"
          assert_select "[data-chat-health-resolution='clarification'] strong", text: "1"
          assert_select "[data-chat-health-resolution='handoff'] strong", text: "0"
          assert_select "[data-chat-health-resolution='provider_unavailable'] [data-chat-health-unknown]", text: unknown
          assert_select "[data-chat-health-resolution='busy'] [data-chat-health-unknown]", text: unknown
          assert_select "[data-chat-health-failure='fallback'] strong", text: "2"
          assert_select "[data-chat-health-failure='error'] strong", text: "0"

          assert_select "[data-chat-health-channel='whatsapp'] td", text: "1"
          assert_select "[data-chat-health-channel='web_chat'] [data-chat-health-unknown]", minimum: 1
          assert_select "[data-chat-health-channel='viber_bm'] td", text: "0"
          assert_select "[data-chat-health-channel='viber_bm'] [data-chat-health-unknown]", text: unknown

          assert_select "[data-chat-health-sends='dead'] [data-chat-health-unknown]", text: unknown
          assert_select "[data-chat-health-sends='retrying'] [data-chat-health-unknown]", text: unknown
          assert_select "[data-chat-health-sends-unavailable]"

          assert_select "[data-chat-health-rollup-empty]"
          assert_select "[data-chat-health-rollup-day]", count: 0
          assert_select "[data-chat-health-latency-empty]"
          assert_select "[data-chat-health-stamp='release_sha'] [data-chat-health-unknown]", text: unknown
          assert_select "[data-chat-health-stamp='prompt_version'] [data-chat-health-unknown]", text: unknown
          assert_no_private_values(response.body)
        end

        test "chat health tab reads the rollup table and bounds the period switch" do
          require "sidekiq/api"
          Decidim::Bih::ConciergeMetricRollup.create!(
            organization: @organization, day: Date.current, kind: "answer", topic: "water", label: "answered", count: 8,
            release_sha: "c" * 40, prompt_version: 1
          )
          Decidim::Bih::ConciergeMetricRollup.create!(
            organization: @organization, day: Date.current, kind: "answer", topic: "water", label: "busy", count: 2,
            release_sha: "c" * 40, prompt_version: 1
          )
          Decidim::Bih::ConciergeMetricRollup.create!(
            organization: @organization, day: Date.current, kind: "stage", topic: "understanding", label: "completed",
            latency_bucket: "500", count: 4, release_sha: "c" * 40, prompt_version: 1
          )
          analytics_operator = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::OperatorRole.create!(
            organization: @organization, user: analytics_operator, role: "analytics_viewer",
            created_by: @admin, expires_at: 30.days.from_now
          )
          empty_set = Struct.new(:jobs) { def scan(_match) = jobs }.new([])

          sign_in analytics_operator
          Sidekiq::DeadSet.stub(:new, empty_set) do
            Sidekiq::RetrySet.stub(:new, empty_set) do
              get "/admin/bih/analytics", params: { tab: "chat_health", period: "30" }
            end
          end

          assert_response :success
          assert_select "#admin-chat-health[data-chat-health-period='30']"
          assert_select "#admin-chat-health-period a[aria-current='page'][data-chat-health-period-link='30']"
          assert_select "[data-chat-health-rollup-day='#{Date.current.iso8601}'] td", text: "20.0 %"
          assert_select "[data-chat-health-latency-bucket='500'] td", text: "4"
          assert_select "[data-chat-health-latency-p95]", text: "500"
          assert_select "[data-chat-health-stamp='release_sha'] code", text: "c" * 40
          assert_select "[data-chat-health-sends='dead'] strong", text: "0"
          assert_select "[data-chat-health-sends-unavailable]", count: 0

          Sidekiq::DeadSet.stub(:new, empty_set) do
            Sidekiq::RetrySet.stub(:new, empty_set) do
              get "/admin/bih/analytics", params: { tab: "chat_health", period: "999" }
            end
          end
          assert_response :success
          assert_select "#admin-chat-health[data-chat-health-period='7']"

          sign_in @citizen
          get "/admin/bih/analytics", params: { tab: "chat_health" }
          assert_response :redirect
        end

        private

        def fake_donations_provider
          FakeDonationProvider.new(
            totals: FakeDonationTotals.new(
              total: BigDecimal("825"),
              count: 6,
              currency: "BAM",
              as_of: Time.zone.local(2026, 2, 3, 4, 5, 6)
            ),
            currency_label: "KM",
            project_mappings: [
              {
                decidim_project_id: 99,
                title: "Safe project",
                campaign: "campaign-safe",
                donor_email: "donor-secret@example.org",
                payout_reference: "BANK-PRIVATE-123",
                totals: FakeDonationTotals.new(
                  total: BigDecimal("225"),
                  count: 2,
                  currency: "BAM",
                  as_of: Time.zone.local(2026, 2, 4, 5, 6, 7)
                )
              }
            ]
          )
        end

        def create_analytics_data!
          @citizen.update!(notification_types: "none")
          Decidim::Authorization.create!(
            user: @citizen,
            name: "sms",
            unique_id: "analytics-onboarding-sms",
            granted_at: Time.current,
            verification_metadata: {}
          )
          Decidim::Authorization.create!(
            user: @citizen,
            name: "postal_letter",
            granted_at: Time.current,
            verification_metadata: {}
          )
          Decidim::Bih::CitizenProfile
            .for_user(@citizen, organization: @organization)
            .assign_komsiluk!(@komsiluk, source: "dropdown")
          Decidim::Bih::Viber::Linkage.create!(
            organization: @organization,
            user: @citizen,
            viber_sender: "analytics-onboarding-viber",
            verified_at: Time.current
          )
          Decidim::Bih::Report.create!(
            organization: @organization,
            author: @citizen,
            description: "Private report body",
            address: "Private report address",
            reporter_email: "private@example.org",
            reporter_phone: "+387 65 999 888",
            category: "putevi",
            severity: "visok",
            mz_slug: "mz-centar"
          )
          Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 30, reason: "report")
          create_reward_fulfillment!(reward_key: "analytics_reward", cost: 20, status: "reserved", seed_points: false)
          opportunity = Decidim::Bih::VolunteerOpportunity.create!(
            organization: @organization,
            author: @citizen,
            title: "Private opportunity title",
            active: true,
            review_status: "approved"
          )
          create_legacy_volunteer_log!(
            organization: @organization,
            opportunity:,
            user: @citizen,
            hours: 2,
            status: "approved"
          )
          Decidim::Bih::VolunteerSignup.create!(
            organization: @organization,
            opportunity:,
            user: @citizen,
            status: "going",
            review_status: "automatic",
            review_source: "automatic",
            reviewed_at: Time.current
          )
          Decidim::Bih::VolunteerAvailability.create!(
            organization: @organization,
            user: @citizen,
            availability: "Private availability",
            interests: "Private interests"
          )
          Decidim::Bih::KomsilukPost.create!(
            organization: @organization,
            author: @citizen,
            komsiluk: @komsiluk,
            category: "general",
            title: "Private komsiluk title",
            body: "Private komsiluk body",
            flagged_count: 1
          )
          Decidim::Bih::Broadcast.create!(
            organization: @organization,
            area: @komsiluk,
            sent_by: @admin,
            message: "Private broadcast content",
            channels: "bell,viber",
            recipients_count: 5
          )
          Decidim::Bih::ConciergeFeedback.create!(
            organization: @organization,
            user: @citizen,
            reply_id: "66666666-6666-4666-8666-666666666666",
            session_digest: "request-private-session-digest",
            value: "helpful",
            locale: "sr",
            metadata: {
              "outcome" => "success",
              "answer_intent" => "waste",
              "reply_length" => 42,
              "quick_replies_count" => 2,
              "raw_message" => "Private request bot prompt",
              "raw_reply" => "Private request bot answer",
              "token" => "request-private-token",
              "viber_sender" => "request-private-viber-sender"
            }
          )
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: @organization,
            bucket_on: Date.current,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            requests_count: 2,
            message_length_total: 64,
            reply_length_total: 192,
            quick_replies_total: 3,
            sticker_count: 1
          )
        end

        def create_reward!(key, title, cost:, stock: nil, expires_at: nil)
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key:,
            title: { "sr" => title },
            cost:,
            stock:,
            expires_at:,
            active: true
          )
        end

        def create_reward_fulfillment!(organization: @organization, user: @citizen, seed_points: true, **attributes)
          ledger = Decidim::Bih::Goodwill::Ledger.new
          ledger.award(user, attributes.fetch(:cost, 10) + 100, reason: "test-seed") if seed_points
          transaction = ledger.spend(
            owner: user,
            amount: attributes.fetch(:cost, 10),
            kind: "redeem",
            reason: "reward:#{attributes.fetch(:reward_key)}"
          )

          defaults = {
            organization:,
            ledger_transaction: transaction,
            user:,
            reward_key: "analytics_reward",
            cost: 10,
            status: "requested"
          }

          Decidim::Bih::Goodwill::RewardFulfillment.create!(defaults.merge(attributes))
        end

        def assert_no_private_values(text)
          assert_not_includes text, "Private report body"
          assert_not_includes text, "Private report address"
          assert_not_includes text, "private@example.org"
          assert_not_includes text, "+387 65 999 888"
          assert_not_includes text, "Private opportunity title"
          assert_not_includes text, "Private komsiluk title"
          assert_not_includes text, "Private komsiluk body"
          assert_not_includes text, "Private broadcast content"
          assert_not_includes text, "donor-secret@example.org"
          assert_not_includes text, "BANK-PRIVATE-123"
          assert_not_includes text, "Private request bot prompt"
          assert_not_includes text, "Private request bot answer"
          assert_not_includes text, "request-private-token"
          assert_not_includes text, "request-private-session-digest"
          assert_not_includes text, "request-private-viber-sender"
          assert_not_includes text, "66666666-6666-4666-8666-666666666666"
          assert_not_includes text, @citizen.email
          assert_not_includes text, @citizen.name
        end
      end
    end
  end
end
