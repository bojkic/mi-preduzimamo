# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceAutomationPolicy
      VERSION = "city-boards-20260925-v3"
      MODES = %w(off shadow automatic).freeze
      AUTOMATIC_SOURCES = %w(electricity_outages water_service road_conditions heating_service city_official_notices).freeze
      NAMESPACE = "city_notice_automation"

      def initialize(organization:)
        @organization = organization
      end

      def rows
        CityServiceSources.all.map do |source|
          { source_key: source.fetch(:key), mode: mode(source.fetch(:key)), version: VERSION,
            automatic_allowed: source.fetch(:enabled, true) && AUTOMATIC_SOURCES.include?(source.fetch(:key)) }
        end
      end

      def mode(source_key)
        return "off" unless CityServiceSources.enabled?(source_key)

        value = Decidim::Bih::Setting.namespace_for(@organization, NAMESPACE).dig(source_key.to_s, "mode")
        MODES.include?(value) ? value : "off"
      end

      def update!(source_key:, mode:, actor:)
        return :not_authorized unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :city_alerts_manage, organization: @organization)
        return :invalid_selection unless CityServiceSources.find(source_key) && MODES.include?(mode)
        return :invalid_selection if mode != "off" && !CityServiceSources.enabled?(source_key)
        return :invalid_selection if mode == "automatic" && AUTOMATIC_SOURCES.exclude?(source_key)

        CityServiceIncident.synchronize(@organization) do
          previous = self.mode(source_key)
          Decidim::Bih::Setting.put(@organization, NAMESPACE, source_key, { "mode" => mode, "version" => VERSION })
          Decidim::Bih::OperatorAuditEvent.record!(organization: @organization, actor:, event_type: "city_notice_automation_policy",
                                                   permission: "city_alerts_manage", metadata: { source_key:, from_mode: previous, to_mode: mode, policy_version: VERSION })
        end
        :updated
      end
    end
  end
end
