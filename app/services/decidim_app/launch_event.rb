# frozen_string_literal: true

require "digest"
require "json"
require_relative "launch_event_configuration"

module DecidimApp
  # Explicitly configured community launch, with two manual message triggers.
  # Delivery claims commit before HTTP; uncertain requests are never resent.
  module LaunchEvent
    TIME_ZONE = "Europe/Sarajevo"
    MESSAGES = {
      "map" => { title: "1. Mapa prijava", action: "Otvori mapu prijava", path: "/biceriseno/mapa",
                 text: "Dobrodošli na događaj vaše MI zajednice. Otvorite mapu prijava preko svog ličnog linka:" },
      "poll" => { title: "2. Anketa o komšiluku", action: "Otvori anketu", path: "/lansiranje/anketa",
                  text: "Zdravo, komšinica vas poziva da odgovorite na anketu o svom komšiluku preko ličnog linka:" }
    }.freeze
    QUESTION = "Šta je najveći problem u tvom komšiluku?"
    CHOICES = {
      "lighting" => "Rasvjeta", "roads" => "Put i rupe", "waste" => "Smeće i deponije",
      "water" => "Voda i kanalizacija", "dogs" => "Psi lutalice", "parking" => "Trotoari i parking",
      "greenery" => "Igralište i zelenilo"
    }.freeze

    module_function

    def configuration(organization)
      return unless organization&.respond_to?(:host)

      LaunchEventConfiguration.load(organization_host: organization.host)
    rescue LaunchEventConfiguration::InvalidConfiguration
      nil
    end

    def closes_at(organization = nil) = configuration(organization)&.closes_at
    def opens_at(organization = nil) = configuration(organization)&.opens_at
    def open?(organization = nil, now: Time.current) = configuration(organization)&.open?(now:) == true

    def event_key(organization, configuration: nil)
      config = configuration || self.configuration(organization)
      return unless config.is_a?(LaunchEventConfiguration) && config.enabled? && config.bound_to?(organization&.host)

      # Bind queued work, previews and votes to both operator settings and the
      # exact message/poll policy; a changed template cannot borrow an old claim.
      digest = Digest::SHA256.hexdigest(JSON.generate([config.identity, MESSAGES, QUESTION, CHOICES, TIME_ZONE]))
      "community-launch-v1:#{digest}"
    end

    def current_event?(organization, identity, now: nil)
      return false unless identity.is_a?(String) && identity.present?

      config = configuration(organization)
      return false unless config&.enabled? && event_key(organization, configuration: config) == identity

      now.nil? || config.open?(now:)
    end

    def citizens(organization)
      Decidim::User.where(organization:, deleted_at: nil, blocked: false, managed: false, admin: false)
                   .where("COALESCE(array_length(roles, 1), 0) = 0")
                   .where(id: Decidim::Bih::CitizenPhoneRecord.where(organization:).select(:decidim_user_id))
    end

    def phone_for(user, organization)
      Decidim::Bih::VerifiedPhone.delivery_phone_for(user:, organization:)
    end

    def phone_digest(phone)
      Decidim::Bih::Messaging::SuppressionKey.digest(kind: "phone", value: phone)
    end

    def channels_for(user, organization, test_message: false, configuration: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      config = configuration || self.configuration(organization)
      identity = event_key(organization, configuration: config)
      return [] unless current_event?(organization, identity, now: Time.current) && user&.active_for_authentication? && !user.blocked? && !user.deleted?
      return [] unless Decidim::Bih::Config.infobip[:optional_traffic_enabled]
      return [] unless test_message || Decidim::Bih::TopicPreferences.enabled?(user, topic: :platform_news)

      phone = phone_for(user, organization)
      return [] if phone.blank?

      client = Decidim::Bih::Infobip::Client.new
      return [] unless client.configured?

      channels = []
      channels << "viber" if client.viber_business_configured?
      channels << "sms" if config.sms_fallback? && Decidim::Bih::Config.infobip[:sms_sender].present?
      channels.reject do |channel|
        Decidim::Bih::Messaging::Suppression.blocking_for(
          organization:, provider: "infobip", channel:, destination_digest: phone_digest(phone)
        ).present?
      end
    end

    def authorized_actor?(actor, organization)
      actor && actor.decidim_organization_id == organization.id && !actor.blocked? && !actor.deleted? &&
        Decidim::Bih::OperatorAuthorization.allowed?(actor, :broadcast_send_viber, organization:)
    end

    def deliveries(organization, key, event_identity: event_key(organization))
      LaunchEventDelivery.where(organization:, event_key: event_identity, message_key: key, test_message: false)
    end

    def preview(organization, key, configuration: nil)
      raise ArgumentError, "Unknown launch message" unless MESSAGES.has_key?(key)

      config = configuration || self.configuration(organization)
      identity = event_key(organization, configuration: config)
      unless current_event?(organization, identity)
        return { registered: 0, eligible: 0, excluded: 0, remaining: 0, statuses: {}, event_key: nil }
      end
      all = citizens(organization).to_a
      eligible = all.select { |user| channels_for(user, organization, configuration: config).any? }
      recorded = deliveries(organization, key, event_identity: identity).where(user: eligible).count
      { registered: all.size, eligible: eligible.size, excluded: all.size - eligible.size,
        remaining: eligible.size - recorded, statuses: deliveries(organization, key, event_identity: identity).group(:status).count, event_key: identity }
    end

    def enqueue!(organization:, key:, actor:, expected_event_key:, test_user: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      raise Decidim::ActionForbidden unless authorized_actor?(actor, organization)
      config = configuration(organization)
      identity = event_key(organization, configuration: config)
      raise ArgumentError, "Event is closed" unless current_event?(organization, identity, now: Time.current)
      raise ArgumentError, "Event changed" unless identity == expected_event_key
      raise ArgumentError, "Unknown launch message" unless MESSAGES.has_key?(key)
      raise Decidim::ActionForbidden if test_user && test_user != actor

      users = test_user ? [test_user] : citizens(organization).to_a
      raise ArgumentError, "Recipient ceiling exceeded" if users.size > 500

      queued = 0
      users.each do |user|
        next if channels_for(user, organization, test_message: test_user.present?, configuration: config).empty?

        break unless current_event?(organization, identity, now: Time.current)

        delivery = LaunchEventDelivery.create_or_find_by!(organization:, user:, event_key: identity,
                                                          message_key: key, test_message: test_user.present?) do |record|
          record.actor = actor
          record.expires_at = config.closes_at
        end
        # A repeated trigger can recover a pending enqueue, but never re-send
        # a committed provider claim. Job concurrency is serialized by row lock.
        next unless delivery.status == "pending"

        LaunchEventDeliveryJob.perform_later(delivery.id)
        queued += 1
      end
      Decidim::Bih::OperatorAuditEvent.record!(organization:, actor:, event_type: "launch_event_triggered",
                                               metadata: { event_key: identity, message_key: key, test_message: test_user.present?, queued: })
      queued
    end

    def deliver!(delivery) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      raw = phone = channels = config = nil
      claimed = delivery.user.with_lock do
        delivery.with_lock do
          next false unless delivery.status == "pending"

          unless current_event?(delivery.organization, delivery.event_key, now: Time.current)
            delivery.update!(status: "skipped", reason: "event_configuration_changed")
            next false
          end
          config = configuration(delivery.organization)
          channels = channels_for(delivery.user, delivery.organization, test_message: delivery.test_message, configuration: config)
          unless authorized_actor?(delivery.actor, delivery.organization) && channels.any? && delivery.expires_at > Time.current &&
                 current_event?(delivery.organization, delivery.event_key, now: Time.current)
            delivery.update!(status: "skipped", reason: "ineligible_or_closed")
            next false
          end
          phone = phone_for(delivery.user, delivery.organization)
          raw = "event-#{SecureRandom.urlsafe_base64(24)}"
          delivery.update!(status: "sending", attempted_at: Time.current,
                           token_digest: Digest::SHA256.hexdigest(raw), phone_digest: phone_digest(phone))
          true
        end
      end
      return unless claimed

      url = "https://#{delivery.organization.host}/v/#{raw}"
      text = "#{MESSAGES.fetch(delivery.message_key).fetch(:text)} #{url}"
      client = Decidim::Bih::Infobip::Client.new
      sms_text = text.tr("čćšžČĆŠŽ’", "ccszCCSZ'").gsub("đ", "dj").gsub("Đ", "Dj")
      # Claims commit before HTTP. Recheck switches, phone and exact event at
      # the provider boundary; ineligibility here is a confirmed unsent skip.
      channels &= channels_for(delivery.user, delivery.organization, test_message: delivery.test_message, configuration: config)
      unless channels.any? && authorized_actor?(delivery.actor, delivery.organization) &&
             phone_for(delivery.user, delivery.organization) == phone && delivery.expires_at > Time.current &&
             current_event?(delivery.organization, delivery.event_key, now: Time.current)
        delivery.update!(status: "skipped", reason: "ineligible_or_event_changed")
        return
      end
      result = client.send_phone_message(to: phone, text: sms_text, viber_text: text, channels:,
                                         final_sms: channels.include?("sms"), expires_at: delivery.expires_at,
                                         channel_validity_seconds: 60)
      ids = Array(result["messages"]).filter_map { |message| message["messageId"].presence }
      groups = Array(result["messages"]).map { |message| message.dig("status", "groupName") }
      state = if groups.any? { |group| %w(REJECTED UNDELIVERABLE EXPIRED).include?(group) }
                "rejected"
              elsif groups.include?("DELIVERED")
                "delivered"
              else
                ids.any? ? "accepted" : "unknown"
              end
      delivery.update!(status: state, provider_message_ids: ids, reason: ids.any? ? nil : "missing_provider_id")
      LaunchEventReceiptJob.set(wait: 20.seconds).perform_later(delivery.id) if state == "accepted"
    rescue StandardError => e
      # Do not log request/response bodies or the personal URL. No automatic
      # retries after a provider request: its acceptance may be unknown.
      delivery.update!(status: "unknown", reason: e.class.name) if delivery.persisted? && delivery.reload.status == "sending"
      Rails.logger.warn("[launch_event] delivery=#{delivery.id} error=#{e.class}")
    end

    def reconcile!(delivery) # rubocop:disable Metrics/CyclomaticComplexity
      return unless %w(accepted unknown rejected).include?(delivery.status) && delivery.provider_message_ids.any?

      client = Decidim::Bih::Infobip::Client.new
      delivery.provider_message_ids.each do |message_id|
        response = client.message_delivery_reports(message_id:)
        Array(response["results"]).each do |report|
          next unless report["messageId"].to_s == message_id.to_s

          group = report.dig("status", "groupName")
          state = case group
                  when "DELIVERED" then "delivered"
                  when "REJECTED", "UNDELIVERABLE", "EXPIRED" then "rejected"
                  end
          next unless state

          delivery.with_lock do
            delivery.update!(status: state, reason: report.dig("status", "name")) unless delivery.status == "delivered"
          end
        end
      end
    end

    def valid_link_recipient?(delivery)
      user = delivery.user
      return false unless current_event?(delivery.organization, delivery.event_key, now: Time.current)
      return false unless user.active_for_authentication? && !user.blocked? && !user.deleted?

      phone = phone_for(user, delivery.organization)
      phone.present? && phone_digest(phone) == delivery.phone_digest
    end

    def results(organization)
      identity = event_key(organization)
      counts = identity ? LaunchEventVote.where(organization:, event_key: identity).group(:choice).count : {}
      total = counts.values.sum
      { total:, event_key: identity, available: identity.present?, choices: CHOICES.map do |key, label|
        count = counts.fetch(key, 0)
        { key:, label:, count:, percent: total.zero? ? 0 : (100.0 * count / total).round(1) }
      end }
    end
  end
end
