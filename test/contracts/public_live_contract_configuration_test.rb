# frozen_string_literal: true
require "test_helper"
require_relative "../live/live_contracts_test"

# Exercise the actual optional contract methods with authored configuration and
# fake clients. No external credentials, provider delivery or network is used.
class PublicLiveContractConfigurationTest < ActiveSupport::TestCase
  KEYS = %w(LIVE_CONTRACTS ODOO_URL ODOO_DB ODOO_LOGIN ODOO_API_KEY ODOO_TEST_PRODUCT_IDS
            INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_TEST_RECIPIENT INFOBIP_SMS_SENDER INFOBIP_LIVE_SEND).freeze
  ODOO_CASE = "test_Odoo_donation_contract_is_wired_for_read-only_shape_checks"
  SMS_CASE = "test_Infobip_outbound_contract_is_wired_for_controlled_test_sinks"

  setup do
    @prior = KEYS.to_h { |key| [key, ENV[key]] }
    KEYS.each { |key| ENV.delete(key) }
  end

  teardown do
    @prior.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "Odoo contract forwards only explicitly selected test products" do
    configure_odoo
    calls = []
    result = Decidim::Bih::Odoo::DonationTotals::Result.new(total: BigDecimal("12"), count: 2, currency: "BAM", as_of: Time.current)
    totals = Object.new
    totals.define_singleton_method(:call) { |**options| calls << options; result }
    inputs = []
    factory = ->(**options) { inputs << options; totals }
    Decidim::Bih::Odoo::DonationTotals.stub(:new, factory) do
      LiveContractsTest.new(ODOO_CASE).public_send(ODOO_CASE)
    end
    assert_equal 1, inputs.length
    assert_equal [901, 902], inputs.first.fetch(:product_ids)
    assert_equal [{ raise_errors: true }], calls
  end

  test "Odoo contract rejects invalid product scope before constructing a client" do
    configure_odoo
    ENV["ODOO_TEST_PRODUCT_IDS"] = "901,0"
    factory = ->(**) { flunk "unscoped Odoo client must not be constructed" }
    Decidim::Bih::Odoo::DonationTotals.stub(:new, factory) do
      failure = assert_raises(Minitest::Assertion) { LiveContractsTest.new(ODOO_CASE).public_send(ODOO_CASE) }
      assert_includes failure.message, "distinct positive test product IDs"
    end
  end

  test "SMS contract without its own sender skips before client construction" do
    configure_sms
    ENV.delete("INFOBIP_SMS_SENDER")
    factory = -> { flunk "an inherited sender must never reach a client" }
    Decidim::Bih::Infobip::Client.stub(:new, factory) do
      skipped = assert_raises(Minitest::Skip) { LiveContractsTest.new(SMS_CASE).public_send(SMS_CASE) }
      assert_includes skipped.message, "INFOBIP_SMS_SENDER"
    end
  end

  test "SMS contract uses its explicit sender and controlled test recipient" do
    configure_sms
    calls = []
    client = Object.new
    client.define_singleton_method(:send_sms) do |**options|
      calls << options
      { "messages" => [{ "status" => { "name" => "PENDING_TEST" } }] }
    end
    Decidim::Bih::Infobip::Client.stub(:new, client) do
      LiveContractsTest.new(SMS_CASE).public_send(SMS_CASE)
    end
    assert_equal 1, calls.length
    assert_equal "CommunityFixture", calls.first.fetch(:from)
    assert_equal "+12025550101", calls.first.fetch(:to)
  end

  private

  def configure_odoo
    ENV.update("ODOO_URL" => "https://erp.example.invalid", "ODOO_DB" => "authored_fixture",
               "ODOO_LOGIN" => "operator@example.invalid", "ODOO_API_KEY" => "authored-test-key",
               "ODOO_TEST_PRODUCT_IDS" => "901,902")
  end

  def configure_sms
    ENV.update("INFOBIP_BASE_URL" => "https://provider.example.invalid", "INFOBIP_API_KEY" => "authored-test-key",
               "INFOBIP_TEST_RECIPIENT" => "+12025550101", "INFOBIP_SMS_SENDER" => "CommunityFixture",
               "INFOBIP_LIVE_SEND" => "1")
  end
end
