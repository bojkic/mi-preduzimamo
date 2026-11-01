# frozen_string_literal: true

require "test_helper"
require "capybara"
require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module Decidim
  module Bih
    class DonationsPageTest < ActionDispatch::IntegrationTest
      FakeTotals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride

      FakeProject = Struct.new(
        :decidim_project_id,
        :title,
        :donate_url,
        :totals,
        :community_project,
        keyword_init: true
      )

      FakeProvider = Struct.new(:totals, :donate_url, :currency_label, :donation_presets, :project_mappings,
                                keyword_init: true)

      setup do
        @organization = create_organization
        host! @organization.host
        @original_provider = Decidim::Bih.donations_provider
        @original_support_email = Decidim::Bih.public_support_email
        Decidim::Bih.public_support_email = "support@example.invalid"
      end

      teardown do
        Decidim::Bih.donations_provider = @original_provider
        Decidim::Bih.public_support_email = @original_support_email
      end

      test "shows aggregate and project totals without a parallel checkout surface" do
        Decidim::Bih.donations_provider = FakeProvider.new(
          totals: FakeTotals.new(total: 1250, count: 8, currency: "BAM", as_of: Time.current),
          donate_url: "https://donations.example.invalid",
          currency_label: "KM",
          donation_presets: [10, 25, 50],
          project_mappings: [
            FakeProject.new(
              decidim_project_id: 321,
              title: "Izmišljeni vrtić",
              donate_url: "https://donations.example.invalid?utm_campaign=synthetic-school",
              totals: FakeTotals.new(total: 300, count: 2, currency: "BAM", as_of: Time.current),
              community_project: false
            ),
            FakeProject.new(
              decidim_project_id: 322,
              title: "Izmišljeni park",
              donate_url: "https://donations.example.invalid?utm_campaign=synthetic-park",
              totals: FakeTotals.new(total: 100, count: 1, currency: "BAM", as_of: Time.current),
              community_project: true
            )
          ]
        )

        get "/biceriseno/donacije"

        assert_response :success
        assert_select ".mi-donation-hero[data-donation-state='available']"
        assert_select ".mi-card-grid .mi-project-card"
        assert_includes response.body, "1.250"
        assert_includes response.body, "Izmišljeni vrtić"
        assert_includes response.body, "Izmišljeni park"
        assert_select ".mi-donation-project-group[data-project-kind='community']", count: 1
        assert_select ".mi-donation-project-group[data-project-kind='participatory-budget']", count: 1
        assert_includes response.body, I18n.t("decidim.bih.donations.show.community_projects_title")
        assert_includes response.body, I18n.t("decidim.bih.donations.show.participatory_budget_projects_title")
        assert_select ".mi-donation-hero a[href='/biceriseno/projekti']", count: 1
        assert_select "a[href='/biceriseno/projekti/321']", minimum: 1
        assert_not_includes response.body, "utm_campaign=synthetic-school"
        assert_not_includes response.body, "https://donations.example.invalid"
        assert_not_includes response.body, "10 KM"
        assert_includes response.body, "300 KM"
        assert_select ".mi-donation-notes p", text: I18n.t("decidim.bih.donations.show.accountability_note", locale: @organization.default_locale)
        assert_select ".mi-donation-notes p", text: I18n.t("decidim.bih.donations.show.donor_privacy_note", locale: @organization.default_locale)
      end

      test "provider availability prevents another tenant from seeing aggregate totals or checkout" do
        provider = FakeProvider.new(
          totals: FakeTotals.new(total: 99_999, count: 40, currency: "BAM", as_of: Time.current),
          donate_url: "https://foundation.example/checkout",
          currency_label: "KM",
          donation_presets: [100],
          project_mappings: []
        )
        provider.define_singleton_method(:available_for?) { |organization:| organization.host == "allowed.example" }
        Decidim::Bih.donations_provider = provider

        get "/biceriseno/donacije"

        assert_response :success
        assert_not_includes response.body, "99.999"
        assert_not_includes response.body, "foundation.example"
      end

      test "missing provider has an unavailable message without fabricated amount or count" do
        Decidim::Bih.donations_provider = nil
        get "/biceriseno/donacije"
        assert_response :success
        assert_select ".mi-donation-hero[data-donation-state='unavailable']"
        assert_select ".mi-donation-unavailable[role='status']"
        assert_select ".mi-donation-total", count: 0
        assert_select ".mi-donation-count", count: 0
        assert_select ".mi-donation-hero a[href='/biceriseno/projekti']", count: 1
      end

      test "a measured zero still displays a real amount and count" do
        Decidim::Bih.donations_provider = FakeProvider.new(
          totals: FakeTotals.new(total: 0, count: 0, currency: "BAM", as_of: Time.current),
          currency_label: "KM", project_mappings: []
        )
        get "/biceriseno/donacije"
        assert_response :success
        assert_select ".mi-donation-hero[data-donation-state='available']"
        assert_select ".mi-donation-total strong", text: "0"
        assert_select ".mi-donation-count", count: 1
        assert_select ".mi-donation-unavailable", count: 0
      end

      test "missing future and malformed observation times do not publish amounts or unallocated funds" do
        [nil, 1.day.from_now, "not-a-trusted-time"].each do |as_of|
          Decidim::Bih.donations_provider = FakeProvider.new(
            totals: FakeTotals.new(total: 999, count: 7, currency: "BAM", as_of:),
            currency_label: "KM", project_mappings: []
          )
          get "/biceriseno/donacije"
          assert_response :success
          assert_select ".mi-donation-hero[data-donation-state='unavailable']"
          assert_select ".mi-donation-total, .mi-donation-count", count: 0
          assert_select ".mi-project-card--muted", count: 0
        end
      end

      test "project navigation and individually known amounts survive an unavailable aggregate" do
        Decidim::Bih.donations_provider = FakeProvider.new(
          totals: FakeTotals.new(total: 999, count: 7, currency: "BAM", as_of: nil),
          currency_label: "KM", project_mappings: [
            FakeProject.new(decidim_project_id: 321, title: "Izmišljeni poznati zbir", community_project: true,
                            totals: FakeTotals.new(total: 300, count: 2, currency: "BAM", as_of: Time.current)),
            FakeProject.new(decidim_project_id: 322, title: "Izmišljeni nepripremljeni zbir", community_project: true,
                            totals: FakeTotals.new(total: 999, count: 7, currency: "BAM", as_of: nil))
          ]
        )
        get "/biceriseno/donacije"
        assert_response :success
        assert_select ".mi-donation-hero[data-donation-state='unavailable']"
        assert_select ".mi-project-card", count: 2
        assert_select "a[href='/biceriseno/projekti/321']", minimum: 1
        assert_select "a[href='/biceriseno/projekti/322']", minimum: 1
        assert_includes response.body, "300 KM"
        assert_not_includes response.body, "999 KM"
        assert_select ".mi-project-card--muted", count: 0
      end

      test "a known aggregate does not invent an unallocated balance from an unknown project total" do
        Decidim::Bih.donations_provider = FakeProvider.new(
          totals: FakeTotals.new(total: 1250, count: 8, currency: "BAM", as_of: Time.current),
          currency_label: "KM", project_mappings: [
            FakeProject.new(decidim_project_id: 321, title: "Izmišljeni nepripremljeni projekat", community_project: true,
                            totals: FakeTotals.new(total: 500, count: 2, currency: "BAM", as_of: nil))
          ]
        )
        get "/biceriseno/donacije"
        assert_response :success
        assert_select ".mi-donation-hero[data-donation-state='available']"
        assert_select ".mi-donation-total strong", text: "1.250"
        assert_select ".mi-project-card", count: 1
        assert_select ".mi-project-card--muted", count: 0
        assert_not_includes response.body, "500 KM"
        assert_not_includes response.body, "750 KM"
      end

      test "all four application languages explain unavailable totals" do
        @organization.update!(available_locales: %w(sr sr-Cyrl bs hr))
        Decidim::Bih.donations_provider = nil
        %w(sr sr-Cyrl bs hr).each do |locale|
          get "/biceriseno/donacije", params: { locale: }
          assert_response :success
          assert_select ".mi-donation-unavailable strong", text: I18n.t("decidim.bih.donations.show.total_unavailable", locale:)
          assert_select ".mi-donation-total, .mi-donation-count", count: 0
        end
      end

      test "links participatory-budget projects to native pages and support projects to the dedicated catalog" do
        process = create(:participatory_process, organization: @organization, published_at: Time.current)
        component = create(:budgets_component, participatory_space: process, published_at: Time.current)
        native_project = create(:project, budget: create(:budget, component:))
        native_path = Decidim::EngineRouter.main_proxy(component).budget_project_path(
          budget_id: native_project.budget.id,
          id: native_project.id
        )
        zero = FakeTotals.new(total: 0, count: 0, currency: "BAM", as_of: Time.current)
        Decidim::Bih.donations_provider = FakeProvider.new(
          totals: zero,
          currency_label: "KM",
          project_mappings: [
            FakeProject.new(
              decidim_project_id: native_project.id,
              title: "Projekat glasanja",
              totals: zero,
              community_project: false
            ),
            FakeProject.new(
              decidim_project_id: 999_999,
              title: "Projekat podrške",
              totals: zero,
              community_project: true
            )
          ]
        )

        get "/biceriseno/donacije"

        assert_response :success
        assert_select "a[href='#{native_path}']", minimum: 1
        assert_select "a[href='/biceriseno/projekti/999999']", minimum: 1
      end
    end
  end
end
