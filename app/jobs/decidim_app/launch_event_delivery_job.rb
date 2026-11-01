# frozen_string_literal: true

module DecidimApp
  class LaunchEventDeliveryJob < ApplicationJob
    queue_as :integrations
    self.log_arguments = false

    def perform(delivery_id)
      delivery = LaunchEventDelivery.find_by(id: delivery_id)
      LaunchEvent.deliver!(delivery) if delivery
    end
  end
end
