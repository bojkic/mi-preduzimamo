# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Public event/post identifiers only. New board effects replay the
    # publication-time receipt audience; recovery never resolves new members.
    class CityServiceEffect < ApplicationRecord
      self.table_name = "decidim_app_city_service_effects"
      belongs_to :event, class_name: "DecidimApp::Bijeljina::CityServiceEvent"
      validates :kind, inclusion: { in: %w(board fallback) }
      validates :identity, presence: true
      after_create_commit :enqueue

      def enqueue
        CityServiceEffectJob.perform_later(id)
      rescue StandardError => e
        Rails.logger.warn("[CityServiceEffect] enqueue deferred id=#{id} error=#{e.class.name}")
      end

      def self.recover_pending!
        where(completed_at: nil).where("last_attempt_at IS NULL OR last_attempt_at < ?", 5.minutes.ago).order(:id).limit(200).each(&:enqueue)
      end
    end
  end
end
