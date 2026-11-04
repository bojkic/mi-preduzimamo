# frozen_string_literal: true

require "application_system_test_case"

class GoodwillPublicPagesTest < ApplicationSystemTestCase
  FakeTotals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride
  FakeProvider = Struct.new(:totals, :donate_url, :currency_label, :donation_presets, keyword_init: true)

  setup do
    @organization = create_organization
    use_organization_host!(@organization)
    @original_provider = Decidim::Bih.donations_provider
    Decidim::Bih.donations_provider = FakeProvider.new(
      totals: FakeTotals.new(total: 1250, count: 8, currency: "BAM", as_of: Time.current),
      donate_url: "https://fondacijabijeljina.com",
      currency_label: "KM",
      donation_presets: [10, 25, 50]
    )
    @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Mila Gradjanka")
    @opportunity = Decidim::Bih::VolunteerOpportunity.create!(
      organization: @organization,
      title: "Ciscenje parka",
      description: "Subotnja akcija",
      active: true
    )
    @full_opportunity = Decidim::Bih::VolunteerOpportunity.create!(
      organization: @organization,
      title: "Puna volonterska smjena",
      description: "Ogranicen broj mjesta",
      capacity: 1,
      active: true,
      review_status: "approved"
    )
    @other_citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
    Decidim::Bih::VolunteerSignup.create!(
      organization: @organization,
      opportunity: @full_opportunity,
      user: @other_citizen,
      status: "going",
      review_status: "automatic",
      review_source: "automatic"
    )
    Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 600, reason: "volunteer_hour")
  end

  teardown do
    Decidim::Bih.donations_provider = @original_provider
  end

  test "public goodwill pages render key content without horizontal overflow" do
    visit "/biceriseno/donacije"
    accept_data_consent!
    assert_selector "body", text: "1.250"
    assert_selector ".mi-donation-count", text: I18n.t("decidim.bih.donations.show.count", count: 8)
    assert_link I18n.t("decidim.bih.donations.show.browse_projects"), href: "/biceriseno/projekti?locale=sr"
    assert_selector ".mi-donation-notes", text: I18n.t("decidim.bih.donations.show.donor_privacy_note")
    assert_no_horizontal_overflow!

    visit "/biceriseno/uticaj"
    accept_data_consent!
    assert_selector "body", text: I18n.t("decidim.bih.impact.index.title")
    assert_selector "body", text: /#{Regexp.escape(I18n.t("decidim.bih.impact.index.trends.eyebrow"))}/i
    assert_selector "body", text: "1.250 KM"
    assert_no_horizontal_overflow!

    visit "/biceriseno/volontiranje"
    accept_data_consent!
    assert_selector "body", text: "Ciscenje parka"
    assert_selector "body", text: I18n.t("decidim.bih.volunteer.index.opportunities")
    assert_no_horizontal_overflow!

    visit "/biceriseno/nagrade"
    accept_data_consent!
    assert_selector "body", text: I18n.t("decidim.bih.goodwill.rewards.majica")
    assert_no_horizontal_overflow!

    visit "/biceriseno/tabla"
    accept_data_consent!
    assert_selector "body", text: "Mila Gradjanka"
    assert_no_horizontal_overflow!
  end

  test "volunteering explains pending review only when applications require review" do
    Decidim::Bih.stub(:volunteer_application_review_required, true) do
      visit "/biceriseno/volontiranje"
      accept_data_consent!
      assert_selector "#prilike li", text: I18n.t("decidim.bih.volunteer.index.lifecycle.application_review", locale: :sr)
      assert_selector "#prilike li", text: I18n.t("decidim.bih.volunteer.index.lifecycle.place_review", locale: :sr)
    end

    Decidim::Bih.stub(:volunteer_application_review_required, false) do
      visit "/biceriseno/volontiranje"
      assert_selector "#prilike li", text: I18n.t("decidim.bih.volunteer.index.lifecycle.place", locale: :sr)
      assert_no_selector "#prilike li", text: I18n.t("decidim.bih.volunteer.index.lifecycle.application_review", locale: :sr)
    end
  end

  test "signed-in citizen sees wallet and can submit volunteer availability" do
    sign_in_user! @citizen

    visit "/biceriseno/moj-doprinos"
    accept_data_consent!
    assert_selector "body", text: "Moj doprinos"
    assert_selector "body", text: "Volonterski sat"
    assert_no_horizontal_overflow!

    visit "/biceriseno/nagrade"
    accept_data_consent!
    assert_selector "body", text: I18n.t("decidim.bih.rewards.show.your_balance")
    assert_selector "body", text: "600"
    assert_no_horizontal_overflow!

    visit "/biceriseno/volontiranje"
    accept_data_consent!
    assert_no_selector ".mi-choice-grid--days"
    find_by_id("mi-install-close").click if page.has_selector?("#mi-install-close", wait: 0)
    within ".mi-volunteer-tabs" do
      availability_link = find_link(I18n.t("decidim.bih.volunteer.index.tabs.dostupnost"))
      availability_uri = URI.parse(availability_link[:href])
      assert_equal "/biceriseno/volontiranje", availability_uri.path
      assert_equal({ "locale" => "sr", "tab" => "dostupnost" }, Rack::Utils.parse_query(availability_uri.query))
      assert_equal "dostupnost", availability_uri.fragment
      assert_not_equal "_blank", availability_link[:target]
      availability_link.click
    end
    assert_current_path "/biceriseno/volontiranje?locale=sr&tab=dostupnost"
    assert_no_selector "input[type='datetime-local']"
    assert_selector ".mi-choice-grid--days", text: "Ponedjeljak"
    assert_selector ".mi-choice-grid--months", text: "Januar"
    assert_selector ".mi-choice-grid--time", text: "Popodne/Veče"
    assert_selector ".mi-choice-pill", text: "Rad na terenu"
    assert_selector ".mi-choice-pill", text: "Digitalna podrška"
    assert_equal "\"✓\"", page.evaluate_script(<<~JS.squish)
      window.getComputedStyle(
        document.querySelector(".mi-choice-grid--days .mi-choice-pill input:checked + span"),
        "::before"
      ).content
    JS
    form = find("form[action='/biceriseno/volontiranje/dostupnost?locale=sr']")
    within form do
      find("textarea[name='availability']").fill_in with: "Subotom prijepodne"
      find("textarea[name='interests']").fill_in with: "Parkovi i dvorista"
    end
    form.native.submit

    assert_eventually_equal 610, -> { Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen).contribution_score }

    visit "/biceriseno/volontiranje"
    accept_data_consent!
    assert_button I18n.t("decidim.bih.volunteer.index.join_waitlist")
    click_button I18n.t("decidim.bih.volunteer.index.join_waitlist")

    assert_eventually_equal 1, lambda {
      Decidim::Bih::VolunteerSignup.waitlisted.where(
        opportunity: @full_opportunity,
        user: @citizen
      ).count
    }
  end

  private

  def assert_eventually_equal(expected, probe, timeout: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    actual = probe.call

    until actual == expected || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.1
      actual = probe.call
    end

    assert_equal expected, actual
  end
end
