# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Operator-safe preview for a reviewed city-service event. It resolves only
    # aggregate target/recipient counts and policy labels; it never exposes
    # recipient identities.
    class CityServiceEventPreview
      Preview = Struct.new(
        :target_area_slugs,
        :target_komsiluk_slugs,
        :recipient_count,
        :policy_decision,
        keyword_init: true
      )

      Target = Struct.new(:komsiluci, :recipient_areas, keyword_init: true) do
        def area_slugs
          recipient_areas.map(&:slug).uniq.sort
        end

        def komsiluk_slugs
          komsiluci.map(&:slug).uniq.sort
        end
      end

      def initialize(event)
        @event = event
        @organization = event.organization
      end

      def call
        target = resolve_target
        policy = CityServiceAlertPolicy.evaluate(
          source_key: event.source_key,
          event_type: event.event_type,
          severity: event.severity,
          target_area_slugs: target.area_slugs.presence || target.komsiluk_slugs,
          fingerprint: event.source_fingerprint,
          starts_at: event.starts_at,
          operator_approved: true
        )

        Preview.new(
          target_area_slugs: target.area_slugs,
          target_komsiluk_slugs: target.komsiluk_slugs,
          recipient_count: recipient_count(target.recipient_areas),
          policy_decision: policy
        )
      rescue StandardError => e
        Rails.logger.warn("[CityServiceEventPreview] preview failed for event #{event.id}: #{e.class}: #{e.message}")
        Preview.new(target_area_slugs: [], target_komsiluk_slugs: [], recipient_count: 0,
                    policy_decision: { delivery: "preview_error", reason: "preview_error" })
      end

      def board_target_slugs
        resolve_target.komsiluk_slugs
      end

      private

      attr_reader :event, :organization

      def resolve_target
        slugs = event.area_slugs
        return Target.new(komsiluci: all_komsiluci, recipient_areas: all_komsiluci) if event.targeting_level == "citywide"

        mzs = areas_by_kind_and_slugs("mz", slugs)
        explicit_komsiluci = areas_by_kind_and_slugs("komsiluk", slugs)
        komsiluci = explicit_komsiluci + komsiluci_for_mz(mzs)
        Target.new(komsiluci: komsiluci.uniq(&:id).sort_by(&:slug), recipient_areas: (mzs + explicit_komsiluci).uniq(&:id))
      end

      def recipient_count(areas)
        areas.flat_map do |area|
          resolver_for(area)&.recipient_ids(
            exclude_user_id: nil,
            honor_opt_out: true,
            notification_topic: CityServiceAlertPolicy::OPT_OUT_TOPIC,
            notification_channel: CityServiceAlertPolicy::OPT_OUT_CHANNEL,
            fallback_key: CityServiceAlertPolicy::LEGACY_OPT_OUT_KEY
          )
        end
             .compact.flatten.uniq.size
      end

      def resolver_for(area)
        case area.kind
        when "komsiluk"
          Decidim::Bih::Komsiluk::MembershipResolver.for_komsiluk(organization:, komsiluk_id: area.id)
        when "mz"
          Decidim::Bih::Komsiluk::MembershipResolver.for_mz(organization:, mz_area: area)
        end
      end

      def all_komsiluci
        @all_komsiluci ||= Decidim::Bih::LocalArea
                           .komsiluci
                           .where(decidim_organization_id: organization.id)
                           .order(:slug)
                           .to_a
      end

      def areas_by_kind_and_slugs(kind, slugs)
        return [] if slugs.empty?

        Decidim::Bih::LocalArea
          .where(decidim_organization_id: organization.id, kind:, slug: slugs)
          .order(:slug)
          .to_a
      end

      def komsiluci_for_mz(mzs)
        return [] if mzs.empty?

        mz_slugs = mzs.map(&:slug)
        all_komsiluci.select do |komsiluk|
          related_mz_slugs = [komsiluk.primary_mz_slug, *Array(komsiluk.overlapping_mz_slugs)].compact
          related_mz_slugs.intersect?(mz_slugs) || mzs.any? { |mz| komsiluk.parent_id == mz.id }
        end
      end
    end
  end
end
