# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # Rings the admins' bell when a scrape leaves an alert in the review queue
    # that starts within a day. The queue count on the dashboard was the only
    # signal before, and ten alerts ran out there unseen (23.09.2026) — water
    # notices arrive about 08:15 for a cut that is already running.
    #
    # "Waiting" is CityServiceWorkflow's review tab, the one definition of the
    # queue. One bell per admin per scrape, however many alerts it found; each
    # alert version rings once, recorded as an OperatorAuditEvent.
    class CityServiceReviewNudge
      HORIZON = 24.hours
      AUDIT_EVENT = "city_service_review_nudge_sent"

      def initialize(organization:, now: Time.current)
        @organization = organization
        @now = now
      end

      # Returns the number of alerts the bell announced; 0 when it could not ring.
      def call(events:)
        due = due_events(Array(events))
        return 0 if due.empty?

        recipients = admins
        return 0 if recipients.empty?

        recipients.each do |admin|
          publish(admin, due)
          alert_phone(admin, due)
        end
        due.each { |event| record(event) }
        due.size
      rescue StandardError => e
        Rails.logger.warn("[CityServiceReviewNudge] bell not sent: #{e.class}: #{e.message}")
        0
      end

      private

      attr_reader :organization, :now

      def due_events(events)
        ids = events.filter_map { |event| event.try(:id) }
        return [] if ids.empty?

        waiting = CityServiceWorkflow.new(organization:, at: now).ids(tab: "review").to_set
        CityServiceEvent.for_organization(organization).where(id: ids.select { |id| waiting.include?(id) })
                        .where("starts_at IS NULL OR starts_at <= ?", now + HORIZON)
                        .order(:starts_at, :id).reject { |event| rung?(event) }
      end

      def rung?(event)
        Decidim::Bih::OperatorAuditEvent.where(organization:, event_type: AUDIT_EVENT, resource_type: event.class.base_class.name, resource_id: event.id)
                                        .exists?(["metadata ->> 'content_version' = ?", event.content_version.to_s])
      end

      def admins
        Decidim::User.where(organization:, admin: true, deleted_at: nil, blocked: false).to_a
      end

      def publish(admin, due)
        Decidim::EventsManager.publish(
          event: "decidim_app.city_service_review_nudge",
          event_class: CityServiceReviewNudgeEvent,
          resource: admin,
          affected_users: [admin],
          force_send: true,
          extra: { count: due.size, title: due.first.title.to_s.truncate(120) }
        )
      end

      # Owner decision 2026-10-06: the bell alone was missed. Also send the
      # admin's phone a Viber message (verified phone) and a device push where
      # one is subscribed. Each alert version is sent once per admin.
      def alert_phone(admin, due)
        key = "city-review-nudge:#{admin.id}:#{Digest::SHA256.hexdigest(due.map { |event| [event.id, event.content_version.to_s] }.to_json)}"
        Decidim::Bih::WebPush.enqueue(admin, topic: "report_updates", deduplication_key: key)
        Decidim::Bih::AccountNotifications.enqueue!(user: admin, organization:, topic: "report_updates", text: phone_text(due),
                                                    channels: %w(viber), expires_at: 3.hours.from_now, deduplication_key: key)
      rescue StandardError => e
        Rails.logger.warn("[CityServiceReviewNudge] phone alert not sent admin=#{admin.id}: #{e.class}")
      end

      def phone_text(due)
        first = due.first
        ends = first.ends_at ? " (traje do #{first.ends_at.in_time_zone("Europe/Sarajevo").strftime("%H:%M")})" : ""
        more = due.size > 1 ? " i još #{due.size - 1}" : ""
        url = Rails.application.routes.url_helpers.decidim_app_admin_city_service_events_url(tab: "review", host: organization.host)
        "MI platforma: gradsko obavještenje čeka provjeru — #{first.title.to_s.truncate(90)}#{ends}#{more}. " \
          "Ako niko ne reaguje u roku od sat vremena, objaviće se automatski u komšilucima koje smo prepoznali; " \
          "obavještenja bez prepoznatog komšiluka ostaju na Vama. Provjera: #{url}"
      end

      def record(event)
        Decidim::Bih::OperatorAuditEvent.record!(
          organization:, actor: nil, event_type: AUDIT_EVENT, permission: "city_alerts_manage", resource: event,
          metadata: { content_version: event.content_version.to_s, source_key: event.source_key }
        )
      end
    end
  end
end
