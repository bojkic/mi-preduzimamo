# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class ParkingZoneStreet < ApplicationRecord
      self.table_name = "decidim_app_parking_zone_streets"

      ZONES = %w(white red blue).freeze

      scope :active, -> { where(active: true) }

      validates :street_name, :normalized_street_name, :zone,
                :source_url, :source_map_url, :source_checked_on, presence: true
      validates :normalized_street_name, uniqueness: true
      validates :zone, inclusion: { in: ZONES }
    end
  end
end
