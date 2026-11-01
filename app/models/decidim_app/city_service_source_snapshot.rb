# frozen_string_literal: true

module DecidimApp
  # Public source materializations only. Never store member/operational payloads.
  class CityServiceSourceSnapshot < ApplicationRecord
    self.table_name = "city_service_source_snapshots"

    validates :source_key, :source_version, presence: true
    validates :source_key, uniqueness: true
  end
end
