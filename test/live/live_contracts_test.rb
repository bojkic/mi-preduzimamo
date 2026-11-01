# frozen_string_literal: true

require "test_helper"
require "bigdecimal"
require "securerandom"

# Live external contracts are intentionally outside default PR gates. Run with:
#
#   LIVE_CONTRACTS=1 bin/rails test test/live
#
# Each test below must use controlled test tenants/recipients/sinks only. Keep
# credential values in the process environment and never print them in failures.
class LiveContractsTest < ActiveSupport::TestCase
  setup do
    skip "set LIVE_CONTRACTS=1 to run live external contract checks" unless ENV["LIVE_CONTRACTS"] == "1"
  end

  test "Odoo donation contract is wired for read-only shape checks" do
    required = %w(ODOO_URL ODOO_DB ODOO_LOGIN ODOO_API_KEY ODOO_TEST_PRODUCT_IDS)
    missing = required.select { |key| ENV[key].blank? }
    skip "missing Odoo live contract environment: #{missing.join(", ")}" if missing.any?

    raw_ids = ENV.fetch("ODOO_TEST_PRODUCT_IDS").split(",")
    product_ids = raw_ids.map { |value| Integer(value.strip, 10, exception: false) }
    assert raw_ids.length.between?(1, 100) &&
           product_ids.all? { |value| value.is_a?(Integer) && value.positive? } &&
           product_ids.uniq.length == product_ids.length,
           "ODOO_TEST_PRODUCT_IDS must list 1-100 distinct positive test product IDs"

    result = Decidim::Bih::Odoo::DonationTotals.new(
      product_ids: product_ids,
      cache_namespace: "live-contract-#{SecureRandom.hex(4)}"
    ).call(raise_errors: true)

    assert_kind_of Decidim::Bih::Odoo::DonationTotals::Result, result
    assert result.total.is_a?(BigDecimal)
    assert_operator result.total, :>=, BigDecimal("0")
    assert_kind_of Integer, result.count
    assert_operator result.count, :>=, 0
    assert_equal "BAM", result.currency
    assert_kind_of Time, result.as_of
  end

  test "Infobip outbound contract is wired for controlled test sinks" do
    required = %w(INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_TEST_RECIPIENT INFOBIP_SMS_SENDER)
    missing = required.select { |key| ENV[key].blank? }
    skip "missing Infobip live contract environment: #{missing.join(", ")}" if missing.any?
    skip "set INFOBIP_LIVE_SEND=1 to permit a controlled live SMS send" unless ENV["INFOBIP_LIVE_SEND"] == "1"

    result = Decidim::Bih::Infobip::Client.new.send_sms(
      to: ENV.fetch("INFOBIP_TEST_RECIPIENT"),
      from: ENV.fetch("INFOBIP_SMS_SENDER"),
      text: "MI contract smoke #{Time.now.utc.strftime("%Y-%m-%d %H:%M:%S UTC")}"
    )

    status_name = result.dig("messages", 0, "status", "name").to_s
    assert status_name.present?, "expected Infobip to return a message status"
    assert_match(/\A[A-Z0-9_ -]+\z/, status_name)
  end
end
