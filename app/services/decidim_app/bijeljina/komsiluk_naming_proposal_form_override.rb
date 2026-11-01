# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module KomsilukNamingProposalFormOverride
      CAMPAIGN = KomsilukNamingCampaign
      I18N_SCOPE = "decidim_app.bijeljina.komsiluk_naming_campaign.errors"

      def self.prepended(base)
        base.validate :validate_komsiluk_naming_eligibility
      end

      # Decidim::Form uses ActiveModel validations without the
      # before_validation macro. Assign before the validation chain so the
      # built-in taxonomy validator and the proposal command see the same area.
      def valid?(context = nil)
        assign_komsiluk_naming_taxonomy
        super
      end

      # The campaign taxonomy comes from the participant's private profile. Do
      # not render a 92-item selector that would imply they may choose any area.
      def taxonomy_filters
        return [] if CAMPAIGN.component?(current_component)

        super
      end

      private

      def assign_komsiluk_naming_taxonomy
        return unless CAMPAIGN.component?(current_component)

        taxonomy_id = CAMPAIGN.taxonomy_id_for_user(current_user)
        return unless taxonomy_id

        self.taxonomies = [taxonomy_id]
        remove_instance_variable(:@compact_taxonomies) if defined?(@compact_taxonomies)
        remove_instance_variable(:@taxonomizations) if defined?(@taxonomizations)
      end

      def validate_komsiluk_naming_eligibility
        return unless CAMPAIGN.component?(current_component)

        taxonomy_id = CAMPAIGN.taxonomy_id_for_user(current_user)
        unless taxonomy_id
          errors.add(:base, I18n.t("#{I18N_SCOPE}.komsiluk_required"))
          return
        end

        prior_ids = CAMPAIGN.participant_taxonomy_ids(current_user, current_component)
        return if prior_ids.empty? || prior_ids == Set[taxonomy_id]

        errors.add(:base, I18n.t("#{I18N_SCOPE}.campaign_area_locked"))
      end
    end
  end
end
