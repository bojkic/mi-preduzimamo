# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportServiceRequestTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
      end

      def report(**attrs)
        Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Reporter-entered private text",
          **attrs
        )
      end

      test "maps internal statuses to public service-request statuses" do
        expected = {
          "primljeno" => "received",
          "proslijedjeno" => "sent_to_service",
          "u_obradi" => "in_progress",
          "rijeseno" => "resolved",
          "odbijeno" => "not_actionable"
        }

        expected.each do |internal_status, public_status|
          assert_equal public_status, Decidim::Bih::ReportServiceRequest.public_status_for(internal_status)
          assert_equal internal_status, Decidim::Bih::ReportServiceRequest.internal_status_for(public_status)
        end
      end

      test "serializes a PII-light service request by default" do
        canonical = report(reference: "BR-2026-0100")
        current = report(
          reference: "BR-2026-0101",
          status: "proslijedjeno",
          category: "putevi",
          department: "Odjeljenje za stambeno-komunalne poslove",
          severity: "normalan",
          address: "Karađorđeva 1",
          latitude: 44.75,
          longitude: 19.21,
          reporter_email: "secret@example.org",
          reporter_phone: "065123456",
          anonymous: false,
          sistem48_reference: "S48-42",
          sistem48_status: "Zaprimljeno",
          duplicate_of: canonical,
          corroboration_count: 2,
          needs_review: true
        )

        payload = Decidim::Bih::ReportServiceRequest.new(current).to_h(locale: :sr)

        assert_equal "putevi", payload[:service_category]
        assert_equal "putevi", payload[:service_code]
        assert_equal "BR-2026-0101", payload[:request_reference]
        assert_equal "duplicate", payload[:public_status]
        assert_equal I18n.t("decidim.bih.reports.public_statuses.duplicate", locale: :sr),
                     payload[:public_status_label]
        assert_equal "proslijedjeno", payload[:internal_status]
        assert_equal({ address: "Karađorđeva 1", latitude: 44.75, longitude: 19.21 }, payload[:location])
        assert_equal({ photo_attached: false }, payload[:media])
        assert_equal({ present: true, anonymous: false }, payload[:private_reporter_contact])
        assert_equal "Odjeljenje za stambeno-komunalne poslove", payload.dig(:city_service_routing, :department)
        assert_equal true, payload.dig(:city_service_routing, :needs_operator_review)
        assert_equal "S48-42", payload[:external_reference]
        assert_equal "Zaprimljeno", payload[:external_status]
        assert_equal "BR-2026-0100", payload.dig(:duplicate_cluster, :duplicate_of_reference)
        assert_equal 2, payload.dig(:duplicate_cluster, :corroboration_count)
        assert_equal "request_sent_to_service", payload[:update_history].detect { |stage| stage[:current] }[:event_type]
        assert_not_nil payload.dig(:timestamps, :created_at)

        json = payload.to_json
        assert_not_includes json, "secret@example.org"
        assert_not_includes json, "065123456"
        assert_not_includes json, current.status_token
        assert_not_includes json, "Reporter-entered private text"
      end

      test "raw reporter contact is explicit opt-in" do
        current = report(
          reporter_email: "contact@example.org",
          reporter_phone: "065111222",
          anonymous: false
        )

        payload = Decidim::Bih::ReportServiceRequest.new(current).to_h(include_private_contact: true)

        assert_equal "contact@example.org", payload.dig(:private_reporter_contact, :email)
        assert_equal "065111222", payload.dig(:private_reporter_contact, :phone)
      end

      test "update history maps lifecycle stages to adapter event types" do
        current = report(reference: "BR-2026-0102")
        current.update!(status: "proslijedjeno")
        current.update!(status: "u_obradi")
        current.update!(status: "odbijeno")

        history = Decidim::Bih::ReportServiceRequest.new(current).update_history(locale: :sr)

        assert_equal(
          %w(
            request_received
            request_sent_to_service
            request_in_progress
            request_not_actionable
          ),
          history.map { |stage| stage[:event_type] }
        )
        assert_equal "not_actionable", history.last[:public_status]
        assert_equal I18n.t("decidim.bih.reports.public_statuses.not_actionable", locale: :sr),
                     history.last[:public_status_label]
      end
    end
  end
end
