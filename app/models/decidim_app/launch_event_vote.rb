# frozen_string_literal: true

module DecidimApp
  class LaunchEventVote < ApplicationRecord
    self.table_name = "decidim_app_launch_event_votes"
    belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
    belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
    validates :event_key, format: { with: /\Acommunity-launch-v1:[a-f0-9]{64}\z/ }
    validate :current_event_identity, on: :create
    validates :choice, inclusion: { in: LaunchEvent::CHOICES.keys }
    validate :same_organization

    private

    def current_event_identity
      errors.add(:event_key, :invalid) unless organization && event_key == LaunchEvent.event_key(organization)
    end

    def same_organization
      errors.add(:user, :invalid) unless user&.decidim_organization_id == decidim_organization_id
    end
  end
end
