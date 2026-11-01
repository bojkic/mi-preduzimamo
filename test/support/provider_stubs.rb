# frozen_string_literal: true

# Shared WebMock stub helpers for provider integrations (Gemini, Odoo, Infobip).
# Extracted from FixtureReplayContractsTest so any test file that needs to stub
# these providers can include this module instead of duplicating the helpers.
#
# Usage:
#   require "test/support/provider_stubs"
#   class MyTest < ActiveSupport::TestCase
#     include ProviderStubs
#     ...
#   end
#
# Stub behaviour is unchanged from the original FixtureReplayContractsTest.
module ProviderStubs
  CONTRACT_FIXTURES = Pathname.new(__dir__).join("../fixtures/files/contracts").cleanpath

  GEMINI_BASE = "https://gen.example.com"
  GEMINI_MODEL = "gemini-flash-lite-latest"
  GEMINI_ENDPOINT = "#{GEMINI_BASE}/v1beta/models/#{GEMINI_MODEL}:generateContent".freeze

  ODOO_BASE = "https://odoo.test"
  ODOO_RPC = "#{ODOO_BASE}/jsonrpc".freeze

  INFOBIP_BASE = "https://test.api.infobip.com"

  def fixture(name)
    CONTRACT_FIXTURES.join(name).read
  end

  def fixture_json(name)
    JSON.parse(fixture(name))
  end

  def gemini_client
    Decidim::Bih::Ai::GeminiClient.new(
      api_key: "test-key",
      base_url: GEMINI_BASE,
      model: GEMINI_MODEL
    )
  end

  def odoo_client
    Decidim::Bih::Odoo::Client.new(
      base_url: ODOO_BASE,
      db: "synthetic_community",
      login: "api@example.test",
      api_key: "test-key"
    )
  end

  # Stubs a Gemini generateContent POST. The caller block receives the raw
  # request and returns true/false to select this stub.
  def stub_gemini(response_fixture)
    stub_request(:post, GEMINI_ENDPOINT)
      .with(headers: { "x-goog-api-key" => "test-key" }) do |request|
        request.uri.query.blank? && yield(request)
      end
      .to_return(
        status: 200,
        body: fixture(response_fixture),
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stubs the Odoo authenticate + execute_kw (donation lines) pair and returns
  # the execute_kw stub for assert_requested.
  def stub_odoo_donation_fixture
    stub_request(:post, ODOO_RPC)
      .with(body: hash_including("params" => hash_including("method" => "authenticate")))
      .to_return(
        status: 200,
        body: fixture("odoo_authenticate_response.json"),
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, ODOO_RPC)
      .with { |request| odoo_donation_execute_kw?(request) }
      .to_return(
        status: 200,
        body: fixture("odoo_donation_lines_response.json"),
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_infobip_sms
    stub_request(:post, "#{INFOBIP_BASE}/sms/2/text/advanced")
      .with(headers: { "Authorization" => "App test-key" }) do |request|
        body = infobip_body(request)
        body.dig("messages", 0, "from") == "LFTest" &&
          body.dig("messages", 0, "destinations", 0, "to") == "12025550123"
      end
      .to_return(
        status: 200,
        body: fixture("infobip_accepted_response.json"),
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_infobip_viber_content(type)
    stub_request(:post, "#{INFOBIP_BASE}/viber/2/messages")
      .with(headers: { "Authorization" => "App test-key" }) do |request|
        body = infobip_body(request)
        content = body.dig("messages", 0, "content")
        body.dig("messages", 0, "sender") == "SyntheticViberSender" &&
          body.dig("messages", 0, "destinations", 0, "to") == "12025550123" &&
          content["type"] == type &&
          (!block_given? || yield(body))
      end
      .to_return(
        status: 200,
        body: fixture("infobip_accepted_response.json"),
        headers: { "Content-Type" => "application/json" }
      )
  end

  def gemini_body(request)
    JSON.parse(request.body)
  end

  def infobip_body(request)
    JSON.parse(request.body)
  end

  def odoo_donation_execute_kw?(request)
    body = JSON.parse(request.body)
    args = body.dig("params", "args")
    domain = args.dig(5, 0)

    body.dig("params", "method") == "execute_kw" &&
      args[3] == "sale.order.line" &&
      args[4] == "search_read" &&
      args.dig(6, "fields") == %w(price_total order_id) &&
      domain.include?(["order_id.state", "in", %w(sale done)]) &&
      domain.include?(["product_id.product_tmpl_id", "in", [901, 902]])
  end
end
