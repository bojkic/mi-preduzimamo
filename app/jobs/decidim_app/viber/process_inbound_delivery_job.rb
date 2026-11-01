# frozen_string_literal: true

module DecidimApp
  module Viber
    class ProcessInboundDeliveryJob < ApplicationJob
      EarlierSenderReceiptPending = Class.new(StandardError)
      SENDER_ORDER_RETRY_WAIT = 10.seconds
      SENDER_ORDER_RETRY_ATTEMPTS = 120

      self.log_arguments = false

      queue_as :integrations

      retry_on StandardError, wait: :polynomially_longer, attempts: 5
      retry_on EarlierSenderReceiptPending,
               wait: SENDER_ORDER_RETRY_WAIT,
               attempts: SENDER_ORDER_RETRY_ATTEMPTS do
        Rails.logger.warn("[Viber inbound processing] sender-order retry exhausted")
      end
      discard_on ActiveJob::DeserializationError

      def perform(delivery_id)
        delivery = Decidim::Bih::Viber::InboundDelivery.find_by(id: delivery_id)
        return unless delivery&.enqueueable?
        return unless delivery.channel.to_s == "viber"
        raise EarlierSenderReceiptPending, "earlier sender receipt is unfinished" if
          delivery.earlier_unfinished_for_sender?
        return delivery.recover_effects! if delivery.phase == "effects"

        delivery.process!(handler: DecidimApp::Bijeljina::Concierge.method(:process_message))
      end
    end
  end
end
