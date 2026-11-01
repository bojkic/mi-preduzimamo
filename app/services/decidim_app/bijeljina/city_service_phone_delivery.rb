# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # Channel availability is deliberately separate from a template's shape.
    # The WhatsApp gate is off until operations verifies the exact Meta-approved
    # template in the provider account and enables its explicit setting.
    module CityServicePhoneDelivery
      TEMPLATE_NAME = "mi_gradsko_obavjestenje_v1"
      # These mappings identify boards intersecting a named place, not the
      # households affected by an unspecified street or settlement segment.
      BROAD_WATER_PRECISIONS = %w(unspecified_street_segment named_settlement_overlap possible_settlement_overlap).freeze
      KINDS = {
        "electricity_outages" => "Mogući prekidi snabdijevanja električnom energijom",
        "water_service" => "Mogući prekidi vodosnabdijevanja",
        "heating_service" => "Mogući prekidi grijanja",
        "road_conditions" => "Moguća izmjena saobraćaja"
      }.freeze

      module_function

      def phone_audience_unverified?(event)
        event.source_key == "water_service" &&
          BROAD_WATER_PRECISIONS.include?(event.extraction_metadata.dig("coverage", "scope_precision"))
      end

      def template_digest(template)
        Digest::SHA256.hexdigest(JSON.generate(canonical_template(template)))
      end

      def canonical_template(value)
        case value
        when Hash
          value.to_h.stringify_keys.sort.to_h.transform_values { |item| canonical_template(item) }
        when Array
          value.map { |item| canonical_template(item) }
        else
          value
        end
      end

      def channels(organization:)
        config = Decidim::Bih::Config.infobip
        return [] unless CityServiceSources.alerts_enabled?
        return [] unless config[:base_url].present? && config[:api_key].present?
        return [] if Decidim::Bih::IntegrationHealth.instance.send_blocked?(provider: "infobip")

        available = []
        available << "viber" if config[:viber_bm_sender].present? &&
                                Decidim::Bih::GovernanceApproval.current_for(organization, "viber_launch").present?
        available << "whatsapp" if whatsapp_ready?(organization:, config:)
        available
      rescue StandardError => e
        Rails.logger.warn("[CityServicePhoneDelivery] readiness unavailable: #{e.class}")
        []
      end

      def whatsapp_ready?(organization:, config: Decidim::Bih::Config.infobip)
        config[:messages_api_enabled] && config[:whatsapp_sender].present? &&
          config[:whatsapp_city_alert_template_approved] == true &&
          config[:whatsapp_city_alert_template_name] == TEMPLATE_NAME &&
          config[:whatsapp_city_alert_template_language] == "sr" &&
          Decidim::Bih::GovernanceApproval.current_for(organization, "external_chat_launch").present?
      end

      def template(event)
        return nil unless whatsapp_ready?(organization: event.organization)

        areas = Decidim::Bih::LocalArea.where(decidim_organization_id: event.decidim_organization_id,
                                               slug: Array(event.target_komsiluk_slugs).presence || event.area_slugs).order(:slug)
        area_names = areas.map(&:translated_name).join(", ")
        return nil if area_names.blank? || area_names.length > 100

        window = [event.starts_at, event.ends_at].compact.map do |time|
          I18n.l(time.in_time_zone("Europe/Sarajevo"), format: "%-d. %B u %H:%M", locale: :sr)
        end.join(" do ")
        return nil if window.blank?

        scope = areas.one? ? "dio komšiluka #{area_names}" : "dijelove komšiluka #{area_names}"
        body = { "1" => KINDS.fetch(event.source_key, "Gradsko obavještenje"), "2" => scope, "3" => window }
        {
          name: TEMPLATE_NAME, language: "sr", body:,
          display_text: "MI PRE(D)UZIMAMO: #{body.fetch('1')} — #{body.fetch('2')}, #{body.fetch('3')}. Detalji na tabli komšiluka.",
          button_suffix: Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_path
        }
      end
    end
  end
end
