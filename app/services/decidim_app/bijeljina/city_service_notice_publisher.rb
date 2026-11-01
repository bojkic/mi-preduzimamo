# frozen_string_literal: true

require_relative "city_service_alert_policy"
require_relative "city_service_notice_classifier"
require_relative "city_service_sources"

module DecidimApp
  module Bijeljina
    # Publishes classified city-service notices to Komsiluk boards and, for
    # urgent actionable notices, Viber.
    #
    # Recipient lists are resolved only inside this service/job boundary and are
    # never returned to callers. Viber fan-out honours the city-service Viber
    # topic preference through the shared MembershipResolver.
    class CityServiceNoticePublisher
      CHUNK_SIZE = Decidim::Bih::ChunkedBellJob::CHUNK_SIZE

      Result = Struct.new(
        :status,
        :classification,
        :policy_decision,
        :posts_count,
        :post_ids,
        :viber_jobs_count,
        :viber_recipients_count,
        :target_area_slugs,
        :target_komsiluk_slugs,
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

      def initialize(organization:, classifier: CityServiceNoticeClassifier.new, board_url: nil, operator_approved: false,
                     delivery_options: {})
        @organization = organization
        @classifier = classifier
        @board_url = board_url
        @operator_approved = operator_approved
        @publish_board = delivery_options.fetch(:publish_board, true)
        @delivery_options = delivery_options
        @existing_post_ids = Array(delivery_options[:existing_post_ids]).map(&:to_i).select(&:positive?).uniq
      end

      def call(notice:)
        classification = classify_notice(notice)
        return result(:no_publish, classification:) unless publishable?(classification)

        target = resolve_target(classification)
        return result(:no_target, classification:, target:) if target.komsiluci.empty?

        posts = publish_board? ? create_board_posts(classification, notice, target.komsiluci) : []
        policy_decision = viber_policy(classification, notice, target)
        viber_count = enqueue_viber_if_ready(classification, policy_decision, target)
        # A reviewed city delivery owns the proactive nudge. Board jobs still
        # create inbox notifications, but must not independently send a push.
        notify_board_posts(posts, proactive_delivery: true) if publish_board?

        result(
          :published,
          classification:,
          policy_decision:,
          target:,
          counts: {
            posts: publish_board? ? posts.size : existing_post_ids.size,
            post_ids: publish_board? ? posts.map(&:id) : existing_post_ids,
            viber_jobs: viber_count.fetch(:jobs),
            viber_recipients: viber_count.fetch(:recipients)
          }
        )
      end

      private

      attr_reader :organization, :classifier, :existing_post_ids

      def publish_board?
        @publish_board
      end

      def classify_notice(notice)
        classifier.call(
          source_key: notice_value(notice, :source_key),
          title: notice_value(notice, :title),
          body: notice_value(notice, :body),
          url: notice_value(notice, :url),
          known_areas: known_area_rows
        )
      end

      def publishable?(classification)
        classification.publish? &&
          !classification.needs_review &&
          %w(board_only viber_alert).include?(classification.delivery_recommendation)
      end

      def resolve_target(classification)
        slugs = Array(classification.target_area_slugs).map(&:to_s).compact_blank.uniq

        return Target.new(komsiluci: all_komsiluci, recipient_areas: all_komsiluci) if classification.targeting_level == "citywide"

        mzs = areas_by_kind_and_slugs("mz", slugs)
        komsiluci = areas_by_kind_and_slugs("komsiluk", slugs)
        komsiluci += komsiluci_for_mz(mzs)

        recipient_areas = (mzs + areas_by_kind_and_slugs("komsiluk", slugs)).uniq(&:id)
        Target.new(komsiluci: komsiluci.uniq(&:id).sort_by(&:slug), recipient_areas:)
      end

      def create_board_posts(classification, notice, komsiluci)
        Decidim::Bih::KomsilukPost.transaction do
          komsiluci.map do |komsiluk|
            post = if @delivery_options[:incident_id]
                     project_post(classification, notice, komsiluk)
                   else
                     Decidim::Bih::KomsilukPost.create!(board_attributes(classification, notice, komsiluk))
                   end
            capture_publication(post) if CityServiceBoardVisibility.current?(post)
            post
          end
        end
      end

      def board_attributes(classification, notice, komsiluk)
        { organization:, author: nil, komsiluk:, category: classification.board_category,
          title: truncate(classification.title, Decidim::Bih::KomsilukPost::TITLE_MAX), body: board_body(classification, notice),
          expires_at: @delivery_options[:expires_at] || classification.ends_at.presence,
          origin: "city_service", published_at: Time.current, publication_key: publication_identity,
          details: { "source" => source_metadata(classification, notice) } }
      end

      def publication_identity
        @publication_identity ||= @delivery_options[:delivery_identity].presence || "city-notice:#{SecureRandom.uuid}"
      end

      def project_post(classification, notice, komsiluk)
        incident = CityServiceIncident.find_by!(id: @delivery_options.fetch(:incident_id), decidim_organization_id: organization.id)
        projection = incident.projections.find_or_initialize_by(komsiluk:)
        attributes = board_attributes(classification, notice, komsiluk)
        if projection.persisted?
          post = projection.post
          # Preserve the same placement and its moderation decision across all
          # source refreshes, including a correction after source withdrawal.
          attributes[:details] = post.details.merge(attributes[:details])
          attributes[:published_at] = post.published_at || Time.current
          attributes[:status] = "open" unless post.status == "hidden" || post.details.dig("moderation", "source_hold") == true
          post.correct!(by: nil, attributes:, expected_revision: post.content_revision, notify: false)
        else
          projection.post = Decidim::Bih::KomsilukPost.create!(attributes)
        end
        projection.update!(revision: @delivery_options.fetch(:event_revision))
        projection.post
      end

      def capture_publication(post)
        CityServiceBoardPublication.publish!(
          post:, identity: @delivery_options[:delivery_identity], expires_at: @delivery_options[:expires_at],
          context: { event_id: @delivery_options[:event_id], event_revision: @delivery_options[:event_revision] }.compact
        )
      end

      def board_body(classification, _notice)
        truncate(classification.body, Decidim::Bih::KomsilukPost::BODY_MAX)
      end

      def source_metadata(classification, notice)
        event = CityServiceEvent.for_organization(organization).find_by(id: @delivery_options[:event_id]) if @delivery_options[:event_id]
        return CityServiceBoardMetadata.for_event(event) if event

        source = CityServiceSources.find(notice_value(notice, :source_key))
        { "provider" => source&.dig(:provider).presence || source&.dig(:label),
          "urls" => [notice_value(notice, :url), *incident_source_urls].compact_blank.uniq,
          "event_ids" => [], "event_type" => classification.event_type,
          "starts_at" => source_timestamp(classification.starts_at), "ends_at" => source_timestamp(classification.ends_at) }
      end

      def source_timestamp(value)
        return if value.blank?
        return value.iso8601 if value.respond_to?(:iso8601)

        Time.iso8601(value.to_s).iso8601
      rescue ArgumentError
        nil
      end

      def incident_source_urls
        return [] unless @delivery_options[:incident_id]

        CityServiceEvent.for_organization(organization).where(incident_id: @delivery_options[:incident_id])
                        .where.not(state: %w(dismissed superseded)).distinct.pluck(:source_url).compact_blank
      end

      def notify_board_posts(posts, proactive_delivery: true)
        posts.each do |post|
          next unless CityServiceBoardVisibility.current?(post)

          if @delivery_options[:delivery_identity]
            persist_effect("board", "#{@delivery_options[:delivery_identity]}:board:#{post.id}",
                           post_id: post.id, board_url: notice_url(post), event_revision: @delivery_options[:event_revision],
                           delivery_identity: @delivery_options[:delivery_identity])
          else
            Decidim::Bih::KomsilukPostNotificationService.call(post:, board_url:, proactive_delivery:)
          end
        rescue StandardError => e
          Rails.logger.error(
            "[CityServiceNoticePublisher] board notification failed for post #{post.id}: #{safe_error(e)}"
          )
        end
      end

      def notice_url(post)
        Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_url(
          post, host: organization.host, protocol: Rails.application.config.force_ssl ? "https" : "http",
                script_name: Decidim::Bih.normalized_public_mount_path
        )
      end

      def viber_policy(classification, notice, target)
        return nil unless classification.viber_requested?

        CityServiceAlertPolicy.evaluate(
          source_key: classification.source_key,
          event_type: classification.event_type,
          severity: classification.severity,
          target_area_slugs: target.area_slugs.presence || target.komsiluk_slugs,
          fingerprint: [classification.fingerprint.presence || notice_value(notice, :fingerprint), @delivery_options[:event_revision]].compact.join(":"),
          starts_at: classification.starts_at,
          operator_approved: @operator_approved
        )
      end

      def enqueue_viber_if_ready(classification, policy_decision, target)
        return { jobs: 0, recipients: 0 } unless fallback_dispatch_ready?(classification, policy_decision)

        user_ids = recipient_ids(target.recipient_areas)
        message = viber_message(classification)
        if user_ids.empty? || message.blank?
          policy_decision.merge!(send_now: false, delivery: "skipped", reason: "no_recipients")
          return { jobs: 0, recipients: 0 }
        end

        if @delivery_options[:delivery_identity]
          persist_effect("fallback", "#{@delivery_options[:delivery_identity]}:fallback",
                         organization_id: organization.id, event_id: @delivery_options[:event_id], event_revision: @delivery_options[:event_revision],
                         dedupe_key: policy_decision.fetch(:dedupe_key), delivery_identity: @delivery_options[:delivery_identity],
                         channels: @delivery_options[:delivery_channels] || ["viber"], template: @delivery_options[:delivery_template])
          return { jobs: 1, recipients: user_ids.size }
        end

        jobs = 0
        user_ids.each_slice(CHUNK_SIZE) do |chunk|
          CityServiceAlertNotificationJob.perform_later(
            organization_id: organization.id,
            event_id: @delivery_options[:event_id], event_revision: @delivery_options[:event_revision],
            user_ids: chunk,
            text: message,
            dedupe_key: policy_decision.fetch(:dedupe_key), channels: @delivery_options[:delivery_channels] || ["viber"],
            template: @delivery_options[:delivery_template]
          )
          jobs += 1
        end

        { jobs:, recipients: user_ids.size }
      end

      def fallback_dispatch_ready?(classification, policy_decision)
        policy_decision&.fetch(:send_now, false) && viber_delivery_allowed?(classification, policy_decision) &&
          @delivery_options[:event_id] && @delivery_options[:event_revision]
      end

      def persist_effect(kind, identity, payload)
        CityServiceEffect.create_or_find_by!(identity:) do |effect|
          effect.event_id = @delivery_options.fetch(:event_id)
          effect.kind = kind
          effect.payload = payload
        end
      end

      def viber_delivery_allowed?(classification, policy_decision)
        guard = viber_delivery_guard(classification, policy_decision)
        return true if guard.fetch(:allowed)

        policy_decision[:send_now] = false
        policy_decision[:delivery] = guard.fetch(:delivery)
        policy_decision[:reason] = guard.fetch(:reason)
        false
      end

      def viber_delivery_guard(classification, policy_decision)
        dedupe_key = policy_decision.fetch(:dedupe_key).to_s
        return delivery_block("duplicate_suppressed") if dedupe_key.present? &&
                                                         delivered_events.exists?(viber_dedupe_key: dedupe_key)

        cooldown_minutes = policy_decision.fetch(:cooldown_minutes).to_i
        return delivery_block("cooldown_active") if cooldown_minutes.positive? &&
                                                    similar_recent_delivery?(classification, policy_decision,
                                                                             cooldown_minutes)

        max_per_area = policy_decision.fetch(:max_per_area_per_day).to_i
        return delivery_block("daily_area_limit_reached") if max_per_area.positive? &&
                                                             daily_area_limit_reached?(policy_decision, max_per_area)

        { allowed: true }
      end

      def delivery_block(reason)
        { allowed: false, delivery: "suppressed", reason: }
      end

      def delivered_events
        DecidimApp::Bijeljina::CityServiceEvent
          .where(decidim_organization_id: organization.id, viber_delivery: "viber_alert")
      end

      def similar_recent_delivery?(classification, policy_decision, cooldown_minutes)
        cutoff = cooldown_minutes.minutes.ago
        target_slugs = Array(policy_decision.fetch(:target_area_slugs)).map(&:to_s)

        delivered_events
          .where(source_key: classification.source_key, event_type: classification.event_type,
                 severity: classification.severity)
          .where("published_at IS NULL OR published_at >= ?", cutoff)
          .any? { |event| Array(event.affected_area_slugs).map(&:to_s).intersect?(target_slugs) }
      end

      def daily_area_limit_reached?(policy_decision, max_per_area)
        target_slugs = Array(policy_decision.fetch(:target_area_slugs)).map(&:to_s)
        return false if target_slugs.empty?

        today_events = delivered_events.where(published_at: Time.current.all_day).to_a
        target_slugs.any? do |slug|
          today_events.count { |event| Array(event.affected_area_slugs).map(&:to_s).include?(slug) } >= max_per_area
        end
      end

      def recipient_ids(areas)
        areas.flat_map do |area|
          resolver_for(area)&.recipient_ids(
            exclude_user_id: nil,
            honor_opt_out: true,
            notification_topic: CityServiceAlertPolicy::OPT_OUT_TOPIC,
            notification_channel: CityServiceAlertPolicy::OPT_OUT_CHANNEL,
            fallback_key: CityServiceAlertPolicy::LEGACY_OPT_OUT_KEY
          )
        end.compact.flatten.uniq.sort
      end

      def resolver_for(area)
        case area.kind
        when "komsiluk"
          Decidim::Bih::Komsiluk::MembershipResolver.for_komsiluk(organization:, komsiluk_id: area.id)
        when "mz"
          Decidim::Bih::Komsiluk::MembershipResolver.for_mz(organization:, mz_area: area)
        end
      end

      def viber_message(classification)
        text = classification.viber_text.presence || [classification.title, classification.body].compact_blank.join(" - ")
        truncate(text, CityServiceNoticeClassifier::VIBER_LIMIT)
      end

      def board_url
        @board_url ||= Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_url(
          host: organization.host,
          protocol: Rails.application.config.force_ssl ? "https" : "http"
        )
      end

      def known_area_rows
        @known_area_rows ||= Decidim::Bih::LocalArea
                             .where(decidim_organization_id: organization.id)
                             .order(:kind, :slug)
                             .map { |area| { kind: area.kind, slug: area.slug, name: area.translated_name } }
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

      def result(status, classification:, policy_decision: nil, target: nil, counts: {})
        Result.new(
          status:,
          classification:,
          policy_decision:,
          posts_count: counts.fetch(:posts, 0),
          post_ids: counts.fetch(:post_ids, []),
          viber_jobs_count: counts.fetch(:viber_jobs, 0),
          viber_recipients_count: counts.fetch(:viber_recipients, 0),
          target_area_slugs: target&.area_slugs || [],
          target_komsiluk_slugs: target&.komsiluk_slugs || []
        )
      end

      def notice_value(notice, key)
        if notice.respond_to?(key)
          notice.public_send(key)
        elsif notice.respond_to?(:[])
          notice[key] || notice[key.to_s]
        end
      end

      def truncate(value, limit)
        text = ActionController::Base.helpers.strip_tags(value.to_s).gsub(/\s+/, " ").strip
        return text if text.length <= limit

        text[0, limit].rstrip
      end

      def safe_error(error)
        if defined?(Decidim::Bih::LogRedactor)
          "#{error.class}: #{Decidim::Bih::LogRedactor.error_message(error)}"
        else
          "#{error.class}: #{error.message.to_s.split.join(" ")[0, 240]}"
        end
      end
    end
  end
end
