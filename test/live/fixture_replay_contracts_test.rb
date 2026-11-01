# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require "support/provider_stubs"

class FixtureReplayContractsTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include ProviderStubs

  FILE_FIXTURES = Rails.root.join("test/fixtures/files")

  setup do
    config = WebMock::Config.instance
    @webmock_config = %i(allow_net_connect allow_localhost allow net_http_connect_on_start).to_h { |key| [key, config.public_send(key)] }
    WebMock.disable_net_connect!
    keys = ["SISTEM48_CENTRAL_INTAKE", "SISTEM48_FROM"] + Decidim::Bih::ReportTaxonomy::CATEGORIES.map { |category| Decidim::Bih::Sistem48::DepartmentRouting.env_key(category) }
    @routing_env = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV.delete(key) }
    @central_intake = Decidim::Bih.sistem48_central_intake
    @mailer_from = Decidim::Bih.sistem48_mailer_from
    Decidim::Bih.sistem48_central_intake = "intake@example.invalid"
    Decidim::Bih.sistem48_mailer_from = "reports@example.invalid"
  end

  teardown do
    WebMock.reset!
    @webmock_config.each { |key, prior| WebMock::Config.instance.public_send("#{key}=", prior) }
    Decidim::Bih.sistem48_central_intake = @central_intake
    Decidim::Bih.sistem48_mailer_from = @mailer_from
    @routing_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "Gemini intent-classification replay matches the schema contract" do
    stub = stub_gemini("gemini_intent_classification_response.json") do |request|
      gemini_body(request).dig("generationConfig", "response_schema", "properties", "intent", "enum")
                          .include?("service")
    end

    result = gemini_client.generate_content(
      contents: [{ role: "user", parts: [{ text: "Gdje mogu dobiti izvod?" }] }],
      response_schema: Decidim::Bih::Concierge::IntentClassifier::RESPONSE_SCHEMA
    )

    assert_requested(stub)
    assert_includes Decidim::Bih::Concierge::IntentClassifier::INTENTS.map(&:to_s), result.fetch("intent")
    assert_equal "service", result.fetch("intent")
    assert_equal "izvod iz maticne knjige rodjenih", result.fetch("query")
  end

  test "Odoo DonationTotals replay keeps the JSON-RPC domain and result shape stable" do
    exec = stub_odoo_donation_fixture
    totals = Decidim::Bih::Odoo::DonationTotals.new(client: odoo_client, product_ids: [901, 902], cache_namespace: "replay")

    result = totals.call

    assert_requested(exec)
    assert_equal BigDecimal("50"), result.total
    assert_equal 2, result.count
    assert_equal "BAM", result.currency
    assert result.as_of.present?
  end

  test "Odoo client replay keeps auth and read response shape stable" do
    exec = stub_odoo_donation_fixture
    rows = odoo_client.read(
      "sale.order.line",
      [
        ["order_id.state", "in", %w(sale done)],
        ["product_id.product_tmpl_id", "in", [901, 902]]
      ],
      %w(price_total order_id),
      limit: false
    )

    assert_requested(exec)
    assert_equal 2, rows.length
    assert_equal 30.0, rows.first.fetch("price_total")
    assert_equal [101, "S0101"], rows.first.fetch("order_id")
  end

  test "Infobip SMS Viber text and Viber image replay preserves outbound shape" do
    sms = stub_infobip_sms
    viber_text = stub_infobip_viber_content("TEXT")
    viber_image = stub_infobip_viber_content("IMAGE") do |body|
      content = body.dig("messages", 0, "content")
      content["imageUrl"] == "https://mi.example.test/mi/stickers/prijavljeno.png" &&
        content["text"] == "Bravo!"
    end

    client = Decidim::Bih::Infobip::Client.new(base_url: INFOBIP_BASE, api_key: "test-key")

    sms_result = client.send_sms(to: "+1 202 555 0123", text: "Kod: 123456", from: "LFTest")
    text_result = client.send_viber(to: "+1 202 555 0123", text: "Zdravo", sender: "SyntheticViberSender")
    image_result = client.send_viber_image(
      to: "+1 202 555 0123",
      image_url: "https://mi.example.test/mi/stickers/prijavljeno.png",
      text: "Bravo!",
      sender: "SyntheticViberSender"
    )

    assert_requested(sms)
    assert_requested(viber_text)
    assert_requested(viber_image)
    assert_equal "PENDING_ACCEPTED", sms_result.dig("messages", 0, "status", "name")
    assert_equal "PENDING_ACCEPTED", text_result.dig("messages", 0, "status", "name")
    assert_equal "PENDING_ACCEPTED", image_result.dig("messages", 0, "status", "name")
  end

  test "Infobip inbound Viber replay parses text image and location messages" do
    text = Decidim::Bih::Viber::InboundMessage.parse(fixture_json("infobip_viber_inbound_text.json"))
    image = Decidim::Bih::Viber::InboundMessage.parse(fixture_json("infobip_viber_inbound_image.json"))
    location = Decidim::Bih::Viber::InboundMessage.parse(fixture_json("infobip_viber_inbound_location.json"))

    assert_equal "TEXT", text.type
    assert_equal "Izmišljeno pitanje o usluzi.", text.text
    assert_nil text.image_url
    assert_not text.location?

    assert_equal "IMAGE", image.type
    assert_equal "Izmišljena fotografija problema.", image.text
    assert_equal "https://media.example.invalid/authored-photo.jpg", image.image_url
    assert_not image.location?

    assert_equal "LOCATION", location.type
    assert_equal "Izmišljena lokacija prijave.", location.text
    assert_in_delta 0.125, location.latitude, 0.0001
    assert_in_delta 0.375, location.longitude, 0.0001
    assert location.location?
  end

  test "Sistem48 forwarding replay emits the expected operator email" do
    report = fixture_json("sistem48_report.json").symbolize_keys

    assert_emails 1 do
      assert Decidim::Bih::Sistem48::Forwarder.new.call(report)
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [Decidim::Bih::Sistem48::DepartmentRouting.central_intake], mail.to
    assert_includes mail.subject, "BR-2040-0001"
    assert_includes mail.body.encoded, "IZMISLJENA PRIJAVA: ne radi testna rasvjeta."
  end

  test "Sistem48 authored archive replay preserves the supported public markup" do
    entries = Decidim::Bih::Sistem48::ArchiveScraper.new.parse(FILE_FIXTURES.join("synthetic/sistem48_archive.html").read)

    assert_equal 4, entries.size
    assert_equal "2040900001", entries.first.fetch(:reference)
    assert_equal "Prijava riješena", entries.first.fetch(:status)
    assert_includes entries.map { |entry| entry.fetch(:status) }, "Obrada u toku"
    assert_includes entries.map { |entry| entry.fetch(:status) }, "Nenadležni za prijavu"
  end
end
