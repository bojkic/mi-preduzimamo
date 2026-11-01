# frozen_string_literal: true

module DecidimApp
  class LaunchEventDelivery < ApplicationRecord
    self.table_name = "decidim_app_launch_event_deliveries"
    belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
    belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
    belongs_to :actor, class_name: "Decidim::User", optional: true

    validates :event_key, format: { with: /\Acommunity-launch-v1:[a-f0-9]{64}\z/ }
    validate :current_event_identity, on: :create
    validates :message_key, inclusion: { in: LaunchEvent::MESSAGES.keys }
    validates :status, inclusion: { in: %w(pending sending accepted delivered rejected unknown skipped) }
    validates :expires_at, presence: true
    validate :same_organization

    def destination
      LaunchEvent::MESSAGES.fetch(message_key).fetch(:path)
    end

    # Conditional SQL is the atomic one-use boundary; validations cannot claim a token.
    # rubocop:disable Rails/SkipsModelValidations
    def claim_token!
      return false unless LaunchEvent.current_event?(organization, event_key, now: Time.current)

      self.class.where(id:, consumed_at: nil).where("expires_at > ?", Time.current)
          .update_all(consumed_at: Time.current, updated_at: Time.current) == 1
    end

    # rubocop:enable Rails/SkipsModelValidations

    private

    def current_event_identity
      errors.add(:event_key, :invalid) unless organization && event_key == LaunchEvent.event_key(organization)
    end

    def same_organization
      errors.add(:user, :invalid) unless user&.decidim_organization_id == decidim_organization_id
      errors.add(:actor, :invalid) if actor && actor.decidim_organization_id != decidim_organization_id
    end
  end
end
