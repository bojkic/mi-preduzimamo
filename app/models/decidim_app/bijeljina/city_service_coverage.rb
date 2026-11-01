# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceCoverage < ApplicationRecord
      self.table_name = "decidim_app_city_service_coverages"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :event, class_name: "DecidimApp::Bijeljina::CityServiceEvent"
      belongs_to :reviewer, class_name: "Decidim::User"
      validates :identity_key, :source_key, :targeting_level, :valid_until, presence: true
    end
  end
end
