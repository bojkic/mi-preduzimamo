# frozen_string_literal: true

module DecidimApp
  # Stable, non-personal campaign links for posters and QR codes. Scanning a QR
  # only opens the correct filtered Decidim proposal list; it never assigns the
  # scanner to a Komšiluk or records an address/location.
  class KomsilukCampaignLinksController < Decidim::ApplicationController
    CAMPAIGN = DecidimApp::Bijeljina::KomsilukNamingCampaign

    def show
      area = campaign_area
      component = CAMPAIGN.component_for(current_organization)
      taxonomy_id = CAMPAIGN.taxonomy_id_for_area(area) if area
      root_taxonomy_id = CAMPAIGN.root_taxonomy_id_for(current_organization)
      return head :not_found unless area && component && taxonomy_id && root_taxonomy_id

      destination = Decidim::EngineRouter.main_proxy(component).root_path(
        filter: {
          "with_any_taxonomies" => {
            root_taxonomy_id.to_s => [taxonomy_id.to_s]
          }
        }
      )
      redirect_to destination
    end

    private

    def campaign_area
      token = params[:area].to_s
      slug = token.match?(/\A\d+\z/) ? "komsiluk-#{token.to_i}" : token

      Decidim::Bih::LocalArea.komsiluci.find_by(
        decidim_organization_id: current_organization.id,
        slug:
      )
    end
  end
end
