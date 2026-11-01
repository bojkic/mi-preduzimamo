# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Decidim
  module Bih
    module Odoo
      class ClientTest < ActiveSupport::TestCase
        BASE = "https://odoo.test"
        RPC = "#{BASE}/jsonrpc".freeze

        def client
          Client.new(base_url: BASE, db: "fdb", login: "odoo-user@example.invalid", api_key: "key")
        end

        setup { WebMock.disable_net_connect!(allow_localhost: true) }
        teardown do
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        test "configured? requires url, db, login and api_key" do
          assert client.configured?
          assert_not Client.new(base_url: BASE, db: "d", login: "l", api_key: nil).configured?
          assert_not Client.new(base_url: nil, db: "d", login: "l", api_key: "k").configured?
        end

        test "uid authenticates and memoizes" do
          stub = stub_request(:post, RPC)
                 .with(body: hash_including("params" => hash_including("method" => "authenticate")))
                 .to_return(status: 200, body: { result: 7 }.to_json, headers: { "Content-Type" => "application/json" })

          c = client
          assert_equal 7, c.uid
          assert_equal 7, c.uid # memoized
          assert_requested(stub, times: 1)
        end

        test "execute_kw authenticates then calls the model method and returns the result" do
          stub_request(:post, RPC)
            .with(body: hash_including("params" => hash_including("method" => "authenticate")))
            .to_return(status: 200, body: { result: 3 }.to_json)
          exec = stub_request(:post, RPC)
                 .with(body: hash_including("params" => hash_including("method" => "execute_kw")))
                 .to_return(status: 200, body: { result: [{ "name" => "Donacija" }] }.to_json)

          rows = client.read("account.move", [["x", "=", 1]], %w(name))
          assert_equal "Donacija", rows.first["name"]
          assert_requested(exec)
        end

        test "raises on an Odoo JSON-RPC fault" do
          body = { error: { data: { message: "bad api_key=key phone=38765111222" } } }.to_json
          stub_request(:post, RPC).to_return(status: 200, body: body)
          error = assert_raises(Decidim::Bih::Odoo::Error) { client.uid }

          assert_includes error.message, "Odoo fault"
          assert_not_includes error.message, "api_key=key"
          assert_not_includes error.message, "38765111222"
          assert_not_includes error.message, "1222"
          assert_nil error.cause
        end

        test "raises when unconfigured" do
          assert_raises(Decidim::Bih::Odoo::Error) do
            Client.new(base_url: nil, db: nil, login: nil, api_key: nil).read("res.partner")
          end
        end
      end
    end
  end
end
