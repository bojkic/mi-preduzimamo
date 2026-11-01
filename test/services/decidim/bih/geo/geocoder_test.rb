# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Decidim
  module Bih
    module Geo
      class GeocoderTest < ActiveSupport::TestCase
        setup do
          @prior_test_geocoder_agent = Decidim::Bih.geocoder_user_agent
          Decidim::Bih.geocoder_user_agent = "AuthoredGeocoderTest/1.0 (geocoding@example.invalid)"
        end

        teardown do
          Decidim::Bih.geocoder_user_agent = @prior_test_geocoder_agent
        end

        # ─── Successful geocode ───────────────────────────────────────────────

        test "returns lat/lon hash on successful Nominatim response" do
          stub_nominatim_success do
            result = Geocoder.coordinates("Izmišljena breza 12, Izmišljeno polje")
            assert_not_nil result
            assert_in_delta 0.156, result[:lat], 0.001
            assert_in_delta 0.214, result[:lon], 0.001
          end
        end

        # ─── Empty results ────────────────────────────────────────────────────

        test "returns nil when Nominatim returns empty array" do
          stub_nominatim_empty do
            result = Geocoder.coordinates("nowhere on earth 99999")
            assert_nil result
          end
        end

        # ─── Network failure ──────────────────────────────────────────────────

        test "returns nil on Faraday connection error" do
          stub_nominatim_error(Faraday::ConnectionFailed.new("refused")) do
            result = Geocoder.coordinates("Izmišljeno polje")
            assert_nil result
          end
        end

        test "returns nil on Faraday timeout" do
          stub_nominatim_error(Faraday::TimeoutError.new("timeout")) do
            result = Geocoder.coordinates("Izmišljeno polje")
            assert_nil result
          end
        end

        # ─── Invalid JSON ─────────────────────────────────────────────────────

        test "returns nil on malformed JSON response" do
          stub_nominatim_bad_json do
            result = Geocoder.coordinates("Izmišljeno polje")
            assert_nil result
          end
        end

        # ─── Blank address ────────────────────────────────────────────────────

        test "returns nil without making a network call for blank address" do
          # If Faraday were called it would fail (no stub); the nil return proves
          # it short-circuits before the HTTP call.
          assert_nil Geocoder.coordinates("")
          assert_nil Geocoder.coordinates(nil)
          assert_nil Geocoder.coordinates("   ")
        end

        # ─── Address is NEVER persisted ───────────────────────────────────────

        test "geocoder does not persist the address string anywhere" do
          # The geocoder takes an address string and returns coordinates only.
          # We verify no DB row was created that could contain the address.
          address = "Ulica Za Test #{SecureRandom.hex(8)}"
          stub_nominatim_success do
            Geocoder.coordinates(address)
          end

          # No model should have persisted the address string
          assert_equal 0, ActiveRecord::Base.connection.select_value(
            "SELECT COUNT(*) FROM decidim_bih_citizen_profiles WHERE source LIKE '%#{address.first(10)}%'"
          ).to_i
        end

        test "sends the configured (host-set) Nominatim User-Agent" do
          original = Decidim::Bih.geocoder_user_agent
          Decidim::Bih.geocoder_user_agent = "TestApp/9 (example.test; geocoding)"
          begin
            ua = Geocoder.new.send(:connection).headers["User-Agent"]
            assert_equal "TestApp/9 (example.test; geocoding)", ua
          ensure
            Decidim::Bih.geocoder_user_agent = original
          end
        end

        test "uses the host-configured geocoder base URL before legacy env" do
          with_geocoder_endpoint(
            configured: "https://geocoder.internal.example",
            generic_env: "https://generic-env-geocoder.example",
            legacy_env: "https://legacy-nominatim.example"
          ) do
            assert_equal "https://geocoder.internal.example/", Geocoder.new.send(:connection).url_prefix.to_s
          end
        end

        test "falls back to DECIDIM_BIH_GEOCODER_BASE_URL when no configured base URL is set" do
          with_geocoder_endpoint(
            configured: nil,
            generic_env: "https://generic-env-geocoder.example",
            legacy_env: "https://legacy-nominatim.example"
          ) do
            assert_equal "https://generic-env-geocoder.example/", Geocoder.new.send(:connection).url_prefix.to_s
          end
        end

        test "falls back to NOMINATIM_HOST for legacy hosts" do
          with_geocoder_endpoint(configured: nil, generic_env: nil, legacy_env: "https://legacy-nominatim.example") do
            assert_equal "https://legacy-nominatim.example/", Geocoder.new.send(:connection).url_prefix.to_s
          end
        end

        test "falls back to public Nominatim when no host endpoint is configured" do
          with_geocoder_endpoint(configured: nil, generic_env: nil, legacy_env: nil) do
            assert_equal "#{Geocoder::DEFAULT_HOST}/", Geocoder.new.send(:connection).url_prefix.to_s
          end
        end

        test "uses a configured geocoder search path" do
          with_geocoder_endpoint(configured: "https://geocoder.internal.example", search_path: "api/search") do
            geocoder = Geocoder.new
            fake_response = Minitest::Mock.new
            fake_response.expect(:success?, true)
            fake_response.expect(:body, '[{"lat":"0.156","lon":"0.214"}]')
            fake_conn = Minitest::Mock.new
            fake_conn.expect(:get, fake_response, ["/api/search", Hash])

            geocoder.stub(:connection, fake_conn) do
              assert_equal({ lat: 0.156, lon: 0.214 }, geocoder.coordinates("Glavna 1"))
            end
          end
        end

        test "adds optional geocoder headers for contracted compatible providers" do
          with_geocoder_endpoint(
            configured: "https://geocoder.internal.example",
            extra_headers: { "X-Geocoder-Token" => "redacted-test-token" }
          ) do
            headers = Geocoder.new.send(:connection).headers
            assert_equal "redacted-test-token", headers["X-Geocoder-Token"]
            assert_equal Decidim::Bih.geocoder_user_agent, headers["User-Agent"]
          end
        end

        test "does not leak the citizen address into logs on a Faraday error" do
          address = "Tajna Ulica #{SecureRandom.hex(6)}"
          # Faraday error messages can embed the request URL including ?q=<address>.
          error = Faraday::ConnectionFailed.new(
            "connection refused: http://nominatim.test/search?q=#{address}&format=jsonv2"
          )
          io = StringIO.new
          original_logger = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(io)
          begin
            stub_nominatim_error(error) { Geocoder.coordinates(address) }
          ensure
            Rails.logger = original_logger
          end

          assert_not_includes io.string, address
        end

        test "candidate search retains multiple address precisions without changing coordinates API" do
          rows = [
            { lat: "0.158", lon: "0.215", display_name: "Glavna 12", category: "place", type: "house", address: { house_number: "12", road: "Glavna" } },
            { lat: "0.157", lon: "0.214", display_name: "Glavna", category: "highway", type: "residential", address: { road: "Glavna" } },
            { lat: "0.156", lon: "0.213", display_name: "Naselje", category: "boundary", type: "administrative", address: { village: "Naselje" } },
            { lat: "not-a-number", lon: "0.213", display_name: "Invalid" }
          ]
          connection = Object.new
          connection.define_singleton_method(:get) do |_path, params|
            raise unless params[:limit] == 5 && params[:addressdetails] == 1

            Struct.new(:success?, :body).new(true, rows.to_json)
          end
          geocoder = Geocoder.new
          geocoder.stub(:connection, connection) do
            result = geocoder.search("Glavna", limit: 100)
            assert_equal(%w(address street place), result.map { |row| row.fetch(:precision) })
            assert_equal "12", result.first.dig(:address, "house_number")
            assert_equal "Glavna", result[1].fetch(:label)
          end
        end

        private

        # Stubs Faraday connection at the geocoder level with a successful JSON response.
        def stub_nominatim_success
          geocoder = Geocoder.new
          fake_response = Minitest::Mock.new
          fake_response.expect(:success?, true)
          fake_response.expect(:body, '[{"lat":"0.156","lon":"0.214","place_id":1}]')

          fake_conn = Minitest::Mock.new
          fake_conn.expect(:get, fake_response, ["/search", Hash])

          geocoder.stub(:connection, fake_conn) do
            Geocoder.stub(:new, geocoder) do
              yield
            end
          end
        end

        def stub_nominatim_empty
          geocoder = Geocoder.new
          fake_response = Minitest::Mock.new
          fake_response.expect(:success?, true)
          fake_response.expect(:body, "[]")

          fake_conn = Minitest::Mock.new
          fake_conn.expect(:get, fake_response, ["/search", Hash])

          geocoder.stub(:connection, fake_conn) do
            Geocoder.stub(:new, geocoder) do
              yield
            end
          end
        end

        def stub_nominatim_error(error)
          geocoder = Geocoder.new
          fake_conn = Object.new
          fake_conn.define_singleton_method(:get) { |*_args| raise error }

          geocoder.stub(:connection, fake_conn) do
            Geocoder.stub(:new, geocoder) do
              yield
            end
          end
        end

        def stub_nominatim_bad_json
          geocoder = Geocoder.new
          fake_response = Minitest::Mock.new
          fake_response.expect(:success?, true)
          fake_response.expect(:body, "not valid json {{")

          fake_conn = Minitest::Mock.new
          fake_conn.expect(:get, fake_response, ["/search", Hash])

          geocoder.stub(:connection, fake_conn) do
            Geocoder.stub(:new, geocoder) do
              yield
            end
          end
        end

        def with_geocoder_endpoint(configured:, generic_env: nil, legacy_env: nil, search_path: nil, extra_headers: nil)
          original_configured = Decidim::Bih.geocoder_base_url
          original_search_path = Decidim::Bih.geocoder_search_path
          original_extra_headers = Decidim::Bih.geocoder_extra_headers
          original_generic_env = ENV.fetch("DECIDIM_BIH_GEOCODER_BASE_URL", nil)
          original_env = ENV.fetch("NOMINATIM_HOST", nil)

          Decidim::Bih.geocoder_base_url = configured
          Decidim::Bih.geocoder_search_path = search_path if search_path
          Decidim::Bih.geocoder_extra_headers = extra_headers if extra_headers
          set_optional_env("DECIDIM_BIH_GEOCODER_BASE_URL", generic_env)
          set_optional_env("NOMINATIM_HOST", legacy_env)

          yield
        ensure
          Decidim::Bih.geocoder_base_url = original_configured
          Decidim::Bih.geocoder_search_path = original_search_path
          Decidim::Bih.geocoder_extra_headers = original_extra_headers
          set_optional_env("DECIDIM_BIH_GEOCODER_BASE_URL", original_generic_env)
          set_optional_env("NOMINATIM_HOST", original_env)
        end

        def set_optional_env(key, value)
          if value.nil?
            ENV.delete(key)
          else
            ENV[key] = value
          end
        end
      end
    end
  end
end
