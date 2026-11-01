# frozen_string_literal: true

require "uri"

module DecidimApp
  module Admin
    # Admin content editor pilot: operator overrides of the shipped city-service
    # FAQ answers (CityServicesData::ENTRIES). Same permission as city alerts.
    # Draft -> preview (through the real chat renderer) -> approve -> rollback.
    class CityServiceEntriesController < Decidim::Bih::Admin::ApplicationController
      PERMISSION = DecidimApp::Bijeljina::CityServiceEntry::PERMISSION
      PREVIEW_LOCALES = Decidim::Bih::Concierge::Dialogue::Contracts::LOCALES

      helper_method :entry_state_key, :entry_state_label, :source_host_reviewed?, :preview_locales

      before_action -> { require_bih_permission!(PERMISSION) }
      before_action :load_entry, except: :index

      def index
        records = DecidimApp::Bijeljina::CityServiceEntry.for_organization(current_organization).index_by(&:key)
        @rows = DecidimApp::Bijeljina::CityServicesData::ENTRIES.map do |shipped|
          { shipped:, record: records[shipped.fetch(:key).to_s] }
        end
        @foundation_status = DecidimApp::Bijeljina::FoundationStatusOverride.approved_for(current_organization)
      end

      def edit; end

      def update
        @entry.stage(entry_params)
        if @entry.save
          audit_operator_action!("city_service_entry_drafted", permission: PERMISSION.to_s, resource: @entry,
                                                               metadata: { key: @entry.key, state: @entry.state })
          redirect_to edit_entry_path, notice: t(".saved")
        else
          render :edit, status: :unprocessable_entity
        end
      end

      def preview
        @query = params[:query].to_s.strip.first(300).presence || @shipped.fetch(:title)
        # Not `params[:locale]`: that is Decidim's UI-locale switch for the whole admin page.
        @locale = params[:answer_locale].to_s.presence_in(PREVIEW_LOCALES) || "sr"
        @draft_answer = render_answer(@entry.new_record? ? nil : @entry)
        @shipped_answer = render_answer(nil)
      end

      def approve
        result = @entry.new_record? ? :not_found : @entry.approve!(actor: current_user)
        if result == :approved
          redirect_to entries_path, notice: t(".approved")
        else
          redirect_to edit_entry_path, alert: t(".#{result}", default: t(".invalid"))
        end
      end

      def rollback
        result = @entry.new_record? ? :not_approved : @entry.rollback!(actor: current_user)
        if result == :rolled_back
          redirect_to entries_path, notice: t(".rolled_back")
        else
          redirect_to entries_path, alert: t(".#{result}", default: t(".not_approved"))
        end
      end

      private

      def load_entry
        @shipped = DecidimApp::Bijeljina::CityServiceEntry.shipped_entry(params[:key])
        raise ActionController::RoutingError, "Unknown FAQ key" unless @shipped

        @entry = DecidimApp::Bijeljina::CityServiceEntry.for_organization_and_key(current_organization, params[:key])
      end

      def entry_params
        params.fetch(:city_service_entry, {}).permit(:title, :body, :source_url, :source_checked_on)
      end

      # The exact chat rendering: the same merge the approved override uses,
      # then DirectoryAnswer and the script localisation ReadPort applies.
      def render_answer(record)
        base = DecidimApp::Bijeljina::CityDirectory.directory.find(@shipped.fetch(:key))
        entry = record ? DecidimApp::Bijeljina::CityDirectory.override_entry(base, **record.override_attributes) : base
        text = DecidimApp::Bijeljina::Milica::DirectoryAnswer.call(entry:, query: @query, locale: @locale)
        Decidim::Bih::Transliterator.localize(text.to_s, locale: @locale)
      end

      def entry_state_key(record)
        return "shipped" if record.nil? || record.new_record?
        return "approval_stale" if record.approval_stale?

        record.state
      end

      def entry_state_label(record)
        t("decidim_app.admin.city_service_entries.states.#{entry_state_key(record)}")
      end

      # Mirrors ReadPort#generic_source_host?: a link on a host outside the
      # reviewed source registry is still shown in the answer text, but the
      # chat fact carries no separate source link. Warn, never block.
      def source_host_reviewed?(url)
        candidate = URI.parse(url.to_s)
        return false unless %w(http https).include?(candidate.scheme) && candidate.host.present?

        DecidimApp::Bijeljina::CityServiceSources.all.any? do |source|
          configured = URI.parse(source.fetch(:source_url).to_s)
          candidate.scheme == configured.scheme && candidate.port == configured.port &&
            candidate.host.to_s.downcase.sub(/\Awww\./, "") == configured.host.to_s.downcase.sub(/\Awww\./, "")
        end
      rescue URI::InvalidURIError
        false
      end

      def preview_locales
        PREVIEW_LOCALES
      end

      def entries_path
        decidim_app_admin_city_service_entries_path
      end

      def edit_entry_path
        decidim_app_admin_city_service_entry_edit_path(@entry.key)
      end
    end
  end
end
