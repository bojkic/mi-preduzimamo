# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceDuplicateDecision < ApplicationRecord
      self.table_name = "decidim_app_city_service_duplicate_decisions"
      validates :decision, inclusion: { in: %w(same separate undo) }
    end
  end
end
