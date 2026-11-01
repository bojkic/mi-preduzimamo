# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceProjection < ApplicationRecord
      self.table_name = "decidim_app_city_service_projections"
      belongs_to :incident, class_name: "DecidimApp::Bijeljina::CityServiceIncident"
      belongs_to :komsiluk, class_name: "Decidim::Bih::LocalArea"
      belongs_to :post, class_name: "Decidim::Bih::KomsilukPost"
    end
  end
end
