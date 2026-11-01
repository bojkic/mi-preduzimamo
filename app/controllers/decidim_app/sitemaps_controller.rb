# frozen_string_literal: true

module DecidimApp
  class SitemapsController < Decidim::ApplicationController
    def show
      @origin = "https://#{current_organization.host}"
      @paths = MiSearchHelper::SITEMAP_PATHS
      render formats: [:xml], layout: false
    end
  end
end
