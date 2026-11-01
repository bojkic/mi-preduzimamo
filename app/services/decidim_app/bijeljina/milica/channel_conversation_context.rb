# frozen_string_literal: true

require "openssl"

module DecidimApp
  module Bijeljina
    module Milica
      # Adapters call this after provider/channel validation and resolve identity
      # themselves. Enabling conversation context never enables report execution.
      module ChannelConversationContext
        CHANNELS = %w(viber viber_bm whatsapp messenger instagram).freeze

        module_function

        def valid_channel?(organization, channel, sender)
          organization.id.is_a?(Integer) && CHANNELS.include?(channel.to_s) && sender.to_s.strip.present?
        end

        def valid_actor?(organization, user)
          user.decidim_organization_id == organization.id && user.id.is_a?(Integer) && !user.deleted? && !user.blocked?
        end

        # Keep actor scope and private-read authority explicit at the adapter boundary.
        def call(organization:, channel:, sender:, user: nil, private_reads: true, now: Time.current) # rubocop:disable Metrics/ParameterLists
          contracts = Decidim::Bih::Concierge::Dialogue::Contracts
          raise contracts::Invalid, "Invalid channel scope" unless valid_channel?(organization, channel, sender)
          raise contracts::Invalid, "Invalid channel actor" if user && !valid_actor?(organization, user)

          # Preserve anonymous report scopes already in use. Actor transitions
          # get a new scope and cannot inherit the preceding person's frame.
          key = ChatReportIntake.conversation_key(organization:, channel:, sender:)
          key = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base.to_s, [key, "actor", user.id].join("\0")) if user
          capabilities = %w(public_reads report_guidance)
          capabilities += %w(neighborhood_reads own_report_reads registration_handoff) if user && private_reads
          contracts::TrustedContext.new(organization_id: organization.id, conversation_key: key,
                                        actor_id: user&.id, account_state: user ? "registered" : "anonymous",
                                        capabilities:, now:)
        end
      end
    end
  end
end
