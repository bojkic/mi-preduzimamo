# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Report attribution only, called after authenticated durable provider receipt
    # processing. Neither a typed contact number nor a model-supplied actor is
    # accepted. This does not create a session, authorization or contact consent.
    class ProviderReportIdentity
      CHANNELS = %w(whatsapp messenger instagram).freeze

      def self.call(organization:, message:)
        new(organization:, message:).call
      end

      def initialize(organization:, message:)
        @organization = organization
        @message = message
      end

      def call
        return unless message.is_a?(Decidim::Bih::Infobip::InboundMessage)
        return unless CHANNELS.include?(message.channel.to_s)

        business_sender = Decidim::Bih::ChannelConnections.configured_sender(message.channel)
        return unless business_sender.present? && message.recipient.to_s == business_sender.to_s && message.sender.present?

        connection = Decidim::Bih::ChannelConnection.active.where.not(verified_at: nil).find_by(
          organization:, channel: message.channel, business_sender: business_sender.to_s,
          recipient_digest: Decidim::Bih::ChannelConnections.digest(message.sender.to_s)
        )
        return eligible(connection.user) if connection

        # WhatsApp can also provide an opaque ID. Never strip text down to its
        # embedded digits, and never interpret another channel's opaque ID as a phone.
        return unless message.channel == "whatsapp" && message.sender.to_s.match?(/\A\+?[0-9]{8,15}\z/)

        Decidim::Bih::Viber::AccountLinking.new(organization:).user_for_phone(message.sender)
      end

      private

      attr_reader :organization, :message

      def eligible(user)
        return unless user && user.decidim_organization_id == organization.id &&
                      user.active_for_authentication? && !user.blocked? && !user.deleted?
        return unless Decidim::Authorization.where(user:, name: "sms").where.not(granted_at: nil).exists?

        user
      end
    end
  end
end
