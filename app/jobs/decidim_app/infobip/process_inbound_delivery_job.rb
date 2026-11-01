# frozen_string_literal: true

module DecidimApp
  module Infobip
    # Processes one durable Infobip chat receipt. Job arguments contain only
    # the database id.
    #
    # Two concierges, by channel:
    #   viber_bm                      -> the FULL concierge (reports, photos,
    #                                    city data, goodwill). Viber Business
    #                                    Messages is MSISDN-addressed, so the
    #                                    carrier-supplied sender is already a
    #                                    proven phone — no OTP round-trip.
    #   whatsapp/messenger/instagram  -> the guidance-only external-chat
    #                                    concierge, which strips the sender so
    #                                    those channels can never file a report
    #                                    or enter account linking.
    class ProcessInboundDeliveryJob < ApplicationJob
      EarlierSenderReceiptPending = Class.new(StandardError)
      SENDER_ORDER_RETRY_WAIT = 10.seconds
      # Span the receipt model's 15-minute stale-processing recovery window so
      # a later message keeps waiting while an abandoned earlier claim clears.
      SENDER_ORDER_RETRY_ATTEMPTS = 120

      self.log_arguments = false

      queue_as :integrations

      retry_on StandardError, wait: :polynomially_longer, attempts: 5
      retry_on EarlierSenderReceiptPending,
               wait: SENDER_ORDER_RETRY_WAIT,
               attempts: SENDER_ORDER_RETRY_ATTEMPTS do
        Rails.logger.warn("[Infobip inbound processing] sender-order retry exhausted")
      end
      discard_on ActiveJob::DeserializationError

      def perform(delivery_id)
        delivery = Decidim::Bih::Viber::InboundDelivery.find_by(id: delivery_id)
        return unless delivery&.enqueueable?
        return unless Decidim::Bih::Infobip::InboundMessage::CHANNELS.include?(delivery.channel.to_s)
        raise EarlierSenderReceiptPending, "earlier sender receipt is unfinished" if
          delivery.earlier_unfinished_for_sender?
        return delivery.recover_effects! if delivery.phase == "effects"

        delivery.process!(handler: concierge_handler_for(delivery))
      end

      private

      def concierge_handler_for(delivery)
        organization = delivery.organization

        if delivery.channel.to_s == "viber_bm"
          return lambda { |message|
            note_report_reply(organization, message)
            DecidimApp::Bijeljina::Concierge.process_message(message)
          }
        end

        lambda do |message|
          note_report_reply(organization, message)
          DecidimApp::Bijeljina::ExternalChatConcierge.call(organization:, message:)
        end
      end

      # A citizen answering a report reminder in Viber/WhatsApp reaches the chat
      # assistant, not the case; mark their waiting case so it is not auto-closed.
      def note_report_reply(organization, message)
        user = if message.channel.to_s == "viber_bm"
                 Decidim::Bih::Viber::AccountLinking.new(organization:).user_for_phone(message.sender) if message.sender.present?
               else
                 DecidimApp::Bijeljina::ProviderReportIdentity.call(organization:, message:)
               end
        Decidim::Bih::ReportSecondReminders.note_channel_message!(user:, channel: message.channel)
      rescue StandardError => e
        Rails.logger.warn("[Infobip inbound processing] report reply marker skipped error=#{e.class}")
      end
    end
  end
end
