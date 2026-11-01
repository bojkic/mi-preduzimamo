# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Extends Decidim's normal SMS action authorization only for the naming
    # campaign. A granted SMS authorization is still mandatory; after that, the
    # participant must have a private Komšiluk assignment matching the proposal.
    class KomsilukNamingActionAuthorizer < Decidim::Verifications::DefaultActionAuthorizer
      CAMPAIGN = KomsilukNamingCampaign
      I18N_SCOPE = "decidim_app.bijeljina.komsiluk_naming_campaign.authorization"

      def authorize
        default_result = super
        return default_result unless default_result.first == :ok && CAMPAIGN.component?(component)

        authorize_campaign_participation
      end

      private

      def authorize_campaign_participation
        user = authorization&.user
        expected_taxonomy_id = CAMPAIGN.taxonomy_id_for_user(user)
        return denied(:komsiluk_required) unless expected_taxonomy_id

        # The vote permission is also used by Decidim for unvoting. Always let a
        # participant remove an existing vote, even if they changed their private
        # Komšiluk selection after casting it.
        return success if removable_vote?(user)

        if resource
          resource_taxonomy_id = CAMPAIGN.taxonomy_id_for_resource(resource)
          return denied(:wrong_komsiluk) unless resource_taxonomy_id == expected_taxonomy_id
        end

        prior_ids = CAMPAIGN.participant_taxonomy_ids(user, component)
        return denied(:campaign_area_locked) if prior_ids.any? && prior_ids != Set[expected_taxonomy_id]

        success
      end

      def removable_vote?(user)
        resource.respond_to?(:voted_by?) && resource.voted_by?(user)
      end

      def success
        [:ok, {}]
      end

      def denied(reason)
        [
          :unauthorized,
          {
            extra_explanation: {
              key: "#{I18N_SCOPE}.#{reason}",
              params: {}
            }
          }
        ]
      end
    end
  end
end
