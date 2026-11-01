# frozen_string_literal: true

require "uri"
require_relative "donations_configuration"

module DecidimApp
  module Bijeljina
    # Reference wiring for the generic Odoo donation mirror. A community
    # explicitly supplies its own public installation configuration. Native
    # project publication, moderated submissions and tenant boundaries remain
    # the authority for project donation links.
    module Donations
      CONFIGURATION = DonationsConfiguration.load
      PRODUCT_IDS = CONFIGURATION.product_ids
      DEFAULT_CONFIRMED_STATES = %w(sale done).freeze
      DONATE_URL = CONFIGURATION.donate_url
      CURRENCY_LABEL = "KM"
      ORGANIZATION_HOST = CONFIGURATION.organization_host
      DONATION_PRESETS = CONFIGURATION.donation_presets

      ProjectMapping = Struct.new(
        :decidim_project_id,
        :title,
        :campaign,
        :donate_url,
        :totals,
        :community_project,
        keyword_init: true
      )

      # Aggregate keys include the configured host. Project keys additionally
      # retain the existing organization id and campaign namespace.
      CACHE_NAMESPACE = CONFIGURATION.cache_namespace

      class << self
        def configured? = CONFIGURATION.configured?

        # The cached totals (Decidim::Bih::Odoo::DonationTotals::Result). NEVER
        # blocks on Odoo: returns the cached value, or a zeroed value plus a
        # background refresh on a cold cache.
        def totals
          service.cached
        end

        # Recomputes synchronously and writes the cache. Called by the scheduled
        # refresh job / a rake task, never from a web request.
        def refresh!
          service.refresh!
        end

        def refresh_all!
          organization = default_organization
          mappings = organization ? mapping_configs(organization:) : []
          [refresh!] + mappings.map { |mapping| project_service(mapping).refresh! }
        end

        def donate_url(campaign: nil)
          return nil unless configured?

          campaign.present? ? tagged_donate_url(campaign) : DONATE_URL
        end

        def currency_label
          CURRENCY_LABEL
        end

        def donation_presets
          DONATION_PRESETS
        end

        def available_for?(organization:)
          configured? && organization.present? && organization.host == ORGANIZATION_HOST
        end

        # Approval-time provider preflight. A community project must reuse an
        # existing reviewed Odoo UTM campaign; a typo must not create a public
        # donation link whose aggregate can never reconcile.
        def campaign_ready?(campaign, organization:, client: Decidim::Bih::Odoo::Client.new(timeout: 5))
          return false unless available_for?(organization:)

          key = campaign.to_s.strip.downcase
          return false unless key.match?(Decidim::Bih::ProjectDonationLink::CAMPAIGN_KEY_PATTERN)

          rows = client.read("utm.campaign", [["name", "=", key]], %w(id name active), limit: 2)
          Array(rows).any? do |row|
            row.is_a?(Hash) && row["name"].to_s.strip.downcase == key && row["active"] == true
          end
        rescue StandardError => e
          Rails.logger.warn("[Donations] Odoo campaign preflight failed (#{e.class})")
          false
        end

        def project_mappings(organization: nil)
          organization ||= default_organization
          return [] unless organization

          mapping_configs(organization:).map do |mapping|
            ProjectMapping.new(
              decidim_project_id: mapping.fetch(:decidim_project_id),
              title: mapping.fetch(:title),
              campaign: mapping.fetch(:campaign),
              donate_url: donate_url(campaign: mapping.fetch(:campaign)),
              totals: project_service(mapping).cached,
              community_project: mapping.fetch(:community_project)
            )
          end
        end

        # Engine service with explicitly reviewed product and date configuration.
        def service
          Decidim::Bih::Odoo::DonationTotals.new(
            product_ids: PRODUCT_IDS,
            confirmed_states: confirmed_states,
            date_from: CONFIGURATION.date_from,
            currency: "BAM",
            cache_namespace: CACHE_NAMESPACE
          )
        end

        # Keyword args for enqueuing the engine refresh job directly (scheduler).
        def refresh_job_args
          {
            product_ids: PRODUCT_IDS,
            confirmed_states: confirmed_states,
            date_from: CONFIGURATION.date_from,
            currency: "BAM",
            cache_namespace: CACHE_NAMESPACE
          }
        end

        private

        # ProjectDonationLink is the provider-neutral, tenant-scoped source of
        # truth. The native Budget Project supplies public copy; this host owns
        # only the Odoo campaign interpretation and checkout URL.
        def mapping_configs(organization:)
          return [] unless Decidim::Bih::ProjectDonationLink.table_exists?

          scope = Decidim::Bih::ProjectDonationLink.active.includes(
            project: { budget: { component: :participatory_space } },
            partner_project_submission: :partner_profile
          )
          scope = scope.where(organization:)
          scope.order(:id).filter_map do |link|
            project = link.project
            next unless public_project?(link, project)

            {
              decidim_organization_id: link.decidim_organization_id,
              decidim_project_id: project.id,
              title: translated_title(project),
              campaign: link.campaign_key,
              community_project: link.partner_project_submission.present?
            }
          end
        rescue ActiveRecord::StatementInvalid
          []
        end

        # Donation mappings feed anonymous pages and aggregate summaries. A
        # legacy participatory-budget project remains governed by its published
        # native process. A moderated community-support project is governed by
        # operator approval and the hidden configured storage hierarchy instead; it
        # must never require or expose a second public participatory process.
        def public_project?(link, project)
          submission = link.partner_project_submission
          if submission
            public_community_project?(submission, project)
          else
            public_native_project?(project)
          end
        rescue StandardError
          false
        end

        def public_community_project?(submission, project)
          return false unless public_submission_owner?(submission)
          return false if project.blank? || project.try(:deleted_at).present?

          community_budget_matches?(submission, project) && hidden_storage_available?(submission, project)
        end

        def community_budget_matches?(submission, project)
          configured_budget_id = community_budget_id(submission.organization)

          configured_budget_id.positive? && project.budget.id == configured_budget_id
        end

        def community_budget_id(organization)
          Decidim::Bih::Setting
            .namespace_for(organization, "community_projects")
            .fetch("budget_id", nil)
            .to_i
        end

        def hidden_storage_available?(submission, project)
          component = project.component
          space = component&.participatory_space

          component&.published? && space&.organization == submission.organization && !space.published?
        end

        def public_native_project?(project)
          return false if project.blank? || project.try(:deleted_at).present?

          component = project.component
          space = component&.participatory_space
          project.visible? && component&.published? && space&.published? && participatory_space_visible?(space)
        end

        def participatory_space_visible?(space)
          !space.respond_to?(:visible?) || space.visible?
        end

        def public_submission_owner?(submission)
          return false unless submission.approved? && submission.partner_profile_id.present?

          Decidim::Bih::PartnerProfile.publicly_visible.exists?(
            id: submission.partner_profile_id,
            decidim_organization_id: submission.decidim_organization_id
          )
        end

        def translated_title(project)
          titles = project.title.to_h.stringify_keys
          titles[I18n.locale.to_s].presence ||
            titles[project.organization.default_locale.to_s].presence ||
            titles.values.find(&:present?).to_s
        end

        def confirmed_states
          CONFIGURATION.confirmed_states
        end

        def default_organization
          return nil unless configured?

          Decidim::Organization.find_by(host: ORGANIZATION_HOST)
        rescue ActiveRecord::StatementInvalid
          nil
        end

        def project_service(mapping)
          Decidim::Bih::Odoo::DonationTotals.new(
            product_ids: PRODUCT_IDS,
            confirmed_states: confirmed_states,
            date_from: CONFIGURATION.date_from,
            currency: "BAM",
            cache_namespace: [
              CACHE_NAMESPACE,
              "organization",
              mapping.fetch(:decidim_organization_id),
              "project",
              mapping.fetch(:campaign)
            ].join("/"),
            extra_domain: [["order_id.campaign_id.name", "=", mapping.fetch(:campaign)]]
          )
        end

        def tagged_donate_url(campaign)
          uri = URI(DONATE_URL)
          params = URI.decode_www_form(uri.query.to_s).to_h
          params["utm_source"] = ORGANIZATION_HOST
          params["utm_medium"] = "decidim"
          params["utm_campaign"] = campaign
          uri.query = URI.encode_www_form(params)
          uri.to_s
        end
      end
    end
  end
end
