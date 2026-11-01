# frozen_string_literal: true

module DecidimApp
  class LaunchEventReceiptJob < ApplicationJob
    queue_as :integrations
    self.log_arguments = false

    def perform(delivery_id, attempt = 0)
      delivery = LaunchEventDelivery.find_by(id: delivery_id)
      return unless delivery

      LaunchEvent.reconcile!(delivery)
      self.class.set(wait: 90.seconds).perform_later(delivery.id, attempt + 1) if %w(accepted rejected
                                                                                     unknown).include?(delivery.reload.status) && attempt < 2 && delivery.expires_at > Time.current
    rescue StandardError => e
      Rails.logger.warn("[launch_event] receipt=#{delivery_id} error=#{e.class}")
    end
  end
end
