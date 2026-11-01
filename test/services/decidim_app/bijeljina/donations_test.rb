# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require_relative "../../../support/synthetic_donations_configuration"
require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module DecidimApp
  module Bijeljina
    class DonationsTest < ActiveSupport::TestCase
      include SyntheticDonationsConfiguration
      setup { install_synthetic_donations_configuration }
      teardown { restore_synthetic_donations_configuration }
      ODOO_URL = "https://odoo.test"
      RPC = "#{ODOO_URL}/jsonrpc".freeze

      # Make the host wrapper's ENV-built Odoo client `configured?` so the real
      # refresh chain (host #refresh! -> engine service -> Client HTTP -> cache)
      # runs end-to-end against WebMock, instead of short-circuiting to zero.
      def with_odoo_env
        previous = ENV.to_hash.slice("ODOO_URL", "ODOO_DB", "ODOO_LOGIN", "ODOO_API_KEY")
        ENV["ODOO_URL"] = ODOO_URL
        ENV["ODOO_DB"] = "fdb"
        ENV["ODOO_LOGIN"] = "odoo-user@example.invalid"
        ENV["ODOO_API_KEY"] = "key"
        yield
      ensure
        %w(ODOO_URL ODOO_DB ODOO_LOGIN ODOO_API_KEY).each { |k| ENV.delete(k) }
        previous.each { |k, v| ENV[k] = v }
      end

      def stub_odoo_rows(rows)
        stub_request(:post, RPC)
          .with(body: hash_including("params" => hash_including("method" => "authenticate")))
          .to_return(status: 200, body: { result: 2 }.to_json)
        stub_request(:post, RPC)
          .with(body: hash_including("params" => hash_including("method" => "execute_kw")))
          .to_return(status: 200, body: { result: rows }.to_json)
      end

      def stub_odoo_fault
        stub_request(:post, RPC)
          .to_return(status: 200, body: { error: { data: { message: "boom" } } }.to_json)
      end

      test "the public initializer activates the explicitly configured community provider" do
        prior = Decidim::Bih.donations_provider
        load Rails.root.join("config/initializers/decidim_bih_donations.rb")
        assert_same Donations, Decidim::Bih.donations_provider
        assert Donations.configured?
      ensure
        Decidim::Bih.donations_provider = prior
      end

      test "empty setup leaves the provider unavailable without a checkout link" do
        prior = Decidim::Bih.donations_provider
        restore_synthetic_donations_configuration
        install_synthetic_donations_configuration(data: {})
        load Rails.root.join("config/initializers/decidim_bih_donations.rb")
        assert_nil Decidim::Bih.donations_provider
        assert_nil Donations.donate_url
        assert_nil Donations.donate_url(campaign: "synthetic-campaign")
        assert_not Donations.configured?
      ensure
        Decidim::Bih.donations_provider = prior
      end

      test "a transient Odoo failure leaves the previously cached non-zero total intact" do
        previous_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new

        with_odoo_env do
          WebMock.disable_net_connect!(allow_localhost: true)

          # Seed a non-zero last-known-good total via a successful refresh.
          stub_odoo_rows([{ "price_total" => 500.0, "order_id" => [42, "S42"] }])
          Donations.refresh!
          assert_equal BigDecimal("500"), Donations.totals.total

          # A transient Odoo fault on the next (cron) refresh must not zero it.
          WebMock.reset!
          stub_odoo_fault
          Donations.refresh!

          assert_equal BigDecimal("500"), Donations.totals.total
        end
      ensure
        WebMock.reset!
        WebMock.allow_net_connect!
        Rails.cache = previous_cache
      end

      test "project donation URLs carry the Odoo UTM campaign slug" do
        url = Donations.donate_url(campaign: "mi-project")

        assert_equal "https", URI(url).scheme
        assert_equal "donations.example.invalid", URI(url).host

        params = URI.decode_www_form(URI(url).query).to_h
        assert_equal "donations-community.example.invalid", params.fetch("utm_source")
        assert_equal "decidim", params.fetch("utm_medium")
        assert_equal "mi-project", params.fetch("utm_campaign")
      end

      test "keeps the aggregate donation URL unchanged" do
        assert_equal "https://donations.example.invalid", Donations.donate_url
      end

      test "aggregate provider is available only for the configured community tenant" do
        community = create_organization(host: Donations::ORGANIZATION_HOST)
        other = create_organization

        assert Donations.available_for?(organization: community)
        assert_not Donations.available_for?(organization: other)
      end

      test "campaign preflight accepts only an exact active Odoo campaign in the configured community tenant" do
        organization = create_organization(host: Donations::ORGANIZATION_HOST)
        client = Struct.new(:rows) do
          def read(*) = rows
        end

        assert Donations.campaign_ready?(
          "reviewed-campaign",
          organization:,
          client: client.new([{ "id" => 7, "name" => "reviewed-campaign", "active" => true }])
        )
        assert_not Donations.campaign_ready?(
          "reviewed-campaign",
          organization:,
          client: client.new([{ "id" => 7, "name" => "other-campaign", "active" => true }])
        )
        assert_not Donations.campaign_ready?(
          "reviewed-campaign",
          organization:,
          client: client.new([{ "id" => 7, "name" => "reviewed-campaign", "active" => false }])
        )
        [{ "id" => 7, "name" => "reviewed-campaign" },
         { "id" => 7, "name" => "reviewed-campaign", "active" => nil },
         { "id" => 7, "name" => "reviewed-campaign", "active" => "true" },
         "malformed"].each do |row|
          assert_not Donations.campaign_ready?("reviewed-campaign", organization:, client: client.new([row]))
        end
      end

      test "builds project mappings from tenant-scoped donation links and native titles" do
        organization = create_organization
        process = create(:participatory_process, organization:, published_at: Time.current)
        component = create(:budgets_component, participatory_space: process, published_at: Time.current)
        budget = create(:budget, component:)
        project = create(
          :project,
          budget:,
          title: { "sr" => "Izvorni naslov", "en" => "Canonical title" }
        )
        Decidim::Bih::ProjectDonationLink.create!(
          organization:,
          project:,
          campaign_key: "approved-project"
        )

        mapping = I18n.with_locale(:sr) { Donations.project_mappings(organization:).sole }

        assert_equal project.id, mapping.decidim_project_id
        assert_equal "Izvorni naslov", mapping.title
        assert_equal "approved-project", mapping.campaign
        assert_includes mapping.donate_url, "utm_campaign=approved-project"
        assert_not mapping.community_project
      end

      test "exposes approved community projects from the hidden storage hierarchy" do
        organization = create_organization
        budget = CommunityProjectsSetup.call(organization:, publish: true)
        representative = create(:user, :confirmed, organization:)
        reviewer = create(:user, :confirmed, :admin, organization:)
        profile = Decidim::Bih::PartnerProfile.create!(
          organization:,
          display_name: "Partner podrške",
          slug: "partner-podrske",
          kind: "business",
          verification_status: "verified",
          verified_at: Time.current
        )
        profile.memberships.create!(
          organization:,
          user: representative,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )
        project = create(:project, budget:, title: { "sr" => "Projekat podrške" })
        Decidim::Bih::PartnerProjectSubmission.create!(
          organization:,
          partner_profile: profile,
          representative:,
          reviewer:,
          project:,
          title: "Projekat podrške",
          description: "Detaljan opis projekta podrške zajednici",
          budget_amount: project.budget_amount,
          review_status: "approved",
          submitted_at: 1.hour.ago,
          reviewed_at: Time.current
        )
        Decidim::Bih::ProjectDonationLink.create!(
          organization:,
          project:,
          campaign_key: "projekat-podrske"
        )

        mapping = Donations.project_mappings(organization:).sole

        assert mapping.community_project
        assert_not budget.participatory_space.published?
        assert budget.component.published?
      end

      test "does not expose a linked project after its native component is unpublished" do
        organization = create_organization
        process = create(:participatory_process, organization:, published_at: Time.current)
        component = create(:budgets_component, participatory_space: process, published_at: Time.current)
        project = create(:project, budget: create(:budget, component:))
        Decidim::Bih::ProjectDonationLink.create!(
          organization:,
          project:,
          campaign_key: "temporarily-public"
        )

        assert_equal [project.id], Donations.project_mappings(organization:).map(&:decidim_project_id)

        component.update!(published_at: nil)

        assert_empty Donations.project_mappings(organization:)
      end

      test "does not expose another tenant's project mapping" do
        first = create_organization
        second = create_organization
        process = create(:participatory_process, organization: first, published_at: Time.current)
        component = create(:budgets_component, participatory_space: process, published_at: Time.current)
        project = create(:project, budget: create(:budget, component:))
        Decidim::Bih::ProjectDonationLink.create!(
          organization: first,
          project:,
          campaign_key: "first-org"
        )

        assert_empty Donations.project_mappings(organization: second)
      end

      test "default reads stay on the configured community tenant and equal campaign keys have isolated caches" do
        community = create_organization(host: Donations::ORGANIZATION_HOST)
        second = create_organization
        campaign = "shared-provider-key"

        projects = [community, second].map do |organization|
          process = create(:participatory_process, organization:, published_at: Time.current)
          component = create(:budgets_component, participatory_space: process, published_at: Time.current)
          project = create(:project, budget: create(:budget, component:))
          Decidim::Bih::ProjectDonationLink.create!(organization:, project:, campaign_key: campaign)
          project
        end

        assert_equal [projects.first.id], Donations.project_mappings.map(&:decidim_project_id)

        cache_keys = [community, second].map do |organization|
          mapping = Donations.send(:mapping_configs, organization:).sole
          Donations.send(:project_service, mapping).cache_key
        end

        assert_not_equal cache_keys.first, cache_keys.last
        assert_includes cache_keys.first, "/organization/#{community.id}/"
        assert_includes cache_keys.last, "/organization/#{second.id}/"
      end
    end
  end
end
