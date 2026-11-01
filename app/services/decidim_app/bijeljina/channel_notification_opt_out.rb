# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Called only from already authenticated webhook processing. A scoped,
    # unresolved opaque identity never becomes a phone or an account match.
    module ChannelNotificationOptOut
      module_function

      def reply(organization:, message:)
        return unless message.text.to_s.strip.match?(/\A(?:ODJAVA|STOP)\z/i)

        channel = message.channel.to_s
        return unless %w(viber_bm whatsapp messenger instagram).include?(channel)

        business_sender = message.respond_to?(:recipient) ? message.recipient : nil
        configured = Decidim::Bih::Infobip::Client.new.chat_channel_configured?(channel)
        changed = configured && Decidim::Bih::NotificationPreferences.opt_out_sender!(
          organization:, channel: channel == "viber_bm" ? "viber" : channel,
          sender: message.sender, business_sender:
        )
        return I18n.t("decidim.bih.channel_connections.opted_out") if changed

        path = "#{Decidim::Bih.public_mount_path}/moj-nalog/poruke"
        I18n.t("decidim.bih.channel_connections.opt_out_unmatched", url: "https://#{organization.host}#{path}")
      end
    end
  end
end
