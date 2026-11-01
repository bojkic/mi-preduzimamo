# frozen_string_literal: true

require "application_system_test_case"

class AdminAnalyticsTest < ApplicationSystemTestCase
  FakeDonationTotals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride
  FakeDonationProvider = Struct.new(:totals, :currency_label, :project_mappings, keyword_init: true)

  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
    @original_donations_provider = Decidim::Bih.donations_provider
    Decidim::Bih.donations_provider = fake_donations_provider
    @komsiluk = Decidim::Bih::LocalArea.create!(
      organization: @organization,
      kind: "komsiluk",
      slug: "browser-analytics-k",
      name: { "sr" => "Browser analitika" }
    )
    create_private_source_data!
  end

  teardown do
    Decidim::Bih.donations_provider = @original_donations_provider
  end

  test "admin analytics page renders aggregate exports and feedback examples without identifiers" do
    sign_in_user! @admin

    visit "/admin/bih/analytics"
    accept_data_consent!

    assert_selector "#admin-analytics-header"
    assert_selector "#admin-analytics-workflow-nav"
    assert_selector "#admin-analytics-header[data-analytics-active-tab='exports']"
    assert_selector "#admin-analytics-workflow-nav a[aria-current='page'][href='/admin/bih/analytics?tab=exports']"
    assert_selector "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=mi_bot_review']"
    assert_selector "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=examples']"
    assert_selector "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=trends']"
    assert_selector "#admin-analytics-workflow-nav a[href='/admin/bih/analytics?tab=previews']"
    assert_selector "#admin-analytics-exports"
    assert_no_selector "#admin-mi-bot-answer-review"
    assert_no_selector "#admin-mi-bot-review-comparison"
    assert_no_selector "#admin-mi-bot-feedback-examples"
    assert_no_selector "#admin-analytics-preview"
    assert_selector "a[href='/admin/bih/analytics/export/donations.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/reports.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/report_triage.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/goodwill.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/reward_fulfillment_review.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/volunteering.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/komsiluk.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/komsiluk_activity_review.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/mi_bot_usage.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/mi_bot_feedback.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/mi_bot_review.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/mi_bot_review_comparison.csv']"
    assert_selector "a[href='/admin/bih/analytics/export/trends.csv']"
    assert_no_text "Private analytics review prompt"
    assert_no_text "Private analytics review answer"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/analytics?tab=mi_bot_review"
    assert_selector "#admin-analytics-header[data-analytics-active-tab='mi_bot_review']"
    assert_selector "#admin-mi-bot-answer-review", text: "Red za pregled odgovora Milice"
    assert_selector "#admin-mi-bot-answer-review", text: I18n.t("decidim.bih.admin.analytics.answer_intents.waste")
    assert_no_text "waste"
    assert_selector "#admin-mi-bot-answer-review", text: "Uzorkuj česte namjere"
    assert_selector "#admin-mi-bot-answer-review a[href='/admin/bih/analytics/export/mi_bot_review.csv']"
    assert_no_selector "#admin-analytics-exports"
    assert_no_selector "#admin-mi-bot-feedback-examples"
    assert_no_text "Private analytics review prompt"
    assert_no_text "Private analytics review answer"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/analytics?tab=trends"
    assert_selector "#admin-analytics-header[data-analytics-active-tab='trends']"
    assert_selector "#admin-mi-bot-review-comparison", text: "Poređenje istih grupa za asistenta"
    assert_selector "#admin-mi-bot-review-comparison a[href='/admin/bih/analytics/export/mi_bot_review_comparison.csv']"
    assert_no_selector "#admin-mi-bot-answer-review"
    assert_no_selector "#admin-mi-bot-feedback-examples"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/analytics?tab=examples"
    assert_selector "#admin-analytics-header[data-analytics-active-tab='examples']"
    assert_selector "#admin-mi-bot-feedback-examples", text: "Primjeri ocijenjenih odgovora Milice"
    assert_selector "#admin-mi-bot-feedback-examples", text: "Private analytics review prompt"
    assert_selector "#admin-mi-bot-feedback-examples", text: "Private analytics review answer"
    assert_selector "#admin-mi-bot-feedback-examples", text: "Private analytics bot prompt"
    assert_selector "#admin-mi-bot-feedback-examples", text: "Private analytics bot answer"
    assert_no_text "browser-feedback-session"
    assert_no_text "browser-review-session"
    assert_no_text "browser-private-token"
    assert_no_text "browser-review-token"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/analytics?tab=previews"
    assert_selector "#admin-analytics-header[data-analytics-active-tab='previews']"
    assert_selector "#admin-analytics-preview", text: "browser-analytics-k"
    assert_selector "#admin-analytics-preview", text: "Browser project"
    assert_selector "#admin-analytics-preview", text: "Kreirane prijave"
    assert_selector "#admin-analytics-preview", text: "received_over_sla"
    assert_selector "#admin-analytics-preview", text: "prepare_pickup_or_delivery"
    assert_selector "#admin-analytics-preview", text: "helpful"
    assert_selector "#admin-analytics-preview", text: "success"
    assert_selector "#admin-analytics-preview", text: "waste"
    assert_selector "#admin-analytics-preview", text: "sample_common_intents"
    assert_selector "#admin-analytics-preview", text: "review_broadcast_reach"
    assert_no_text "Private analytics report body"
    assert_no_text "analytics-private@example.org"
    assert_no_text "+387 65 333 444"
    assert_no_text "Private analytics board title"
    assert_no_text "Private analytics board body"
    assert_no_text "Private analytics broadcast"
    assert_no_text "browser-donor@example.org"
    assert_no_text "Private analytics reward pickup note"
    assert_no_text "browser-feedback-session"
    assert_no_text "browser-review-session"
    assert_no_text "browser-private-token"
    assert_no_text "browser-review-token"
    assert_no_text "88888888-8888-4888-8888-888888888888"
    assert_no_text "99999999-9999-4999-8999-999999999999"
    assert_no_text @citizen.email
    assert_no_text @citizen.name
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def fake_donations_provider
    FakeDonationProvider.new(
      totals: FakeDonationTotals.new(
        total: BigDecimal("900"),
        count: 7,
        currency: "BAM",
        as_of: Time.zone.local(2026, 3, 4, 5, 6, 7)
      ),
      currency_label: "KM",
      project_mappings: [
        {
          decidim_project_id: 77,
          title: "Browser project",
          campaign: "browser-safe",
          donor_email: "browser-donor@example.org",
          totals: FakeDonationTotals.new(
            total: BigDecimal("350"),
            count: 3,
            currency: "BAM",
            as_of: Time.zone.local(2026, 3, 5, 6, 7, 8)
          )
        }
      ]
    )
  end

  def create_private_source_data!
    Decidim::Bih::Report.create!(
      organization: @organization,
      description: "Private analytics report body",
      reporter_email: "analytics-private@example.org",
      reporter_phone: "+387 65 333 444",
      category: "putevi",
      mz_slug: "mz-browser"
    )
    Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 15, reason: "report")
    create_reward_fulfillment!(
      reward_key: "browser_reward",
      cost: 10,
      status: "reserved",
      notes: "Private analytics reward pickup note"
    )
    opportunity = Decidim::Bih::VolunteerOpportunity.create!(
      organization: @organization,
      author: @citizen,
      title: "Private analytics opportunity",
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
    Decidim::Bih::KomsilukPost.create!(
      organization: @organization,
      author: @citizen,
      komsiluk: @komsiluk,
      category: "general",
      title: "Private analytics board title",
      body: "Private analytics board body"
    )
    Decidim::Bih::Broadcast.create!(
      organization: @organization,
      area: @komsiluk,
      sent_by: @admin,
      message: "Private analytics broadcast",
      channels: "bell",
      recipients_count: 3
    )
    Decidim::Bih::ConciergeFeedback.create!(
      organization: @organization,
      user: @citizen,
      reply_id: "88888888-8888-4888-8888-888888888888",
      session_digest: "browser-feedback-session",
      citizen_message: "Private analytics bot prompt",
      bot_reply_text: "Private analytics bot answer",
      value: "helpful",
      locale: "sr",
      metadata: {
        "outcome" => "success",
        "answer_intent" => "waste",
        "reply_length" => 64,
        "quick_replies_count" => 1,
        "raw_message" => "Private analytics bot prompt",
        "raw_reply" => "Private analytics bot answer",
        "token" => "browser-private-token"
      }
    )
    Decidim::Bih::ConciergeFeedback.create!(
      organization: @organization,
      user: @citizen,
      reply_id: "99999999-9999-4999-8999-999999999999",
      session_digest: "browser-review-session",
      citizen_message: "Private analytics review prompt",
      bot_reply_text: "Private analytics review answer",
      value: "not_helpful",
      locale: "sr",
      metadata: {
        "outcome" => "success",
        "answer_intent" => "waste",
        "reply_length" => 72,
        "quick_replies_count" => 2,
        "raw_message" => "Private analytics review prompt",
        "raw_reply" => "Private analytics review answer",
        "token" => "browser-review-token"
      }
    )
  end

  def create_reward_fulfillment!(**attributes)
    ledger = Decidim::Bih::Goodwill::Ledger.new
    ledger.award(@citizen, attributes.fetch(:cost, 10) + 100, reason: "test-seed")
    transaction = ledger.spend(
      owner: @citizen,
      amount: attributes.fetch(:cost, 10),
      kind: "redeem",
      reason: "reward:#{attributes.fetch(:reward_key)}"
    )

    defaults = {
      organization: @organization,
      ledger_transaction: transaction,
      user: @citizen,
      reward_key: "browser_reward",
      cost: 10,
      status: "requested"
    }

    Decidim::Bih::Goodwill::RewardFulfillment.create!(defaults.merge(attributes))
  end
end
