# frozen_string_literal: true

require "test_helper"

# The komšiluk address-suggest flow geocodes the typed address in-request and
# must never persist or LOG it. Rails' own request-parameter logging is the one
# place in-controller care cannot reach, so the binding guarantee here is that
# :address (and phone) are in config.filter_parameters.
module Decidim
  module Bih
    class KomsilukAddressLogPrivacyTest < ActiveSupport::TestCase
      # filter_parameters is compiled into a single Regexp in this app, so we
      # assert on BEHAVIOR (does the filter mask the value?) rather than on the
      # presence of a symbol in the config array.
      test "the parameter filter masks address, geocoded_address and phone values" do
        filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
        masked = filter.filter(
          "address" => "Karađorđeva 12, Bijeljina",
          "geocoded_address" => "Račanska bb",
          "mobile_phone_number" => "+38766900004",
          "phone" => "066900004",
          "tab" => "kako"
        )
        assert_equal "[FILTERED]", masked["address"], "address must be filtered from logs"
        assert_equal "[FILTERED]", masked["geocoded_address"], "geocoded_address must be filtered"
        assert_equal "[FILTERED]", masked["mobile_phone_number"], "phone number must be filtered"
        assert_equal "[FILTERED]", masked["phone"], "phone must be filtered"
        assert_equal "kako", masked["tab"], "non-sensitive params stay readable"
      end
    end
  end
end
