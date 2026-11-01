# frozen_string_literal: true

require "bigdecimal"

module DecidimApp
  module Bijeljina
    # The two native proposal components share a process, not a ballot.
    # Current selected neighbourhood determines eligibility, including new members.
    module RaceProjectSelection
      PROCESS_SLUG = "komsiluci-biraju"
      NAMESPACE = "race_projects"

      module_function

      def settings(organization)
        Decidim::Bih::Setting.namespace_for(organization, NAMESPACE)
      end

      # Names come from accepted standings in this organization, never from
      # bundled local results. Callers escape names at the HTML boundary.
      def winner_names(organization, locale: "sr")
        standings = Decidim::Bih::Race::Standings.new(organization)
        %w(grad selo).map do |zone|
          winner = standings.leader(zone)
          raise ArgumentError, "both final winners required" unless winner

          localized_name(winner.komsiluk.name, locale:)
        end
      end

      def localized_name(value, locale: "sr")
        name = if value.is_a?(Hash)
                 value[locale].presence || value["sr"].presence || value["en"].presence || value.values.find(&:present?)
               else
                 value
               end
        raise ArgumentError, "community display name required" if name.blank?

        name.to_s
      end

      def budget_scope(organization)
        value = settings(organization)["project_budget_bam"]
        return "u okviru objavljenog budžeta procesa" if value.blank?

        amount = BigDecimal(value.to_s)
        raise ArgumentError, "positive finite project budget required" unless amount.finite? && amount.positive?

        "do #{ActiveSupport::NumberHelper.number_to_currency(amount, unit: "KM", format: "%n %u", precision: 2, delimiter: ".", separator: ",")}"
      end

      def process(organization)
        Decidim::ParticipatoryProcess.find_by(organization:, slug: PROCESS_SLUG)
      end

      def published_process(organization)
        record = process(organization)
        record if record&.published? && !record.private_space? && !record.deleted?
      end

      def component?(component)
        component&.manifest_name == "proposals" &&
          component.participatory_space.is_a?(Decidim::ParticipatoryProcess) &&
          component.participatory_space.slug == PROCESS_SLUG
      end

      def area_id(component)
        settings(component.organization).fetch("component_areas", {})[component.id.to_s]&.to_i if component?(component)
      end

      def eligible_voter?(user, component)
        return false unless eligible_account?(user, component)

        return false unless phone_verified?(user)

        target = area_id(component)
        target.present? && Decidim::Bih::CitizenProfile.exists?(
          decidim_organization_id: component.organization.id,
          decidim_user_id: user.id,
          komsiluk_id: target
        )
      end

      def eligible_account?(user, component)
        user && component?(component) && user.decidim_organization_id == component.organization.id &&
          !user.blocked? && !user.deleted?
      end

      def phone_verified?(user)
        authorization = Decidim::Authorization.find_by(user:, name: "sms")
        authorization&.granted? && !authorization.expired?
      end

      def voting_open?(component)
        component.published? && component.participatory_space.published? &&
          component.current_settings.votes_enabled? && !component.current_settings.votes_blocked?
      end

      def vote_allowed?(user, component)
        voting_open?(component) && eligible_voter?(user, component)
      end

      def links(organization)
        record = published_process(organization)
        return [] unless record

        record.components.published.where(manifest_name: "proposals").order(:weight, :id).map do |component|
          { name: component.name, path: Decidim::EngineRouter.main_proxy(component).root_path,
            new_path: Decidim::EngineRouter.main_proxy(component).new_proposal_path }
        end
      end

      def process_path
        "/processes/#{PROCESS_SLUG}"
      end
    end
  end
end
