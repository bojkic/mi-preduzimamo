# frozen_string_literal: true

module DecidimApp
  module Admin
    class CityServiceEventsController < Decidim::Bih::Admin::ApplicationController
      helper_method :workflow_entry, :workflow_label, :workflow_reason, :state_label, :severity_label, :review_exceptions, :source_status_label, :city_alert_area_label,
                    :city_alert_time_window, :city_alert_source_label, :city_alert_reference_label

      WORKFLOW_TABS = %w(review automatic done settings).freeze
      LEGACY_TABS = { "reviewed" => "review", "viber" => "done", "all" => "review", "readiness" => "settings", "published" => "done", "history" => "done" }.freeze
      DEFAULT_WORKFLOW_TAB = "review"
      # Where an operator lands after acting on one item. Following the item to
      # the tab it moved to emptied the queue out from under them: publish one
      # alert and you were on "Objavljeno", with the remaining work a click
      # away and no sign of it.
      QUEUE_TAB = "review"
      REVIEW_EXCEPTIONS = %w(unknown_area invalid_time changed_source unavailable_source cancelled).freeze

      before_action -> { require_bih_permission!(:city_alerts_manage) }

      def index
        @active_city_alert_tab = active_workflow_tab
        @filters = filter_params
        @workflow = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: current_organization)
        @state_options = DecidimApp::Bijeljina::CityServiceWorkflow::STATUSES
        @source_options = DecidimApp::Bijeljina::CityServiceEvent
                          .for_organization(current_organization)
                          .distinct
                          .order(:source_key)
                          .pluck(:source_key)
        matching_entries = @workflow.current_entries.select { |entry| @filters[:source_key].blank? || entry.event.source_key == @filters[:source_key] }
        @state_counts = matching_entries.reject { |entry| entry.tab == "automatic" }.map(&:status).tally
        @lane_counts = matching_entries.map(&:tab).tally
        @review_total = @workflow.ids(tab: "review").size
        load_source_health
        @events = filtered_events
                  .order(Arel.sql("CASE WHEN severity IN ('emergency', 'safety') THEN 0 ELSE 1 END, starts_at ASC NULLS LAST, id DESC"))
                  .page(params[:page]).per(80)
        @previous_versions = DecidimApp::Bijeljina::CityServiceEvent.for_organization(current_organization)
                                                                    .where(superseded_by_id: @events.map(&:id)).order(id: :desc).group_by(&:superseded_by_id)
        @review_areas = Decidim::Bih::LocalArea.where(decidim_organization_id: current_organization.id).order(:kind, :slug)
        @area_by_slug = @review_areas.index_by(&:slug)
        @document_history = @events.index_with(&:review_document_history)
        @previews = @events.index_with do |event|
          DecidimApp::Bijeljina::CityServiceEventPreview.new(event).call
        end
        load_viber_readiness
      end

      def check_automatic_publication
        result = DecidimApp::Bijeljina::CityServiceAutomaticPublicationCheck.new(event:, actor: current_user)
                                                                     .mark_ok!(expected_revision: params[:publication_revision], expected_digest: params[:evidence_digest])
        kind = result == :checked || result == :already_checked ? :notice : :alert
        redirect_to city_alerts_path(tab: event_tab, anchor: "city-service-event-#{event.id}"),
                    kind => t("decidim_app.admin.city_service_events.auto_check.results.#{result}")
      end

      def bulk_check_automatic
        selections = params.permit(auto_checks: [:selected, :publication_revision, :evidence_digest]).fetch(:auto_checks, {}).to_h
        selected = selections.select { |_id, receipt| receipt["selected"] == "1" }.first(80)
        results = selected.map do |id, receipt|
          item = DecidimApp::Bijeljina::CityServiceEvent.for_organization(current_organization).find_by(id: id)
          next :stale_review unless item

          DecidimApp::Bijeljina::CityServiceAutomaticPublicationCheck.new(event: item, actor: current_user)
                                                                     .mark_ok!(expected_revision: receipt["publication_revision"], expected_digest: receipt["evidence_digest"])
        end
        checked = results.count { |result| result == :checked }
        failed = results.size - checked - results.count { |result| result == :already_checked }
        redirect_to city_alerts_path(tab: "automatic"),
                    notice: t("decidim_app.admin.city_service_events.auto_check.bulk_result", count: checked, failed: failed)
      end

      def revoke_coverage
        result = DecidimApp::Bijeljina::CityServiceCoverageRegistry.revoke!(event:, actor: current_user)
        redirect_to city_alerts_path(tab: "review"), notice: t("decidim_app.admin.city_service_events.compact.results.#{result}")
      end

      def incident_decision
        result = DecidimApp::Bijeljina::CityServiceIncidentReview.new(event:, actor: current_user).resolve!(
          other_event_id: params[:other_event_id], decision: params[:decision], review_token: params[:review_token], other_review_token: params[:other_review_token]
        )
        redirect_to city_alerts_path(tab: "review", anchor: "city-service-event-#{event.id}"), notice: t("decidim_app.admin.city_service_events.compact.results.#{result}")
      end

      def automation_policy
        result = DecidimApp::Bijeljina::CityServiceAutomationPolicy.new(organization: current_organization).update!(
          source_key: params[:source_key], mode: params[:mode], actor: current_user
        )
        redirect_to city_alerts_path(tab: "settings"), notice: t("decidim_app.admin.city_service_events.compact.results.#{result}")
      end

      def map
        response.headers["Cache-Control"] = "private, no-store"
        render json: DecidimApp::Bijeljina::CityServiceReviewMap.new(event).call
      end

      def update
        unless editable_event?
          redirect_to city_alerts_path(tab: "history"), alert: t(".not_editable", default: "Published city-service events cannot be edited.")
          return
        end

        fallback = params[:viber_fallback] == "1" && params[:review_action] == "publish"
        return if fallback && !fallback_confirmation_ready?

        correction_pending = event.extraction_metadata["publication_correction_pending"] == true
        corrected_revision = Array(event.extraction_metadata["publication_history"]).last&.fetch("revision", nil) if correction_pending
        result = save_review(fallback:)
        if result.respond_to?(:posts_count)
          if result.status == :published && corrected_revision
            DecidimApp::Bijeljina::CityServiceAutomaticPublicationCheck.new(event:, actor: current_user)
                                                                       .mark_resolution!(expected_revision: corrected_revision, result: "corrected")
          end
          redirect_publication(result)
        elsif result == :updated
          redirect_to city_alerts_path(tab: QUEUE_TAB), notice: t(".updated")
        else
          redirect_to city_alerts_path(tab: event_tab, anchor: "city-service-event-#{event.id}"), alert: t(".#{result}")
        end
      end

      def bulk_review
        receipts = params.permit(selections: [:selected, :content_version, :review_token]).fetch(:selections, {}).to_h
        selected = receipts.select { |_id, receipt| receipt["selected"] == "1" }
        result = DecidimApp::Bijeljina::CityServiceBulkReview.new(
          organization: current_organization, actor: current_user, action: params[:bulk_action], selections: selected, note: params[:review_note]
        ).call
        message = t(".#{result.status}", count: result.affected_count)
        redirect_to city_alerts_path(tab: bulk_result_tab(result)),
                    **{ result.status == :updated ? :notice : :alert => message }
      end

      def approve_answers
        result = event.approve_answers!(actor: current_user, expected_version: params[:content_version], review_token: params[:review_token])
        if result == :approved
          redirect_to city_alerts_path(tab: QUEUE_TAB), notice: t(".approved")
        else
          redirect_to city_alerts_path(tab: "review"), alert: t(".#{result}")
        end
      end

      def revoke_answers
        result = event.revoke_answers!(actor: current_user, expected_version: params[:content_version], review_token: params[:review_token])
        if result == :revoked
          redirect_to city_alerts_path(tab: "review"), notice: t(".revoked")
        else
          redirect_to city_alerts_path(tab: "history"), alert: t(".#{result}")
        end
      end

      def publish_board
        result = publisher.publish_board!
        redirect_publication(result)
      end

      def notification_preview
        response.headers["Cache-Control"] = "private, no-store"
        retry_failed = params[:retry_failed] == "1"
        unless event.board_published? || (retry_failed && event.published?)
          redirect_to city_alerts_path(tab: "review"), alert: t("decidim_app.admin.city_service_events.publish_viber.board_first_required")
          return
        end
        workflow_status = DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: current_organization).entries.fetch(event.id).status
        unless workflow_status == "published" && event.publication_revision.present? && event.publication_blocker.nil?
          redirect_to city_alerts_path(tab: "history"), alert: workflow_message(:not_publishable)
          return
        end

        load_viber_readiness
        unless @viber_send_ready
          redirect_to city_alerts_path(tab: "published"), alert: t("decidim_app.admin.city_service_events.publish_viber.viber_not_ready")
          return
        end
        return unless city_alert_dispatch_allowed?
        return unless phone_audience_allowed?

        @approval_attributes = event.attributes.slice("title", "summary", "viber_text")
        @approval_preview = DecidimApp::Bijeljina::CityServiceApprovalPreview.new(event:, actor: current_user, attributes: {},
                                                                                   retry_failed:).call
        @published_fallback = true
        render :approval_preview
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      # -- a flat, ordered sequence of refusals: board first, provider and
      # governance readiness, the explicit review confirmation, then the
      # shared dispatch guard. The ORDER is the contract; folding it into
      # helpers would hide which refusal an operator meets first.
      def publish_viber
        unless event.board_published? || (params[:retry_failed] == "1" && event.published?)
          redirect_to city_alerts_path(tab: "review"), alert: t(".board_first_required")
          return
        end

        load_viber_readiness
        unless @viber_send_ready
          redirect_to city_alerts_path(tab: "published"), alert: t(".viber_not_ready")
          return
        end

        unless params[:viber_review_confirmed] == "1"
          redirect_to city_alerts_path(tab: event_tab), alert: t(".confirmation_required")
          return
        end

        # The dispatch-time recheck, the same one the broadcast and operator
        # message surfaces run. ADDITIVE: every check above still runs and none
        # of them moved. It covers the retry branch below as well as a fresh
        # publication, and it re-reads the facts rather than trusting the
        # readiness that was loaded a moment ago.
        return unless city_alert_dispatch_allowed?
        return unless phone_audience_allowed?

        return unless published_fallback_confirmation_ready?

        if params[:retry_failed] == "1"
          result = DecidimApp::Bijeljina::CityServiceDeliveryRetry.call(event:, actor: current_user, review_token: params[:review_token])
          message = if [:delivery_retry_queued, :nothing_to_retry].include?(result.status)
                      t("decidim_app.admin.city_service_events.simplified.#{result.status}", count: result.retried_count)
                    else
                      workflow_message(result.status)
                    end
          return redirect_to city_alerts_path(tab: event_tab, anchor: "city-service-event-#{event.id}"),
                             **{ result.retried_count.positive? ? :notice : :alert => message }
        end

        result = publisher.publish_with_viber_review!(channels: @delivery_channels, template: @delivery_template)
        redirect_publication(result, viber: true)
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def withdraw
        correction = params[:withdraw_action] == "correct"
        previous_revision = event.publication_revision
        result = DecidimApp::Bijeljina::CityServicePublicationWithdrawal.call(
          event:, actor: current_user, review_token: params[:review_token], note: params[:review_note], correct: correction
        )
        if result == :withdrawn && !correction
          DecidimApp::Bijeljina::CityServiceAutomaticPublicationCheck.new(event:, actor: current_user)
                                                                     .mark_resolution!(expected_revision: previous_revision, result: "withdrawn") if previous_revision
        end
        tab = event_tab
        redirect_to city_alerts_path(tab:), **{ result == :withdrawn ? :notice : :alert => workflow_message(result) }
      end

      def dismiss
        unless editable_event?
          redirect_to city_alerts_path(tab: "history"), alert: t(".not_dismissible", default: "Published city-service events cannot be dismissed.")
          return
        end

        from_state = event.state
        ActiveRecord::Base.transaction do
          event.update!(
            state: "dismissed",
            dismissed_at: Time.current,
            reviewer: current_user,
            reviewed_at: Time.current,
            review_note: params[:review_note].presence || event.review_note
          )
          audit_event!("city_service_event_dismissed", from_state:, to_state: event.state)
        end
        redirect_to city_alerts_path(tab: QUEUE_TAB), notice: t(".dismissed")
      end

      private

      def published_fallback_confirmation_ready?
        ready = false
        DecidimApp::Bijeljina::CityServiceIncident.synchronize(current_organization) do
          event.with_lock do
            preview = DecidimApp::Bijeljina::CityServiceApprovalPreview.new(event:, actor: current_user, attributes: {},
                                                                             retry_failed: params[:retry_failed] == "1")
            current_preview = preview.valid_result(params[:fallback_token]) if params[:fallback_confirmed] == "1"
            ready = current_preview && current_preview.viber_audience.fetch(:eligible_phone).positive?
            @delivery_channels = current_preview.channels if ready
            @delivery_template = current_preview.template if ready
            unless ready
              @approval_attributes = event.attributes.slice("title", "summary", "viber_text")
              @approval_preview = preview.call
              @published_fallback = true
            end
          end
        end
        unless ready
          flash.delete(:notice)
          render :approval_preview
        end
        ready
      end

      def save_review(fallback:)
        DecidimApp::Bijeljina::CityServiceIncident.synchronize(current_organization) do
          save_review_locked(fallback:)
        end
      end

      def save_review_locked(fallback:)
        event.with_lock do
          if fallback && !DecidimApp::Bijeljina::CityServiceApprovalPreview.new(event:, actor: current_user, attributes: event_params).valid?(params[:fallback_token])
            return :stale_review
          end

          result = DecidimApp::Bijeljina::CityServiceEventReview.new(event:, actor: current_user, attributes: event_params).call
          return result unless result == :updated && params[:review_action] == "publish"

          publisher(review_token: event.answer_review_token).publish_board!(viber_fallback: fallback, channels: @delivery_channels,
                                                                            template: @delivery_template)
        end
      end

      def fallback_confirmation_ready?
        return false unless city_alert_dispatch_allowed?
        return false unless phone_audience_allowed?

        preview = DecidimApp::Bijeljina::CityServiceApprovalPreview.new(event:, actor: current_user, attributes: event_params)
        current_preview = preview.valid_result(params[:fallback_token]) if params[:fallback_confirmed] == "1"
        if current_preview && current_preview.viber_audience.fetch(:eligible_phone).positive?
          @delivery_channels = current_preview.channels
          @delivery_template = current_preview.template
          return true
        end

        @approval_attributes = event_params.to_h
        @approval_preview = preview.call
        if @approval_preview.status == :ready
          render :approval_preview
        else
          redirect_to city_alerts_path(tab: "review"), alert: t(".#{@approval_preview.status}")
        end
        false
      end

      # Provider/governance readiness is checked here. Combined approval also
      # validates the signed edited-facts/audience preview under the incident lock.
      # Per-recipient eligibility is rechecked asynchronously at dispatch.
      def city_alert_dispatch_allowed?
        load_viber_readiness
        result = Decidim::Bih::Messaging::DispatchGuard.evaluate(
          authorized: bih_allowed?(:city_alerts_manage),
          governance_current: @city_alert_channels.any?,
          preview_fresh: true,
          preview_matches: true,
          audience_unchanged: true,
          expired: false,
          channel_ready: @viber_send_ready == true
        )
        return true if result.allowed?

        redirect_to city_alerts_path(tab: "published"),
                    alert: t("decidim.bih.admin.composer.blockers.#{result.blockers.first}")
        false
      end

      def phone_audience_allowed?
        return true unless DecidimApp::Bijeljina::CityServicePhoneDelivery.phone_audience_unverified?(event)

        redirect_to city_alerts_path(tab: event_tab, anchor: "city-service-event-#{event.id}"),
                    alert: t("decidim_app.admin.city_service_events.publish_viber.phone_audience_unverified")
        false
      end

      def load_viber_readiness
        infobip = Decidim::Bih::Config.infobip
        @viber_provider_configured = [:base_url, :api_key, :viber_bm_sender].all? { |key| infobip[key].present? }
        @viber_provider_health = Decidim::Bih::IntegrationHealth.instance.state(provider: "infobip")
        @viber_governance_approval = Decidim::Bih::GovernanceApproval.current_for(current_organization, "viber_launch")
        # Blocked only by EVIDENCE of a failing provider — see
        # IntegrationHealth#send_blocked?. The health state is still read above
        # and shown to the operator, because "we have not heard from the
        # provider recently" is worth knowing; it is just not a reason to hide
        # the control.
        @city_alert_channels = DecidimApp::Bijeljina::CityServicePhoneDelivery.channels(organization: current_organization)
        @viber_send_ready = @city_alert_channels.any?
      rescue StandardError => e
        Rails.logger.warn("[Admin::CityServiceEvents] Viber readiness unavailable: #{e.class}")
        @viber_send_ready = false
        @viber_governance_approval = nil
      end

      def filtered_events
        scope = DecidimApp::Bijeljina::CityServiceEvent.for_organization(current_organization)
        scope = scope_for_active_tab(scope)
        scope = scope.where(id: @filters[:event_id]) if @filters[:event_id].present?
        if @active_city_alert_tab == "done" && @filters[:unchecked] == "1"
          ids = @workflow.current_entries.filter_map { |entry| entry.event.id if entry.reason == "expired" && entry.automatic_unchecked? }
          scope = scope.where(id: ids)
        end

        scope = scope.where(source_key: @filters[:source_key]) if @filters[:source_key].present?
        apply_exception_filter(scope)
      end

      def load_source_health
        data = DecidimApp::Bijeljina
        store = data::CityServiceSourceCheckStore.new
        @source_checks = store.check.index_by(&:source_key)
        @source_snapshots = DecidimApp::CityServiceSourceSnapshot.where(source_key: @source_checks.keys).index_by(&:source_key)
        keys = [data::CityReferenceRefresh::GAZETTE_KEY, data::PublicCallsPreparation.snapshot_key(current_organization)] +
               data::ServiceProcedures.all.map { |card| "reference:procedure:#{card.fetch(:key)}" }
        @prepared_references = keys.map { |key| { key:, snapshot: store.snapshot(source_key: key) } }
      end

      def city_alert_area_label(slug)
        area = @area_by_slug[slug]
        return slug unless area

        name = area.translated_name
        number = slug.delete_prefix("komsiluk-")
        return "MZ · #{name}" if area.kind == "mz"

        "#{t("decidim_app.admin.city_service_events.index.layout.komsiluk_number", number:)} · #{name}"
      end

      def city_alert_time_window(item)
        unless item.starts_at
          if item.ends_at
            return t("decidim_app.admin.city_service_events.ui_review.unknown_start", finish: item.ends_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. %H:%M"))
          end

          return t("decidim_app.admin.city_service_events.index.layout.unknown_time")
        end

        start_at = item.starts_at.in_time_zone("Europe/Sarajevo")
        end_at = item.ends_at&.in_time_zone("Europe/Sarajevo")
        value = start_at.strftime("%d.%m.%Y. · %H:%M")
        return value unless end_at

        "#{value}–#{end_at.strftime(start_at.to_date == end_at.to_date ? "%H:%M" : "%d.%m.%Y. %H:%M")}"
      end

      def city_alert_source_label(key)
        t("decidim_app.admin.city_service_events.ui_review.sources.#{key}",
          default: DecidimApp::Bijeljina::CityServiceSources.find(key)&.fetch(:provider) || key.to_s.humanize)
      end

      def city_alert_reference_label(key)
        family, subject, item = key.to_s.split(":", 3)
        kind = family == "reference" ? subject : family
        kind = "procedure_#{item}" if subject == "procedure"
        t("decidim_app.admin.city_service_events.ui_review.references.#{kind}",
          default: t("decidim_app.admin.city_service_events.ui_review.references.other"))
      end

      def source_status_label(status)
        t("decidim_app.admin.city_service_events.source_health.statuses.#{status}", default: status.to_s)
      end

      def review_exceptions(item)
        exceptions = []
        exceptions << "unknown_area" if item.targeting_level == "unknown"
        exceptions << "invalid_time" if [:missing_time, :invalid_time].include?(item.publication_blocker)
        source_changed = @previous_versions.fetch(item.id, []).any? || item.extraction_metadata["source_document_changed"] == true
        exceptions << "changed_source" if source_changed && !item.current_source_reviewed?
        check = @source_checks[item.source_key]
        exceptions << "unavailable_source" unless check && [:ok, :empty, :unreviewed].include?(check.status)
        exceptions << "cancelled" if %w(cancelled resolved superseded).include?(item.lifecycle)
        exceptions
      end

      def apply_exception_filter(scope)
        case @filters[:exception]
        when "unknown_area" then scope.where(targeting_level: "unknown")
        when "invalid_time" then scope.where("starts_at IS NULL OR ends_at IS NULL OR ends_at <= starts_at")
        when "changed_source"
          previous = DecidimApp::Bijeljina::CityServiceEvent.for_organization(current_organization)
                                                            .where.not(superseded_by_id: nil).select(:superseded_by_id)
          scope.where(id: previous).or(scope.where("extraction_metadata ->> 'source_document_changed' = 'true'"))
               .where("content_version IS NULL OR content_version = '' OR reviewed_at IS NULL OR reviewed_by_id IS NULL OR " \
                      "reviewed_content_version IS DISTINCT FROM content_version")
        when "unavailable_source"
          healthy = @source_checks.values.select { |check| [:ok, :empty, :unreviewed].include?(check.status) }.map(&:source_key)
          scope.where.not(source_key: healthy)
        when "cancelled" then scope.where(lifecycle: %w(cancelled resolved superseded))
        else scope
        end
      end

      def filter_params
        {
          event_id: params[:event_id].to_s.presence&.match?(/\A[1-9]\d*\z/) ? params[:event_id].to_i : nil,
          state: params[:state].to_s.presence_in(DecidimApp::Bijeljina::CityServiceWorkflow::STATUSES),
          source_key: params[:source_key].to_s.presence,
          exception: params[:exception].to_s.presence_in(REVIEW_EXCEPTIONS),
          unchecked: params[:unchecked].to_s.presence_in(["1"])
        }
      end

      def event
        @event ||= DecidimApp::Bijeljina::CityServiceEvent
                   .for_organization(current_organization)
                   .find(params[:id])
      end

      def event_params
        params.fetch(:city_service_event, {}).permit(
          :title,
          :summary,
          :recommended_action,
          :viber_text,
          :review_note, :content_version, :review_token, :facts_reviewed, :event_type, :severity, :lifecycle,
          :targeting_level, :starts_at_local, :ends_at_local, :reuse_coverage, :coverage_valid_until, area_ids: []
        )
      end

      def editable_event?
        DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: current_organization).entries.fetch(event.id).editable?
      end

      def city_alerts_path(**options)
        Rails.application.routes.url_helpers.decidim_app_admin_city_service_events_path(options)
      end

      def active_workflow_tab
        requested = LEGACY_TABS.fetch(params[:tab].to_s, params[:tab].to_s)
        WORKFLOW_TABS.include?(requested) ? requested : DEFAULT_WORKFLOW_TAB
      end

      def scope_for_active_tab(scope)
        scope.where(id: @workflow.ids(tab: @active_city_alert_tab, status: @filters[:state]))
      end

      # A batch, like a single item, ends where the remaining work is.
      def bulk_result_tab(_result)
        QUEUE_TAB
      end

      def event_tab
        DecidimApp::Bijeljina::CityServiceWorkflow.new(organization: current_organization).entries.fetch(event.id).tab
      end

      def workflow_entry(item)
        @workflow.entries.fetch(item.id)
      end

      def workflow_label(status)
        t("decidim_app.admin.city_service_events.simplified.statuses.#{status}")
      end

      def workflow_reason(item)
        entry = workflow_entry(item)
        return unless entry.reason

        label = t("decidim_app.admin.city_service_events.simplified.reasons.#{entry.reason}")
        return label unless %w(expired expired_unpublished).include?(entry.reason)

        "#{label} · #{item.ends_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m. u %H:%M")}"
      end

      def publisher(review_token: params[:review_token])
        DecidimApp::Bijeljina::CityServiceEventPublisher.new(event, actor: current_user, review_token:)
      end

      def workflow_message(key, **values)
        t("decidim_app.admin.city_service_events.workflow_results.#{key}", **values)
      end

      def redirect_publication(result, viber: false)
        return redirect_publication_failure(result) unless result.status == :published
        return redirect_skipped_delivery(result) if viber && result.viber_jobs_count.zero?

        # Back to the queue, where the rest of the work is. The exception is a
        # delivery that was actually queued: its status lives on the published
        # tab and the operator has just asked to watch it.
        redirect_to city_alerts_path(tab: viber ? event_tab : QUEUE_TAB),
                    notice: workflow_message(viber ? :delivery_queued : :board_published, posts: result.posts_count, recipients: result.viber_recipients_count)
      end

      def redirect_publication_failure(result)
        flash.delete(:notice)
        key = result.status == :not_publishable ? result.policy_decision[:reason] : result.status
        redirect_to city_alerts_path(tab: event_tab, anchor: "city-service-event-#{event.id}"), alert: workflow_message(key)
      end

      def redirect_skipped_delivery(result)
        flash.delete(:notice)
        reason = result.policy_decision&.fetch(:reason, nil) || "no_recipients"
        redirect_to city_alerts_path(tab: "published"), alert: workflow_message(:delivery_skipped, reason:)
      end

      def state_label(state)
        t("decidim_app.admin.city_service_events.states.#{state}", default: state)
      end

      def audit_event!(event_type, metadata = {})
        Decidim::Bih::OperatorAuditEvent.record!(
          organization: current_organization,
          actor: current_user,
          event_type:,
          permission: "city_alerts_manage",
          role: current_bih_role_for(:city_alerts_manage),
          resource: event,
          metadata:
        )
      end

      def severity_label(severity)
        t("decidim_app.admin.city_service_events.severities.#{severity}", default: severity)
      end
    end
  end
end
