# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Decidim
  module Bih
    module Odoo
      class DonationTotalsTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        BASE = "https://odoo.test"
        RPC = "#{BASE}/jsonrpc".freeze

        def client
          Client.new(base_url: BASE, db: "fdb", login: "odoo-user@example.invalid", api_key: "key")
        end

        def build(product_ids: [901, 902], **)
          DonationTotals.new(client: client, product_ids:, cache_namespace: "test-#{SecureRandom.hex(4)}", **)
        end

        setup do
          WebMock.disable_net_connect!(allow_localhost: true)
          # The test env uses :null_store; swap in a real store so the cache
          # round-trip (refresh! writes, cached reads) is observable.
          @previous_cache = Rails.cache
          Rails.cache = ActiveSupport::Cache::MemoryStore.new
        end
        teardown do
          Rails.cache = @previous_cache
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        # Stub authenticate (uid) + the sale.order.line search_read returning rows.
        def stub_odoo(rows)
          stub_request(:post, RPC)
            .with(body: hash_including("params" => hash_including("method" => "authenticate")))
            .to_return(status: 200, body: { result: 2 }.to_json)
          stub_request(:post, RPC)
            .with(body: hash_including("params" => hash_including("method" => "execute_kw")))
            .to_return(status: 200, body: { result: rows }.to_json)
        end

        test "missing product configuration never queries a configured Odoo client" do
          fake = Struct.new(:reads) do
            def configured? = true
            def read(*)
              self.reads += 1
              []
            end
          end.new(0)
          result = DonationTotals.new(client: fake, cache_namespace: "unconfigured-products").call
          assert_equal 0, fake.reads
          assert_equal BigDecimal("0"), result.total
          assert_nil result.as_of
        end

        test "unconfigured products neither return cached funds nor enqueue a refresh" do
          service = DonationTotals.new(client: client, cache_namespace: "unconfigured-cache")
          prior = DonationTotals::Result.new(total: BigDecimal("42"), count: 1, currency: "BAM", as_of: Time.current)
          Rails.cache.write(service.cache_key, prior)
          result = nil
          assert_no_enqueued_jobs { result = service.cached }
          assert_equal BigDecimal("0"), result.total
          assert_nil result.as_of
          assert_equal prior, Rails.cache.read(service.cache_key)
        end

        test "sums price_total over confirmed donation lines and counts distinct orders" do
          stub_odoo([
                      { "price_total" => 30.0, "order_id" => [101, "S0101"] },
                      { "price_total" => 45.0, "order_id" => [101, "S0101"] },
                      { "price_total" => 50.0, "order_id" => [102, "S0102"] }
                    ])

          result = build.call

          assert_equal BigDecimal("125"), result.total
          assert_equal 2, result.count # two distinct orders
          assert_equal "BAM", result.currency
          assert_not_nil result.as_of
        end

        test "sends the confirmed-states + donation-product domain to Odoo" do
          stub_request(:post, RPC)
            .with(body: hash_including("params" => hash_including("method" => "authenticate")))
            .to_return(status: 200, body: { result: 2 }.to_json)
          exec = stub_request(:post, RPC)
                 .with { |req| donation_domain?(req) }
                 .to_return(status: 200, body: { result: [] }.to_json)

          build.call

          assert_requested(exec)
        end

        test "adds a date_order lower bound when date_from is given" do
          stub_request(:post, RPC)
            .with(body: hash_including("params" => hash_including("method" => "authenticate")))
            .to_return(status: 200, body: { result: 2 }.to_json)
          exec = stub_request(:post, RPC)
                 .with { |req| domain_includes_date?(req, "2026-01-01") }
                 .to_return(status: 200, body: { result: [] }.to_json)

          build(date_from: "2026-01-01").call

          assert_requested(exec)
        end

        test "appends an extra Odoo domain filter when given" do
          stub_request(:post, RPC)
            .with(body: hash_including("params" => hash_including("method" => "authenticate")))
            .to_return(status: 200, body: { result: 2 }.to_json)
          filter = ["order_id.campaign_id.name", "=", "mi-project"]
          exec = stub_request(:post, RPC)
                 .with { |req| parsed_domain(req)&.include?(filter) }
                 .to_return(status: 200, body: { result: [] }.to_json)

          build(extra_domain: [filter]).call

          assert_requested(exec)
        end

        test "returns a zeroed result (never raises) on an Odoo fault" do
          stub_request(:post, RPC)
            .to_return(status: 200, body: { error: { data: { message: "boom" } } }.to_json)

          result = build.call

          assert_equal BigDecimal("0"), result.total
          assert_equal 0, result.count
          assert_nil result.as_of
        end

        test "returns a zeroed result when the client is unconfigured" do
          unconfigured = Client.new(base_url: nil, db: nil, login: nil, api_key: nil)
          result = DonationTotals.new(client: unconfigured, cache_namespace: "u").call

          assert_equal BigDecimal("0"), result.total
          assert_equal 0, result.count
        end

        test "falls back to price_subtotal when a row has no price_total" do
          stub_odoo([{ "price_subtotal" => 20.0, "order_id" => [9, "S9"] }])

          assert_equal BigDecimal("20"), build.call.total
        end

        # --- caching ------------------------------------------------------

        test "refresh! computes and writes the cache; cached reads it back" do
          stub_odoo([{ "price_total" => 60.0, "order_id" => [1, "S1"] }])
          totals = build

          written = totals.refresh!
          assert_equal BigDecimal("60"), written.total

          # The read path must NOT hit Odoo again — reset stubs and read cache.
          WebMock.reset!
          WebMock.disable_net_connect!
          cached = totals.cached
          assert_equal BigDecimal("60"), cached.total
          assert_equal 1, cached.count
        end

        test "refresh! keeps a previously cached non-zero total on a transient Odoo fault" do
          # First, a successful refresh seeds a non-zero cached total.
          stub_odoo([{ "price_total" => 200.0, "order_id" => [7, "S7"] }])
          totals = build
          seeded = totals.refresh!
          assert_equal BigDecimal("200"), seeded.total

          # Now a transient Odoo fault on a non-raising refresh (the cron path).
          WebMock.reset!
          stub_request(:post, RPC)
            .to_return(status: 200, body: { error: { data: { message: "boom" } } }.to_json)

          result = totals.refresh!(raise_errors: false)

          # The errored result is zero, but the cache must NOT be clobbered.
          assert_equal BigDecimal("0"), result.total
          cached = Rails.cache.read(totals.cache_key)
          assert_equal BigDecimal("200"), cached.total
          assert_equal 1, cached.count
          assert_not_nil cached.as_of
        end

        test "refresh! still caches a successful zero total (genuinely no donations)" do
          stub_odoo([])
          totals = build

          result = totals.refresh!(raise_errors: false)

          assert_equal BigDecimal("0"), result.total
          assert_not_nil result.as_of # a real, successful query
          cached = Rails.cache.read(totals.cache_key)
          assert_not_nil cached
          assert_equal BigDecimal("0"), cached.total
          assert_not_nil cached.as_of
        end

        test "refresh! clears the refresh lock even when keeping the cached value" do
          stub_odoo([{ "price_total" => 200.0, "order_id" => [7, "S7"] }])
          totals = build
          totals.refresh!

          Rails.cache.write(totals.refresh_lock_key, true, expires_in: 2.minutes)
          WebMock.reset!
          stub_request(:post, RPC)
            .to_return(status: 200, body: { error: { data: { message: "boom" } } }.to_json)

          totals.refresh!(raise_errors: false)

          assert_nil Rails.cache.read(totals.refresh_lock_key)
        end

        test "CACHE_TTL comfortably outlasts the hourly refresh cron so the key never gaps" do
          assert_operator DonationTotals::CACHE_TTL, :>, 1.hour
        end

        test "refresh! can raise Odoo errors for background job retries" do
          stub_request(:post, RPC)
            .to_return(status: 200, body: { error: { data: { message: "boom" } } }.to_json)
          totals = build

          assert_raises(Decidim::Bih::Odoo::Error) do
            totals.refresh!(raise_errors: true)
          end
          assert_nil Rails.cache.read(totals.cache_key)
        end

        test "cached returns a cheap zero and enqueues a refresh on a cold cache" do
          totals = build
          assert_enqueued_with(job: Decidim::Bih::Odoo::RefreshDonationTotalsJob) do
            result = totals.cached
            assert_equal BigDecimal("0"), result.total
            assert_nil result.as_of
          end
        end

        test "cold cache enqueues only one refresh while the refresh lock is hot" do
          totals = build

          assert_enqueued_jobs 1, only: Decidim::Bih::Odoo::RefreshDonationTotalsJob do
            2.times do
              result = totals.cached
              assert_equal BigDecimal("0"), result.total
            end
          end
        end

        test "refresh clears the cold-cache refresh lock after a successful write" do
          totals = build
          Rails.cache.write(totals.refresh_lock_key, true, expires_in: 2.minutes)
          stub_odoo([{ "price_total" => 15.0, "order_id" => [3, "S3"] }])

          totals.refresh!

          assert_nil Rails.cache.read(totals.refresh_lock_key)
        end

        test "cache_key folds in namespace and config so different configs don't collide" do
          a = DonationTotals.new(client: client, cache_namespace: "org1")
          b = DonationTotals.new(client: client, cache_namespace: "org2")
          c = DonationTotals.new(client: client, cache_namespace: "org1", date_from: "2026-01-01")
          d = DonationTotals.new(client: client, cache_namespace: "org1",
                                 extra_domain: [["order_id.campaign_id.name", "=", "mi-project"]])

          assert_not_equal a.cache_key, b.cache_key
          assert_not_equal a.cache_key, c.cache_key
          assert_not_equal a.cache_key, d.cache_key
        end

        private

        def parsed_domain(req)
          body = JSON.parse(req.body)
          # execute_kw args: [db, uid, key, model, method, [domain], kwargs]
          body.dig("params", "args", 5, 0)
        end

        def donation_domain?(req)
          domain = parsed_domain(req)
          return false unless domain

          domain.include?(["order_id.state", "in", %w(sale done)]) &&
            domain.include?(["product_id.product_tmpl_id", "in", [901, 902]])
        end

        def domain_includes_date?(req, date)
          domain = parsed_domain(req)
          return false unless domain

          domain.include?(["order_id.date_order", ">=", date])
        end
      end
    end
  end
end
