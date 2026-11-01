# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceIncident < ApplicationRecord
      self.table_name = "decidim_app_city_service_incidents"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      has_many :events, class_name: "DecidimApp::Bijeljina::CityServiceEvent", foreign_key: :incident_id, dependent: :restrict_with_exception
      has_many :projections, class_name: "DecidimApp::Bijeljina::CityServiceProjection", foreign_key: :incident_id, dependent: :restrict_with_exception
      validates :identity_key, :service, presence: true

      # One lock order for publication, ingestion and operator incident decisions.
      def self.synchronize(organization)
        transaction do
          key = Digest::SHA256.hexdigest("city-notices:#{organization.id}")[0, 15].to_i(16)
          connection.execute("SELECT pg_advisory_xact_lock(#{key})")
          yield
        end
      end
    end
  end
end
