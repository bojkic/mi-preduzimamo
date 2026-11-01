# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class CityServicePhoneDeliveryTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @healthy = Object.new
        @healthy.define_singleton_method(:send_blocked?) { |**| false }
      end

      test "an unapproved WhatsApp template never joins a working Viber route" do
        config = provider_config(whatsapp_city_alert_template_approved: false)
        with_readiness(config) do
          assert_equal ["viber"], CityServicePhoneDelivery.channels(organization: @organization)
        end
      end

      test "approved exact template permits WhatsApp without a Viber sender" do
        config = provider_config(viber_bm_sender: nil, whatsapp_city_alert_template_approved: true)
        with_readiness(config) do
          assert_equal ["whatsapp"], CityServicePhoneDelivery.channels(organization: @organization)
        end
      end

      test "wrong template name cannot enable WhatsApp" do
        config = provider_config(viber_bm_sender: nil, whatsapp_city_alert_template_approved: true,
                                 whatsapp_city_alert_template_name: "different_template")
        with_readiness(config) do
          assert_empty CityServicePhoneDelivery.channels(organization: @organization)
        end
      end

      test "WhatsApp approval is independent of Viber launch approval" do
        config = provider_config(viber_bm_sender: nil, whatsapp_city_alert_template_approved: true)
        with_readiness(config, approval: ->(_organization, kind) { kind == "external_chat_launch" ? nil : Object.new }) do
          assert_empty CityServicePhoneDelivery.channels(organization: @organization)
        end
      end

      test "template fingerprint survives JSON key conversion and order changes" do
        approved = { name: "mi_gradsko_obavjestenje_v1", body: { "1" => "Voda", "2" => "dio komšiluka" }, language: "sr" }
        persisted = { "language" => "sr", "body" => { "2" => "dio komšiluka", "1" => "Voda" }, "name" => "mi_gradsko_obavjestenje_v1" }
        assert_equal CityServicePhoneDelivery.template_digest(approved), CityServicePhoneDelivery.template_digest(persisted)
        refute_equal CityServicePhoneDelivery.template_digest(approved),
                     CityServicePhoneDelivery.template_digest(persisted.merge("body" => { "1" => "Struja", "2" => "dio komšiluka" }))
      end

      test "broad water geometry is a board destination, not a verified phone audience" do
        %w(unspecified_street_segment named_settlement_overlap possible_settlement_overlap).each do |precision|
          event = Struct.new(:source_key, :extraction_metadata).new(
            "water_service", { "coverage" => { "scope_precision" => precision } }
          )
          assert CityServicePhoneDelivery.phone_audience_unverified?(event), precision
        end

        exact_station = Struct.new(:source_key, :extraction_metadata).new(
          "electricity_outages", { "coverage" => { "scope_precision" => "part_of_area" } }
        )
        refute CityServicePhoneDelivery.phone_audience_unverified?(exact_station)
      end

      private

      def provider_config(**overrides)
        { base_url: "https://provider.example", api_key: "configured", viber_bm_sender: "ViberBM",
          messages_api_enabled: true, whatsapp_sender: "WhatsApp",
          whatsapp_city_alert_template_name: CityServicePhoneDelivery::TEMPLATE_NAME,
          whatsapp_city_alert_template_language: "sr", whatsapp_city_alert_template_approved: false }.merge(overrides)
      end

      def with_readiness(config, approval: Object.new, &block)
        DecidimApp::Bijeljina::CityServiceSources.stub(:alerts_enabled?, true) do
          Decidim::Bih::IntegrationHealth.stub(:instance, @healthy) do
            Decidim::Bih::Config.stub(:infobip, config) do
              Decidim::Bih::GovernanceApproval.stub(:current_for, approval, &block)
            end
          end
        end
      end
    end
  end
end
