# frozen_string_literal: true

require "yaml"

module DecidimApp
  module Admin
    # The foundation's own open/closed call status and review window, edited
    # as a draft and approved before Milica::FoundationRead uses it instead of
    # config/milica/foundation_sources.yml. Same permission as city alerts.
    class FoundationStatusController < Decidim::Bih::Admin::ApplicationController
      PERMISSION = DecidimApp::Bijeljina::FoundationStatusOverride::PERMISSION

      helper_method :status_label

      before_action -> { require_bih_permission!(PERMISSION) }
      before_action :load_override

      def show
        @effective = effective_status
      end

      def update
        @override.stage(override_params)
        if @override.save
          audit_operator_action!("foundation_status_drafted", permission: PERMISSION.to_s, resource: @override,
                                                              metadata: { state: @override.state, current_open_status: @override.current_open_status })
          redirect_to status_path, notice: t(".saved")
        else
          @effective = effective_status
          render :show, status: :unprocessable_entity
        end
      end

      def approve
        result = @override.new_record? ? :invalid : @override.approve!(actor: current_user)
        redirect_to status_path, **(result == :approved ? { notice: t(".approved") } : { alert: t(".#{result}", default: t(".invalid")) })
      end

      def rollback
        result = @override.new_record? ? :not_approved : @override.rollback!(actor: current_user)
        redirect_to status_path, **(result == :rolled_back ? { notice: t(".rolled_back") } : { alert: t(".#{result}", default: t(".not_approved")) })
      end

      private

      def load_override
        @override = DecidimApp::Bijeljina::FoundationStatusOverride.for_organization(current_organization)
      end

      def override_params
        params.fetch(:foundation_status_override, {}).permit(:current_open_status, :reviewed_on, :review_expires_on)
      end

      # What Milica currently answers from: the approved override, else the
      # shipped YAML — the same rule FoundationRead applies.
      def effective_status
        if DecidimApp::Bijeljina::Milica::FoundationRead::METADATA_PATH.empty?
          return { source: :unconfigured, status: "unverified", reviewed_on: nil, expires_on: nil }
        end

        approved = DecidimApp::Bijeljina::FoundationStatusOverride.approved_for(current_organization)
        if approved
          { source: :override, status: approved.current_open_status, reviewed_on: approved.reviewed_on,
            expires_on: approved.review_expires_on }
        else
          shipped = YAML.safe_load_file(DecidimApp::Bijeljina::Milica::FoundationRead::METADATA_PATH, aliases: false)
          { source: :yaml, status: shipped.dig("sources", "idea_call", "current_open_status") || "unverified",
            reviewed_on: Date.iso8601(shipped.fetch("reviewed_on")), expires_on: Date.iso8601(shipped.fetch("review_expires_on")) }
        end
      end

      def status_label(status)
        t("decidim_app.admin.foundation_status.show.statuses.#{status}", default: status.to_s)
      end

      def status_path
        decidim_app_admin_foundation_status_path
      end
    end
  end
end
