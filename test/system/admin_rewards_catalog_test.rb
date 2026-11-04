# frozen_string_literal: true

require "application_system_test_case"

class AdminRewardsCatalogTest < ApplicationSystemTestCase
  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Mila Rewards QA")
    @reward = Decidim::Bih::Goodwill::Reward.create!(
      organization: @organization,
      key: "browser_majica",
      title: { "sr" => "Majica browser" },
      cost: 500,
      stock: 3,
      active: true
    )
    create_reward_fulfillment!(status: "requested")
    create_reward_fulfillment!(status: "fulfilled")
    create_reward_fulfillment!(status: "canceled")
  end

  test "admin rewards catalogue workflow tabs render cleanly" do
    sign_in_user! @admin

    visit "/admin/bih/rewards"
    accept_data_consent!

    assert_selector "#admin-rewards-header[data-rewards-active-tab='catalog']"
    assert_selector "#admin-rewards-workflow-nav a[aria-current='page'][href='/sr/admin/bih/rewards?tab=catalog']"
    assert_selector "#admin-rewards-list", text: "Majica browser"
    assert_selector "#admin-rewards-list form[action='/sr/admin/bih/rewards/#{@reward.id}/deactivate'] input[name='approval_rationale']"
    assert_no_selector "#admin-rewards-stock-review"
    assert_no_selector "#admin-rewards-diagnostics"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/rewards?tab=stock"

    assert_selector "#admin-rewards-header[data-rewards-active-tab='stock']"
    assert_selector "#admin-rewards-stock-review", text: "Majica browser"
    assert_selector "#admin-rewards-stock-review", text: "Zauzeto"
    assert_selector "#admin-rewards-stock-review td", text: "2"
    assert_selector "#admin-rewards-stock-review td", text: "1"
    assert_no_selector "#admin-rewards-stock-review form[action='/sr/admin/bih/rewards/#{@reward.id}/deactivate']"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!

    visit "/admin/bih/rewards?tab=diagnostics"

    assert_selector "#admin-rewards-header[data-rewards-active-tab='diagnostics']"
    assert_selector "#admin-rewards-diagnostics", text: "Dijagnostika kataloga"
    find("#admin-rewards-diagnostics summary").click
    assert_selector "#admin-rewards-diagnostics", text: "decidim_bih:goodwill:import_rewards_catalog"
    assert_no_selector "#admin-rewards-list"
    assert_no_horizontal_overflow!
    assert_no_browser_console_errors!
  end

  private

  def create_reward_fulfillment!(status:)
    ledger = Decidim::Bih::Goodwill::Ledger.new
    ledger.award(@citizen, @reward.cost, reason: "system-test-seed")
    transaction = ledger.spend(
      owner: @citizen,
      amount: @reward.cost,
      kind: "redeem",
      reason: "reward:#{@reward.key}"
    )

    Decidim::Bih::Goodwill::RewardFulfillment.create!(
      organization: @organization,
      ledger_transaction: transaction,
      user: @citizen,
      reward_key: @reward.key,
      cost: @reward.cost,
      status:,
      handled_by: (%w(fulfilled canceled reversed).include?(status) ? @admin : nil),
      handled_at: (%w(fulfilled canceled reversed).include?(status) ? Time.current : nil)
    )
  end
end
