# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module KomsilukNamingProposalVoteOverride
      CAMPAIGN = KomsilukNamingCampaign
      I18N_SCOPE = "decidim_app.bijeljina.komsiluk_naming_campaign.errors"

      def self.prepended(base)
        base.validate :validate_komsiluk_naming_vote, on: :create
      end

      private

      def validate_komsiluk_naming_vote
        return unless proposal && CAMPAIGN.component?(proposal.component)

        taxonomy_id = CAMPAIGN.taxonomy_id_for_resource(proposal)
        return if taxonomy_id && CAMPAIGN.allowed_taxonomy_for?(
          author,
          component: proposal.component,
          taxonomy_id:
        )

        errors.add(:proposal, I18n.t("#{I18N_SCOPE}.wrong_komsiluk"))
      end
    end
  end
end
