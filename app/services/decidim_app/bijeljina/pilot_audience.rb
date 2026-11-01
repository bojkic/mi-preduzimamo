# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Aggregate-only audience estimate. Canonical topic defaults and explicit
    # choices are shared by both modes. Reachability is evaluated separately.
    # No destination digests are supplied, so deliverable counts are upper
    # bounds before transport suppressions and per-event provider readiness.
    module PilotAudience
      MODES = [:compatibility, :target].freeze

      # Phase 1 REGISTRY keys, not topic names. `report_updates` is a preference
      # adapter/topic; the message classes are these.
      CITY_ALERT_CLASS = "city.service_alert_viber"
      REPORT_EXTERNAL_COPY_CLASS = "report.author_external_copy"

      # `producer_gate` records what the CALLER filters on before it enqueues,
      # which is not the same reader the ledger delivers on:
      #   default_allowed_reader — canonical topic permission
      #   none                   — the producer applies no preference filter
      CANDIDATES = {
        CITY_ALERT_CLASS => {
          topic: :city_service_alerts,
          channel: :viber,
          producer_gate: :default_allowed_reader,
          fallback_key: Decidim::Bih::NotificationPreferences::LEGACY_LOCAL_ALERTS_KEY,
          per_event_scope: :area_membership
        },
        REPORT_EXTERNAL_COPY_CLASS => {
          topic: :report_updates,
          channel: :viber,
          producer_gate: :none,
          fallback_key: nil,
          per_event_scope: :single_author
        }
      }.freeze

      class << self
        def city_service_alert(organization:, area_ids:, modes: MODES)
          audience(message_class: CITY_ALERT_CLASS, organization:, modes:,
                   user_ids: area_member_ids(organization:, area_ids:))
        end

        def report_author_external_copy(organization:, modes: MODES)
          audience(message_class: REPORT_EXTERNAL_COPY_CLASS, organization:, modes:,
                   user_ids: report_author_ids(organization:))
        end

        def audience(message_class:, organization:, user_ids:, modes: MODES)
          candidate = CANDIDATES.fetch(message_class)
          counts = {
            message_class:,
            per_event_scope: candidate.fetch(:per_event_scope),
            producer_gate: candidate.fetch(:producer_gate),
            population: user_ids.size,
            enqueue_candidates: 0,
            permitted: 0,
            missing_key: 0,
            explicit_false: 0,
            deliverable: modes.index_with { 0 },
            reason_codes: modes.index_with { Hash.new(0) }
          }

          Decidim::User.where(id: user_ids).find_each do |user|
            tally_preference_readers(counts, candidate, user)
            tally_routing(counts, message_class, user, organization:, modes:)
          end

          counts[:reason_codes] = counts[:reason_codes].transform_values { |tally| tally.sort.to_h }
          counts
        end

        private

        # The geographic gate is NOT re-evaluated here. `MembershipResolver`
        # resolved it at alert-creation time, before any user id reached the
        # job; this reads the SAME membership. `honor_opt_out: false` is
        # deliberate — the preference classification happens once, below,
        # instead of twice under two different readers.
        def area_member_ids(organization:, area_ids:)
          Decidim::Bih::LocalArea.where(id: area_ids, decidim_organization_id: organization.id).flat_map do |area|
            resolver = if area.kind == "mz"
                         Decidim::Bih::Komsiluk::MembershipResolver.for_mz(organization:, mz_area: area)
                       else
                         Decidim::Bih::Komsiluk::MembershipResolver.for_komsiluk(organization:, komsiluk_id: area.id)
                       end
            resolver.recipient_ids(honor_opt_out: false)
          end.uniq
        end

        # Only a report's own authenticated author owns this private update. An
        # anonymous contact address never selects somebody's account, so an
        # anonymous report contributes no recipient at all.
        def report_author_ids(organization:)
          # One row per AUTHOR, not per report: the uniqueness comes from this
          # id lookup, so `.distinct` on the report scope would be decorative.
          author_ids = Decidim::Bih::Report.where(organization:).where.not(decidim_user_id: nil).pluck(:decidim_user_id)
          Decidim::User.where(organization:, id: author_ids, blocked: false, deleted_at: nil)
                       .where.not(confirmed_at: nil).pluck(:id)
        end

        # Keep historical artifact keys while both readers share canonical permission.
        def tally_preference_readers(counts, candidate, user)
          preferences = Decidim::Bih::NotificationPreferences
          topic = candidate.fetch(:topic)
          channel = candidate.fetch(:channel)
          explicit = preferences.explicit?(user, topic:, channel:)

          counts[:enqueue_candidates] += 1 if producer_admits?(candidate, user)
          counts[:permitted] += 1 if preferences.permitted?(user, topic:, channel:)
          counts[:missing_key] += 1 unless explicit
          counts[:explicit_false] += 1 if explicit && !preferences.permitted?(user, topic:, channel:)
        end

        def producer_admits?(candidate, user)
          return true if candidate.fetch(:producer_gate) == :none

          Decidim::Bih::NotificationPreferences.enabled?(
            user, topic: candidate.fetch(:topic), channel: candidate.fetch(:channel),
                  fallback_key: candidate.fetch(:fallback_key)
          )
        end

        # WhatsApp's approved-template requirement is deliberately NOT modelled:
        # `Policy` carries template validity as one per-recipient gate, so
        # asserting it would refuse Viber too. Every group here is `single` and
        # Viber leads it, so the count is the Viber-led chain either way —
        # which is what the legacy selection picks first as well.
        def tally_routing(counts, message_class, user, organization:, modes:)
          # A proven phone is a fact about reachability, not a preference, and
          # the number itself never leaves this frame.
          reachable = Decidim::Bih::VerifiedPhone.delivery_phone_for(user:, organization:).present?
          recipient = Decidim::Bih::Messaging::RecipientContext.account(
            organization_id: organization.id, account_id: user.id, locale: user.locale
          )

          modes.each do |mode|
            plan = Decidim::Bih::Messaging::Router.plan(
              message_class:, recipient:, organization:, mode:,
              context: { destination_present: reachable }
            )
            if plan.deliverable?
              counts[:deliverable][mode] += 1
            else
              plan.suppressed.each { |entry| Array(entry[:reason_codes]).each { |code| counts[:reason_codes][mode][code] += 1 } }
            end
          end
        end
      end
    end
  end
end
