# frozen_string_literal: true

require "test_helper"
require "csv"
require "securerandom"

module Decidim
  module Bih
    module Admin
      class AnalyticsSummaryTest < ActiveSupport::TestCase
        FakeDonationTotals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride
        FakeDonationProvider = Struct.new(:totals, :currency_label, :project_mappings, keyword_init: true)

        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @original_donations_provider = Decidim::Bih.donations_provider
          @komsiluk = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "analytics-komsiluk",
            name: { "sr" => "Analitika komšiluk" }
          )
        end

        teardown do
          Decidim::Bih.donations_provider = @original_donations_provider
        end

        test "donation analytics use aggregate provider totals without exposing donor data" do
          Decidim::Bih.donations_provider = FakeDonationProvider.new(
            totals: FakeDonationTotals.new(
              total: BigDecimal("1250.50"),
              count: 8,
              currency: "BAM",
              as_of: Time.zone.local(2026, 1, 2, 3, 4, 5)
            ),
            currency_label: "KM",
            project_mappings: [
              {
                decidim_project_id: 42,
                title: "=Project total",
                campaign: "safe-campaign",
                donate_url: "https://payments.example/private",
                donor_email: "donor@example.org",
                donor_name: "Private Donor",
                totals: FakeDonationTotals.new(
                  total: BigDecimal("300"),
                  count: 2,
                  currency: "BAM",
                  as_of: Time.zone.local(2026, 1, 3, 4, 5, 6)
                )
              }
            ]
          )

          csv = summary.csv_for("donations")
          parsed = CSV.parse(csv, headers: true)

          assert_equal "general", parsed.first["scope"]
          assert_equal "1250.5", parsed.first["total_amount"]
          assert_equal "8", parsed.first["donation_orders_count"]
          assert(parsed.any? { |row| row["scope"] == "project" && row["decidim_project_id"] == "42" })
          assert_includes csv, "'=Project total"
          assert_no_private_values(csv)
        end

        test "report analytics aggregate counts without exposing report PII" do
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private report description",
            address: "Private address 1",
            reporter_email: "reporter@example.org",
            reporter_phone: "+387 65 111 222",
            category: "putevi",
            severity: "visok",
            mz_slug: "mz-centar",
            status: "primljeno"
          )

          csv = summary.csv_for("reports")

          parsed = CSV.parse(csv, headers: true)
          assert_equal "mz-centar", parsed.first["mz_slug"]
          assert_equal "putevi", parsed.first["category"]
          assert_equal "1", parsed.first["count"]
          assert_no_private_values(csv)
        end

        test "report triage analytics export aggregate attention buckets without report PII" do
          now = Time.zone.local(2026, 6, 18, 12, 0, 0)
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private report triage old received",
            address: "Private report triage address",
            reporter_email: "triage@example.org",
            reporter_phone: "+387 65 444 333",
            created_at: now - 3.days,
            updated_at: now - 3.days
          )
          failed = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private report triage failed",
            address: "Private failed triage address",
            created_at: now - 1.day,
            updated_at: now - 1.day
          )
          failed.record_forwarding_failure!(StandardError.new("Private triage failure"), code: "private_failure")
          failed.update_columns(forwarding_failed_at: now - 4.days, updated_at: now - 4.days) # rubocop:disable Rails/SkipsModelValidations
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private report triage stale",
            address: "Private stale triage address",
            status: "u_obradi",
            review_state: "validated",
            forwarded_at: now - 45.days,
            created_at: now - 45.days,
            updated_at: now - 45.days
          )
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private report triage review",
            address: "Private review triage address",
            needs_review: true,
            created_at: now - 2.days,
            updated_at: now - 2.days
          )

          csv = summary_at(now).csv_for("report_triage")
          parsed = CSV.parse(csv, headers: true)
          rows = parsed.index_by { |row| row["bucket"] }

          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("report_triage"), parsed.headers
          assert_equal "1", rows.fetch("forwarding_failed")["count"]
          assert_equal "high", rows.fetch("forwarding_failed")["review_priority"]
          assert_equal "retry_forwarding", rows.fetch("forwarding_failed")["review_action"]
          assert_equal "2026-06-14", rows.fetch("forwarding_failed")["oldest_attention_on"]
          assert_equal "forward_received_report", rows.fetch("received_over_sla")["review_action"]
          assert_equal "2", rows.fetch("received_over_sla")["forwarding_sla_days"]
          assert_equal "check_city_followup", rows.fetch("stale_city_followup")["review_action"]
          assert_not rows.has_key?("needs_review")
          assert_equal Decidim::Bih::Report::STALE_DAYS.to_s, rows.fetch("stale_city_followup")["stale_days"]
          assert_no_private_values(csv)
          assert_not_includes csv, "Private report triage"
          assert_not_includes csv, "triage@example.org"
          assert_not_includes csv, "+387 65 444 333"
          assert_not_includes csv, "private_failure"
        end

        test "csv string cells are neutralized for spreadsheet formulas" do
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Spreadsheet edge case",
            category: "putevi",
            mz_slug: "=cmd"
          )

          csv = summary.csv_for("reports")

          assert_includes csv, "'=cmd"
        end

        test "goodwill analytics aggregate by transaction kind" do
          Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 25, reason: "report")

          row = summary.rows_for("goodwill").find { |candidate| candidate[:kind] == "earn" }

          assert_equal 1, row.fetch(:transactions_count)
          assert_equal 25, row.fetch(:positive_points)
          assert_equal 25, row.fetch(:negative_points)
        end

        test "reward fulfillment review aggregates queue and event state without fulfillment PII" do
          now = Time.zone.local(2026, 6, 18, 12, 0, 0)
          travel_to now do
            Decidim::Bih::Goodwill::Reward.create!(
              organization: @organization,
              key: "formula_reward",
              title: { "sr" => "=Formula reward" },
              cost: 20,
              stock: 1,
              active: true,
              expires_at: now + 10.days
            )
            requested = create_reward_fulfillment!(
              reward_key: "formula_reward",
              cost: 20,
              status: "requested",
              notes: "Private reward pickup note",
              reward_expires_at: now - 1.day,
              created_at: now - 5.days,
              updated_at: now - 5.days
            )
            requested.record_event!(
              "requested",
              source: "public",
              metadata: {
                reward_key: "formula_reward",
                phone: "+387 65 777 888",
                pickup_location: "Private pickup desk"
              }
            )
            requested.record_event!(
              "reserved",
              actor: @admin,
              metadata: {
                reward_key: "formula_reward",
                fulfillment_note: "Private reserved note"
              }
            )
            create_reward_fulfillment!(
              reward_key: "formula_reward",
              cost: 20,
              status: "fulfilled",
              reward_expires_at: now + 10.days,
              handled_at: now - 1.day,
              created_at: now - 4.days,
              updated_at: now - 1.day
            )
            create_reward_fulfillment!(
              reward_key: "canceled_reward",
              cost: 10,
              status: "canceled",
              created_at: now - 6.days,
              updated_at: now - 2.days,
              handled_at: now - 2.days
            )

            other_org = create_organization
            other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
            create_reward_fulfillment!(
              organization: other_org,
              user: other_user,
              reward_key: "other_private_reward",
              cost: 15,
              status: "requested"
            )
          end

          rows = summary_at(now).rows_for("reward_fulfillment_review")
          formula = rows.find { |row| row[:reward_key] == "formula_reward" }
          canceled = rows.find { |row| row[:reward_key] == "canceled_reward" }

          assert_equal "high", rows.first.fetch(:review_priority)
          assert_equal "=Formula reward", formula.fetch(:reward_name)
          assert_equal "check_expired_open_requests", formula.fetch(:review_action)
          assert_equal 2, formula.fetch(:fulfillments_count)
          assert_equal 1, formula.fetch(:open_count)
          assert_equal 1, formula.fetch(:requested_count)
          assert_equal 1, formula.fetch(:fulfilled_count)
          assert_equal 1, formula.fetch(:expired_open_count)
          assert_equal 2, formula.fetch(:events_count)
          assert_equal "reserved", formula.fetch(:latest_event_type)
          assert_equal "2026-06-13", formula.fetch(:oldest_opened_on)
          assert_equal "2026-06-17", formula.fetch(:latest_status_on)
          assert_equal "2026-06-18", formula.fetch(:latest_event_on)
          assert_equal "2026-06-17", formula.fetch(:next_expiry_on)
          assert_equal 0, formula.fetch(:stock_remaining)
          assert_equal 1, formula.fetch(:stock_total)
          assert_equal "watch", canceled.fetch(:review_priority)
          assert_equal "review_recent_cancellations", canceled.fetch(:review_action)

          csv = summary_at(now).csv_for("reward_fulfillment_review")
          parsed = CSV.parse(csv, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("reward_fulfillment_review"), parsed.headers
          assert_includes csv, "'=Formula reward"
          assert_no_private_values(csv)
          assert_not_includes csv, "Private reward pickup note"
          assert_not_includes csv, "Private pickup desk"
          assert_not_includes csv, "+387 65 777 888"
          assert_not_includes csv, "Private reserved note"
          assert_not_includes csv, "other_private_reward"
          assert_not_includes csv, @citizen.email
          assert_not_includes csv, @citizen.name
        end

        test "volunteering analytics aggregate opportunities logs and signups" do
          opportunity = Decidim::Bih::VolunteerOpportunity.create!(
            organization: @organization,
            author: @citizen,
            title: "Private volunteer opportunity",
            active: true,
            review_status: "approved"
          )
          create_legacy_volunteer_log!(
            organization: @organization,
            opportunity:,
            user: @citizen,
            hours: 3,
            status: "approved"
          )
          Decidim::Bih::VolunteerSignup.create!(
            organization: @organization,
            opportunity:,
            user: @citizen,
            status: "going", review_status: "automatic", review_source: "automatic"
          )

          rows = summary.rows_for("volunteering")

          assert(rows.any? { |row| row[:metric] == "opportunities" && row[:count] == 1 })
          assert(rows.any? { |row| row[:metric] == "volunteer_logs" && row[:hours] == 3 })
          assert(rows.any? { |row| row[:metric] == "signups" && row[:status] == "going" })
        end

        test "komsiluk analytics aggregate posts and broadcasts without content or recipients" do
          Decidim::Bih::KomsilukPost.create!(
            organization: @organization,
            author: @citizen,
            komsiluk: @komsiluk,
            category: "general",
            title: "Private board title",
            body: "Call me at +387 65 111 222",
            flagged_count: 2
          )
          Decidim::Bih::Broadcast.create!(
            organization: @organization,
            area: @komsiluk,
            sent_by: @admin,
            message: "Private broadcast message",
            channels: "bell,viber",
            recipients_count: 4
          )

          csv = summary.csv_for("komsiluk")

          parsed = CSV.parse(csv, headers: true)
          assert(parsed.any? { |row| row["metric"] == "posts" && row["total_flags"] == "2" })
          assert(parsed.any? { |row| row["metric"] == "broadcasts" && row["total_recipients"] == "4" })
          assert_no_private_values(csv)
        end

        test "komsiluk activity review prioritizes aggregate rows without content or membership data" do
          now = Time.zone.local(2026, 6, 18, 12, 0, 0)
          formula_area = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "formula-komsiluk",
            name: { "sr" => "=Formula komšiluk" }
          )
          Decidim::Bih::KomsilukPost.create!(
            organization: @organization,
            author: @citizen,
            komsiluk: @komsiluk,
            category: "general",
            title: "Private review hidden title",
            body: "Private review hidden body",
            status: "hidden",
            flagged_count: 3,
            hidden_at: now - 2.days,
            created_at: now - 12.days,
            updated_at: now - 2.days
          )
          Decidim::Bih::KomsilukPost.create!(
            organization: @organization,
            author: @citizen,
            komsiluk: @komsiluk,
            category: "safety",
            title: "Private review urgent title",
            body: "Private review urgent body",
            expires_at: now + 3.days,
            created_at: now - 4.days,
            updated_at: now - 4.days
          )
          Decidim::Bih::KomsilukPost.create!(
            organization: @organization,
            author: @citizen,
            komsiluk: formula_area,
            category: "general",
            title: "Private review expired title",
            body: "Private review expired body",
            status: "expired",
            expires_at: now - 1.day,
            created_at: now - 20.days,
            updated_at: now - 1.day
          )
          Decidim::Bih::Broadcast.create!(
            organization: @organization,
            area: @komsiluk,
            sent_by: @admin,
            message: "Private review broadcast message",
            channels: "bell,viber",
            recipients_count: 12,
            created_at: now - 1.day,
            updated_at: now - 1.day
          )
          Decidim::Bih::Broadcast.create!(
            organization: @organization,
            area: formula_area,
            sent_by: @admin,
            message: "Private review zero-recipient broadcast",
            channels: "bell",
            recipients_count: 0,
            created_at: now - 2.days,
            updated_at: now - 2.days
          )
          other_org = create_organization
          other_area = Decidim::Bih::LocalArea.create!(
            organization: other_org,
            kind: "komsiluk",
            slug: "other-activity-komsiluk",
            name: { "sr" => "Other activity area" }
          )
          other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
          Decidim::Bih::KomsilukPost.create!(
            organization: other_org,
            author: other_user,
            komsiluk: other_area,
            category: "safety",
            title: "Other org activity title",
            body: "Other org activity body",
            flagged_count: 9
          )

          rows = summary_at(now).rows_for("komsiluk_activity_review")
          main = rows.find { |row| row[:area_slug] == "analytics-komsiluk" }
          formula = rows.find { |row| row[:area_slug] == "formula-komsiluk" }

          assert_equal "high", rows.first.fetch(:review_priority)
          assert_equal "review_moderation_queue", main.fetch(:review_action)
          assert_equal 2, main.fetch(:posts_count)
          assert_equal 1, main.fetch(:urgent_posts_count)
          assert_equal 1, main.fetch(:hidden_posts_count)
          assert_equal 1, main.fetch(:flagged_posts_count)
          assert_equal 1, main.fetch(:expiring_posts_count)
          assert_equal 3, main.fetch(:total_flags)
          assert_equal 1, main.fetch(:broadcasts_count)
          assert_equal 1, main.fetch(:viber_broadcasts_count)
          assert_equal 12, main.fetch(:total_recipients)
          assert_equal "2026-06-06", main.fetch(:first_post_on)
          assert_equal "2026-06-14", main.fetch(:last_post_on)
          assert_equal "2026-06-17", main.fetch(:first_broadcast_on)
          assert_equal "2026-06-17", main.fetch(:last_broadcast_on)
          assert_equal "watch", formula.fetch(:review_priority)
          assert_equal "check_expired_cleanup", formula.fetch(:review_action)
          assert_equal 1, formula.fetch(:expired_posts_count)
          assert_equal 0, formula.fetch(:total_recipients)

          csv = summary_at(now).csv_for("komsiluk_activity_review")
          parsed = CSV.parse(csv, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("komsiluk_activity_review"), parsed.headers
          assert_includes csv, "'=Formula komšiluk"
          assert_no_private_values(csv)
          assert_not_includes csv, "Private review"
          assert_not_includes csv, "Other org activity"
        end

        test "mi bot feedback analytics aggregate answer ratings without conversation data" do
          create_feedback!(
            value: "helpful",
            locale: "sr",
            reply_id: "11111111-1111-4111-8111-111111111111",
            session_digest: "private-session-digest-1",
            citizen_message: "Private bot prompt",
            bot_reply_text: "Private bot answer",
            created_at: Time.zone.local(2026, 5, 1, 8, 0, 0),
            updated_at: Time.zone.local(2026, 5, 1, 8, 5, 0),
            metadata: {
              "outcome" => "success",
              "answer_intent" => "waste",
              "reply_length" => 100,
              "quick_replies_count" => 0,
              "raw_message" => "Private bot prompt",
              "raw_reply" => "Private bot answer",
              "token" => "private-feedback-token",
              "ip" => "198.51.100.9",
              "user_agent" => "Private test browser"
            }
          )
          create_feedback!(
            value: "helpful",
            locale: "sr",
            reply_id: "22222222-2222-4222-8222-222222222222",
            session_digest: "private-session-digest-2",
            created_at: Time.zone.local(2026, 5, 2, 8, 0, 0),
            updated_at: Time.zone.local(2026, 5, 4, 8, 0, 0),
            metadata: {
              "outcome" => "success",
              "answer_intent" => "waste",
              "reply_length" => 140,
              "quick_replies_count" => 2
            }
          )
          create_feedback!(
            value: "not_helpful",
            locale: "en",
            reply_id: "33333333-3333-4333-8333-333333333333",
            session_digest: "private-session-digest-3",
            metadata: {
              "outcome" => "fallback",
              "answer_intent" => "fallback",
              "reply_length" => 30,
              "quick_replies_count" => 4
            }
          )
          create_feedback!(
            value: "helpful",
            locale: "bs",
            reply_id: "44444444-4444-4444-8444-444444444444",
            session_digest: "private-session-digest-4",
            metadata: {
              "outcome" => "=cmd",
              "answer_intent" => "=intent",
              "reply_length" => "not a number",
              "quick_replies_count" => "bad"
            }
          )
          create_feedback!(
            organization: create_organization,
            value: "helpful",
            locale: "sr",
            reply_id: "55555555-5555-4555-8555-555555555555",
            session_digest: "other-org-private-session",
            metadata: {
              "outcome" => "other-org-private-outcome",
              "answer_intent" => "other-org-private-intent",
              "reply_length" => 999,
              "quick_replies_count" => 99,
              "raw_message" => "Other organization bot prompt"
            }
          )

          rows = summary.rows_for("mi_bot_feedback")
          helpful = rows.find do |row|
            row[:rating] == "helpful" && row[:outcome] == "success" &&
              row[:answer_intent] == "waste" && row[:locale] == "sr"
          end
          fallback = rows.find do |row|
            row[:rating] == "not_helpful" && row[:outcome] == "fallback" &&
              row[:answer_intent] == "fallback" && row[:locale] == "en"
          end
          formula = rows.find { |row| row[:outcome] == "=cmd" && row[:answer_intent] == "=intent" }

          assert_equal 2, helpful.fetch(:count)
          assert_equal "waste", helpful.fetch(:answer_intent)
          assert_equal "120.0", helpful.fetch(:average_reply_length)
          assert_equal "1.0", helpful.fetch(:average_quick_replies_count)
          assert_equal "2026-05-01", helpful.fetch(:first_feedback_on)
          assert_equal "2026-05-04", helpful.fetch(:last_feedback_on)
          assert_equal 1, fallback.fetch(:count)
          assert_nil formula.fetch(:average_reply_length)
          assert_nil formula.fetch(:average_quick_replies_count)

          csv = summary.csv_for("mi_bot_feedback")
          parsed = CSV.parse(csv, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("mi_bot_feedback"), parsed.headers
          assert_includes csv, "'=cmd"
          assert_includes csv, "'=intent"
          assert_no_private_values(csv)
        end

        test "mi bot usage analytics aggregate all bot turns without conversation data" do
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: @organization,
            bucket_on: Date.new(2026, 5, 1),
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            requests_count: 2,
            message_length_total: 50,
            reply_length_total: 200,
            quick_replies_total: 2,
            sticker_count: 1
          )
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: @organization,
            bucket_on: Date.new(2026, 5, 2),
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            requests_count: 1,
            message_length_total: 25,
            reply_length_total: 70,
            quick_replies_total: 1,
            sticker_count: 0
          )
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: @organization,
            bucket_on: Date.new(2026, 5, 2),
            channel: "viber",
            outcome: "fallback",
            answer_intent: "fallback",
            locale: "en",
            requests_count: 1,
            message_length_total: 10,
            reply_length_total: 40,
            quick_replies_total: 0,
            sticker_count: 0
          )
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: create_organization,
            bucket_on: Date.new(2026, 5, 2),
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            requests_count: 99,
            message_length_total: 999,
            reply_length_total: 999,
            quick_replies_total: 99
          )

          rows = summary.rows_for("mi_bot_usage")
          web = rows.find { |row| row[:channel] == "web_chat" && row[:answer_intent] == "waste" }
          fallback = rows.find { |row| row[:channel] == "viber" && row[:outcome] == "fallback" }

          assert_equal 3, web.fetch(:count)
          assert_equal "25.0", web.fetch(:average_message_length)
          assert_equal "90.0", web.fetch(:average_reply_length)
          assert_equal "1.0", web.fetch(:average_quick_replies_count)
          assert_equal 1, web.fetch(:sticker_count)
          assert_equal "2026-05-01", web.fetch(:first_seen_on)
          assert_equal "2026-05-02", web.fetch(:last_seen_on)
          assert_equal 1, fallback.fetch(:count)
          assert_nil fallback.fetch(:average_message_length)

          csv = summary.csv_for("mi_bot_usage")
          parsed = CSV.parse(csv, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("mi_bot_usage"), parsed.headers
          assert_no_private_values(csv)
          assert_not_includes csv, "99"
        end

        test "mi bot review analytics prioritize aggregate answer-quality buckets" do
          create_feedback!(
            value: "helpful",
            locale: "sr",
            reply_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            session_digest: "private-review-session-1",
            citizen_message: "Private review prompt",
            bot_reply_text: "Private review answer",
            created_at: Time.zone.local(2026, 5, 1, 8, 0, 0),
            updated_at: Time.zone.local(2026, 5, 1, 8, 1, 0),
            metadata: {
              "outcome" => "success",
              "answer_intent" => "budget",
              "reply_length" => 100,
              "quick_replies_count" => 0,
              "raw_message" => "Private review prompt",
              "raw_reply" => "Private review answer"
            }
          )
          create_feedback!(
            value: "not_helpful",
            locale: "sr",
            reply_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            session_digest: "private-review-session-2",
            created_at: Time.zone.local(2026, 5, 2, 8, 0, 0),
            updated_at: Time.zone.local(2026, 5, 2, 8, 1, 0),
            metadata: {
              "outcome" => "success",
              "answer_intent" => "budget",
              "reply_length" => 80,
              "quick_replies_count" => 1
            }
          )
          create_feedback!(
            value: "not_helpful",
            locale: "sr",
            reply_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            session_digest: "private-review-session-3",
            created_at: Time.zone.local(2026, 5, 3, 8, 0, 0),
            updated_at: Time.zone.local(2026, 5, 3, 8, 1, 0),
            metadata: {
              "outcome" => "success",
              "answer_intent" => "budget",
              "reply_length" => 60,
              "quick_replies_count" => 2
            }
          )
          create_feedback!(
            value: "not_helpful",
            locale: "en",
            reply_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            session_digest: "private-review-session-4",
            metadata: {
              "outcome" => "fallback",
              "answer_intent" => "fallback",
              "reply_length" => 30,
              "quick_replies_count" => 4
            }
          )
          create_feedback!(
            value: "helpful",
            locale: "bs",
            reply_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            session_digest: "private-review-session-5",
            metadata: {
              "outcome" => "success",
              "answer_intent" => "waste",
              "reply_length" => 120,
              "quick_replies_count" => 0
            }
          )
          create_feedback!(
            organization: create_organization,
            value: "not_helpful",
            locale: "sr",
            reply_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            session_digest: "other-org-private-review-session",
            metadata: {
              "outcome" => "other-org-private-review-outcome",
              "answer_intent" => "other-org-private-review-intent",
              "raw_message" => "Other org private review prompt"
            }
          )

          rows = summary.rows_for("mi_bot_review")
          success = rows.find { |row| row[:outcome] == "success" && row[:answer_intent] == "budget" && row[:locale] == "sr" }
          fallback = rows.find { |row| row[:outcome] == "fallback" && row[:answer_intent] == "fallback" && row[:locale] == "en" }
          stable = rows.find { |row| row[:outcome] == "success" && row[:answer_intent] == "waste" && row[:locale] == "bs" }

          assert_equal "high", rows.first.fetch(:review_priority)
          assert_equal 3, success.fetch(:feedback_count)
          assert_equal "budget", success.fetch(:answer_intent)
          assert_equal 1, success.fetch(:helpful_count)
          assert_equal 2, success.fetch(:not_helpful_count)
          assert_equal "66.7", success.fetch(:not_helpful_rate)
          assert_equal "80.0", success.fetch(:average_reply_length)
          assert_equal "1.0", success.fetch(:average_quick_replies_count)
          assert_equal "high", success.fetch(:review_priority)
          assert_equal "review_answer_library", success.fetch(:review_action)
          assert_equal "high", fallback.fetch(:review_priority)
          assert_equal "check_resolver_and_city_data", fallback.fetch(:review_action)
          assert_equal "monitor", stable.fetch(:review_priority)
          assert_equal "continue_monitoring", stable.fetch(:review_action)
          assert_equal [success, fallback], summary.mi_bot_answer_review_queue
          assert_equal [success], summary.mi_bot_answer_review_queue(limit: 1)
          assert_not_includes summary.mi_bot_answer_review_queue, stable

          csv = summary.csv_for("mi_bot_review")
          parsed = CSV.parse(csv, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("mi_bot_review"), parsed.headers
          assert_no_private_values(csv)
          assert_not_includes csv, "Private review"
          assert_not_includes csv, "other-org-private"
          assert_not_includes csv, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
          assert_not_includes csv, "private-review-session"
        end

        test "mi bot review comparison tracks same answer buckets before and after improvements" do
          now = Time.zone.local(2026, 7, 8, 12, 0, 0)
          previous_at = now - 45.days
          current_at = now - 5.days
          3.times do
            create_feedback!(
              value: "not_helpful",
              locale: "sr",
              created_at: previous_at,
              updated_at: previous_at,
              session_digest: "private-comparison-previous-session",
              citizen_message: "Private previous comparison prompt",
              bot_reply_text: "Private previous comparison answer",
              metadata: {
                "outcome" => "success",
                "answer_intent" => "public_transport",
                "raw_message" => "Private previous comparison prompt"
              }
            )
          end
          create_feedback!(
            value: "not_helpful",
            locale: "sr",
            created_at: current_at,
            updated_at: current_at,
            session_digest: "private-comparison-current-session",
            citizen_message: "Private current comparison prompt",
            bot_reply_text: "Private current comparison answer",
            metadata: {
              "outcome" => "success",
              "answer_intent" => "public_transport",
              "raw_reply" => "Private current comparison answer"
            }
          )
          create_feedback!(
            value: "helpful",
            locale: "sr",
            created_at: current_at,
            updated_at: current_at,
            metadata: {
              "outcome" => "success",
              "answer_intent" => "public_transport"
            }
          )
          create_feedback!(
            organization: create_organization,
            value: "not_helpful",
            locale: "sr",
            created_at: current_at,
            updated_at: current_at,
            metadata: {
              "outcome" => "other-private-outcome",
              "answer_intent" => "other-private-intent"
            }
          )

          rows = summary_at(now).rows_for("mi_bot_review_comparison")
          row = rows.find { |candidate| candidate[:answer_intent] == "public_transport" }

          assert_equal "success", row.fetch(:outcome)
          assert_equal "sr", row.fetch(:locale)
          assert_equal 1, row.fetch(:current_not_helpful_count)
          assert_equal 3, row.fetch(:previous_not_helpful_count)
          assert_equal(-2, row.fetch(:change_value))
          assert_equal "-66.7", row.fetch(:change_percent)
          assert_equal true, row.fetch(:decreased)
          assert_equal 2, row.fetch(:current_total_feedback)
          assert_equal 3, row.fetch(:previous_total_feedback)
          assert_equal "2026-06-08", row.fetch(:current_started_on)
          assert_equal "2026-07-08", row.fetch(:current_ended_on)
          assert_equal "2026-05-09", row.fetch(:previous_started_on)
          assert_equal "2026-06-08", row.fetch(:previous_ended_on)

          csv = summary_at(now).csv_for("mi_bot_review_comparison")
          parsed = CSV.parse(csv, headers: true)
          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("mi_bot_review_comparison"), parsed.headers
          assert_no_private_values(csv)
          assert_not_includes csv, "Private"
          assert_not_includes csv, "private-comparison"
          assert_not_includes csv, "other-private"
        end

        test "mi bot answer review examples expose bounded anonymous clicked feedback" do
          create_feedback!(
            value: "helpful",
            reply_id: "12121212-1212-4212-8212-121212121212",
            session_digest: "private-example-helpful-session",
            citizen_message: "Private helpful prompt",
            bot_reply_text: "Private helpful answer",
            updated_at: Time.zone.local(2026, 5, 2, 8, 0, 0),
            metadata: {
              "outcome" => "success",
              "answer_intent" => "waste"
            }
          )
          create_feedback!(
            value: "not_helpful",
            reply_id: "23232323-2323-4232-8232-232323232323",
            session_digest: "private-example-not-helpful-session",
            citizen_message: "Private not helpful prompt",
            bot_reply_text: "#{"Private not helpful answer " * 80}with the failing detail",
            updated_at: Time.zone.local(2026, 5, 3, 8, 0, 0),
            metadata: {
              "outcome" => "fallback",
              "answer_intent" => "fallback"
            }
          )
          create_feedback!(
            value: "not_helpful",
            reply_id: "34343434-3434-4343-8343-343434343434",
            session_digest: "private-example-missing-transcript-session",
            citizen_message: nil,
            bot_reply_text: "Missing prompt answer",
            updated_at: Time.zone.local(2026, 5, 4, 8, 0, 0),
            metadata: {
              "outcome" => "success",
              "answer_intent" => "budget"
            }
          )
          create_feedback!(
            organization: create_organization,
            value: "not_helpful",
            reply_id: "45454545-4545-4454-8454-454545454545",
            session_digest: "other-org-private-example-session",
            citizen_message: "Other org private prompt",
            bot_reply_text: "Other org private answer",
            metadata: {
              "outcome" => "success",
              "answer_intent" => "waste"
            }
          )

          rows = summary.mi_bot_answer_review_examples(limit: 2)

          assert_equal %w(not_helpful helpful), (rows.map { |row| row[:rating] })
          assert_equal "check_resolver_and_city_data", rows.first.fetch(:review_action)
          assert_equal "continue_monitoring", rows.second.fetch(:review_action)
          assert_equal "fallback", rows.first.fetch(:answer_intent)
          assert_equal "2026-05-03", rows.first.fetch(:feedback_on)
          assert_equal "Private not helpful prompt", rows.first.fetch(:citizen_message)
          assert_includes rows.first.fetch(:bot_reply_text), "Private not helpful answer"
          assert_operator rows.first.fetch(:bot_reply_text).length,
                          :<=,
                          Decidim::Bih::Admin::AnalyticsSummary::MI_BOT_REVIEW_EXAMPLE_TEXT_LIMIT
          assert_equal "Private helpful prompt", rows.second.fetch(:citizen_message)
          assert_equal "Private helpful answer", rows.second.fetch(:bot_reply_text)

          rendered = rows.to_s
          assert_not_includes rendered, "private-example-not-helpful-session"
          assert_not_includes rendered, "private-example-helpful-session"
          assert_not_includes rendered, "23232323-2323-4232-8232-232323232323"
          assert_not_includes rendered, "12121212-1212-4212-8212-121212121212"
          assert_not_includes rendered, "Missing prompt answer"
          assert_not_includes rendered, "Other org private prompt"
          assert_not_includes rendered, @citizen.email
          assert_not_includes rendered, @citizen.name
        end

        test "trend analytics compare current and previous windows without exposing source PII" do
          now = Time.zone.local(2026, 6, 17, 12, 0, 0)
          current_at = now - 5.days
          previous_at = now - 35.days
          older_at = now - 75.days
          other_org = create_organization
          other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
          ledger = Decidim::Bih::Goodwill::Ledger.new
          seed = ledger.award(@citizen, 200, reason: "seed")
          current_earn = ledger.award(@citizen, 40, reason: "current")
          previous_earn = ledger.award(@citizen, 10, reason: "previous")
          current_redeem = ledger.spend(owner: @citizen, amount: 20, kind: "redeem", reason: "reward:current")
          previous_redeem = ledger.spend(owner: @citizen, amount: 5, kind: "redeem", reason: "reward:previous")
          other_txn = ledger.award(other_user, 999, reason: "other")
          [seed, current_earn, previous_earn, current_redeem, previous_redeem, other_txn].compact.each do |txn|
            timestamp = case txn
                        when seed
                          older_at
                        when previous_earn, previous_redeem
                          previous_at
                        else
                          current_at
                        end
            stamp_transaction!(txn, timestamp)
          end

          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private trend report body",
            reporter_email: "trend@example.org",
            reporter_phone: "+387 65 555 444",
            category: "putevi",
            mz_slug: "mz-trend",
            created_at: current_at
          )
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Previous private trend report body",
            category: "vodovod_kanalizacija",
            created_at: previous_at
          )
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Boundary private trend report body",
            category: "putevi",
            created_at: now - 30.days
          )
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Exact end private trend report body",
            category: "putevi",
            created_at: now
          )
          Decidim::Bih::Report.create!(
            organization: other_org,
            description: "Other org trend report body",
            category: "putevi",
            created_at: current_at
          )

          opportunity = Decidim::Bih::VolunteerOpportunity.create!(
            organization: @organization,
            author: @citizen,
            title: "Private trend opportunity",
            active: true,
            review_status: "approved"
          )
          create_legacy_volunteer_log!(
            organization: @organization,
            opportunity:,
            user: @citizen,
            hours: 3,
            status: "approved",
            created_at: current_at
          )
          create_legacy_volunteer_log!(
            organization: @organization,
            opportunity:,
            user: @citizen,
            hours: 1,
            status: "approved",
            created_at: previous_at
          )
          Decidim::Bih::VolunteerSignup.create!(
            organization: @organization,
            opportunity:,
            user: @citizen,
            status: "going",
            review_status: "automatic",
            review_source: "automatic",
            created_at: current_at
          )

          Decidim::Bih::KomsilukPost.create!(
            organization: @organization,
            author: @citizen,
            komsiluk: @komsiluk,
            category: "general",
            title: "Private trend board title",
            body: "Private trend board body",
            created_at: current_at
          )
          Decidim::Bih::Broadcast.create!(
            organization: @organization,
            area: @komsiluk,
            sent_by: @admin,
            message: "Private trend broadcast",
            channels: "bell",
            recipients_count: 4,
            created_at: current_at
          )
          Decidim::Bih::Broadcast.create!(
            organization: @organization,
            area: @komsiluk,
            sent_by: @admin,
            message: "Previous private trend broadcast",
            channels: "bell",
            recipients_count: 2,
            created_at: previous_at
          )

          create_feedback!(
            value: "helpful",
            created_at: current_at,
            metadata: { "raw_message" => "Private trend bot prompt" }
          )
          create_feedback!(value: "not_helpful", created_at: current_at)
          create_feedback!(value: "helpful", created_at: previous_at)
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: @organization,
            bucket_on: current_at.to_date,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            requests_count: 4,
            message_length_total: 100,
            reply_length_total: 300,
            quick_replies_total: 2
          )
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: @organization,
            bucket_on: previous_at.to_date,
            channel: "viber",
            outcome: "success",
            answer_intent: "report",
            locale: "sr",
            requests_count: 1,
            message_length_total: 20,
            reply_length_total: 80,
            quick_replies_total: 0
          )
          Decidim::Bih::ConciergeUsageAggregate.create!(
            organization: other_org,
            bucket_on: current_at.to_date,
            channel: "web_chat",
            outcome: "success",
            answer_intent: "waste",
            locale: "sr",
            requests_count: 99
          )

          rows = summary_at(now).rows_for("trends").index_by { |row| row[:metric] }

          csv_headers = summary_at(now).csv_for("trends").then do |csv|
            CSV.parse(csv, headers: true).headers
          end

          assert_equal Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("trends"), csv_headers
          assert_equal 2, rows.fetch("reports_created").fetch(:current_value)
          assert_equal 1, rows.fetch("reports_created").fetch(:previous_value)
          assert_equal 40, rows.fetch("goodwill_points_earned").fetch(:current_value)
          assert_equal 10, rows.fetch("goodwill_points_earned").fetch(:previous_value)
          assert_equal 30, rows.fetch("goodwill_points_earned").fetch(:change_value)
          assert_equal "300.0", rows.fetch("goodwill_points_earned").fetch(:change_percent)
          assert_equal 1, rows.fetch("goodwill_redemptions").fetch(:current_value)
          assert_equal 20, rows.fetch("goodwill_points_redeemed").fetch(:current_value)
          assert_equal 5, rows.fetch("goodwill_points_redeemed").fetch(:previous_value)
          assert_equal 3, rows.fetch("volunteer_hours_approved").fetch(:current_value)
          assert_equal 1, rows.fetch("volunteer_hours_approved").fetch(:previous_value)
          assert_equal 4, rows.fetch("komsiluk_broadcast_recipients").fetch(:current_value)
          assert_equal 2, rows.fetch("komsiluk_broadcast_recipients").fetch(:previous_value)
          assert_equal 4, rows.fetch("mi_bot_requests").fetch(:current_value)
          assert_equal 1, rows.fetch("mi_bot_requests").fetch(:previous_value)
          assert_equal 2, rows.fetch("mi_bot_feedback").fetch(:current_value)
          assert_equal 1, rows.fetch("mi_bot_helpful_feedback").fetch(:current_value)
          assert_equal 1, rows.fetch("mi_bot_not_helpful_feedback").fetch(:current_value)
          assert_nil rows.fetch("mi_bot_not_helpful_feedback").fetch(:change_percent)
          assert_equal "2026-05-18", rows.fetch("reports_created").fetch(:current_started_on)
          assert_equal "2026-06-17", rows.fetch("reports_created").fetch(:current_ended_on)

          csv = summary_at(now).csv_for("trends")
          assert_includes csv, "reports_created"
          assert_no_private_values(csv)
          assert_not_includes csv, "Private trend"
          assert_not_includes csv, "trend@example.org"
          assert_not_includes csv, "+387 65 555 444"
          assert_not_includes csv, "Other org trend"
        end

        test "digest_sections expose bounded aggregate review rows for scheduled delivery" do
          now = Time.zone.local(2026, 6, 18, 12, 0, 0)
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private digest report description",
            address: "Private digest address",
            reporter_email: "digest@example.org",
            created_at: now - 3.days,
            updated_at: now - 3.days
          )
          create_feedback!(
            value: "not_helpful",
            created_at: now - 1.day,
            updated_at: now - 1.day,
            session_digest: "private-digest-session",
            metadata: {
              "outcome" => "fallback",
              "answer_intent" => "waste",
              "reply_length" => 120,
              "quick_replies_count" => 2,
              "raw_prompt" => "Private prompt"
            }
          )

          sections = summary_at(now).digest_sections(limit: 3)

          assert_equal Decidim::Bih::Admin::AnalyticsSummary::DATASETS, sections.fetch(:overview).keys
          assert(sections.fetch(:report_triage).any? { |row| row[:bucket] == "received_over_sla" })
          assert(sections.fetch(:mi_bot_review).any? { |row| row[:answer_intent] == "waste" })
          assert(sections.fetch(:mi_bot_review_comparison).any? { |row| row[:answer_intent] == "waste" })
          assert_equal 13, sections.fetch(:trends).size

          rendered = sections.to_s
          assert_not_includes rendered, "Private digest"
          assert_not_includes rendered, "digest@example.org"
          assert_not_includes rendered, "private-digest-session"
          assert_not_includes rendered, "Private prompt"
        end

        private

        def summary
          Decidim::Bih::Admin::AnalyticsSummary.new(organization: @organization)
        end

        def summary_at(now)
          Decidim::Bih::Admin::AnalyticsSummary.new(organization: @organization, now:)
        end

        def create_feedback!(organization: @organization, **attributes)
          defaults = {
            organization:,
            user: @citizen,
            reply_id: SecureRandom.uuid,
            session_digest: SecureRandom.hex(16),
            value: "helpful",
            locale: "sr",
            metadata: {}
          }

          Decidim::Bih::ConciergeFeedback.create!(defaults.merge(attributes))
        end

        def create_reward_fulfillment!(organization: @organization, user: @citizen, **attributes)
          ledger = Decidim::Bih::Goodwill::Ledger.new
          ledger.award(user, attributes.fetch(:cost, 10) + 100, reason: "test-seed")
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

        def stamp_transaction!(transaction, timestamp)
          # Ledger entries are intentionally immutable; this helper only builds
          # historical windows for trend analytics coverage.
          # rubocop:disable Rails/SkipsModelValidations
          transaction.update_columns(created_at: timestamp, updated_at: timestamp)
          # rubocop:enable Rails/SkipsModelValidations
        end

        def assert_no_private_values(text)
          assert_not_includes text, "Private report description"
          assert_not_includes text, "Private address"
          assert_not_includes text, "reporter@example.org"
          assert_not_includes text, "+387 65 111 222"
          assert_not_includes text, "Private board title"
          assert_not_includes text, "Private broadcast message"
          assert_not_includes text, "donor@example.org"
          assert_not_includes text, "Private Donor"
          assert_not_includes text, "payments.example"
          assert_not_includes text, "Private bot prompt"
          assert_not_includes text, "Private bot answer"
          assert_not_includes text, "private-feedback-token"
          assert_not_includes text, "private-session-digest"
          assert_not_includes text, "11111111-1111-4111-8111-111111111111"
          assert_not_includes text, "22222222-2222-4222-8222-222222222222"
          assert_not_includes text, "33333333-3333-4333-8333-333333333333"
          assert_not_includes text, "198.51.100.9"
          assert_not_includes text, "Private test browser"
          assert_not_includes text, "other-org-private"
          assert_not_includes text, @citizen.email
          assert_not_includes text, @citizen.name
        end
      end
    end
  end
end
