# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
# General host mail tests retain ActionMailer's test adapter. Dedicated mailbox
# tests explicitly select Gmail with fixture configuration.
ENV["REPORT_MAIL_TRANSPORT"] ||= "relay"

require_relative "../script/lib/mi_test_guard"

# FAIL CLOSED if the test database is not a test database.
#
# .env sets DATABASE_URL to the LIVE decidim_production database, and Rails
# gives DATABASE_URL precedence over config/database.yml — so sourcing .env
# before `bin/rails test` silently points the suite at production. The suite
# then calls maintain_test_schema!, which PURGES (drops and reloads) whatever
# database it resolved. On 2026-09-01 that wiped production and took the site
# down until it was restored from the nightly dump.
#
# This runs before config/environment is loaded, so it aborts before Rails can
# touch the database at all. Run tests with no DATABASE_URL set (or
# `env -u DATABASE_URL bin/rails test`).
begin
  MiTestGuard.reject_named_database_urls!(ENV)
  MiTestGuard.database_from_url!(ENV.fetch("DATABASE_URL")) unless ENV.fetch("DATABASE_URL", "").empty?
rescue MiTestGuard::Invalid => e
  abort "Refusing test database configuration: #{e.message}. Use an isolated task database or unset DATABASE_URL."
end

# FAIL CLOSED if Redis is not an explicit test endpoint.
#
# Production Redis is db0 on 127.0.0.1:6379, and the old code fallback was db1
# on the same instance, so test runs wrote integration-health keys into the
# production server. The suite now needs an explicit REDIS_URL that is neither
# of those nor the production endpoint (checked against /etc/mi-platform/runtime.env
# and the live .env when readable; only REDIS_*_URL lines, never printed).
# REDIS_URL is also Sidekiq's default, so this covers clients
# that do not use the shared resolver. Bundler setup opens no connection;
# nothing else is loaded before the check.
require_relative "../config/boot"
require "decidim/bih/redis_endpoint"
begin
  Decidim::Bih::RedisEndpoint.guard_test_environment!(ENV)
rescue Decidim::Bih::RedisEndpoint::Error => e
  abort "Refusing test Redis configuration: #{e.message}. Use the task run wrapper or set REDIS_URL to a dedicated test endpoint."
end
# The same engine guard is mode aware (Decidim::Bih::TestRedisInstance): it
# judges where a URL lands, and once the dedicated test instance is installed
# it accepts only that instance (server-health plan item 7).
# Latch this process as a test process before the application loads. Tests stub
# Rails.env (e.g. as "production"); the latch keeps every Redis client resolving
# through the fail-closed test path regardless. Production never latches.
Decidim::Bih::RedisEndpoint.mark_test_process!

require_relative "../config/environment"
require "rails/test_help"
# Standalone contracts can disable discovery; retain Rails reporting in this suite.
require "minitest/rails_plugin"
Minitest.extensions << "rails" unless Minitest.extensions.include?("rails")
require "minitest/mock"
require_relative "support/mi_timing_reporter" if ENV["MI_TEST_TIMINGS_PATH"].present?
require_relative "support/decidim_test_setup"
require_relative "support/shakapacker_manifest_stub"

# Purge leftover :test ActiveStorage disk blobs from a PREVIOUS run before this
# one starts. That service writes attachments to tmp/storage and Rails never
# cleans them, so without this they pile up across runs (this once filled the
# server disk to 100%). Done at load — before the parallel workers fork — so it
# never races a running test; glob("*") skips the tracked .keep placeholder.
require "fileutils"
FileUtils.rm_rf(Rails.root.glob("tmp/storage/*"))

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    test_workers = ENV["MI_TEST_WORKERS"].to_s.strip
    parallelize(workers: test_workers.empty? ? :number_of_processors : Integer(test_workers, 10))

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # FactoryBot syntax (create/build/...) and Decidim record helpers.
    include FactoryBot::Syntax::Methods
    include DecidimFactoryHelpers

    # Safety net for the Nominatim geocoder. Some flows (e.g. komšiluk resolution
    # during a grant/postal flow) can geocode incidentally; if a test doesn't stub
    # it, the call hits WebMock's disabled net-connect and raises — and under the
    # parallel runner this surfaced as an order-dependent flake. Register a default
    # "no match" stub so a stray call returns nil instead of erroring. Tests that
    # exercise geocoding register their own stub, which WebMock matches first
    # (most-recently-registered wins), so this never masks their assertions.
    # Guarded on defined?(WebMock): WebMock is required per-file, so in the full
    # suite (the parent loads every file before forking workers) it is always
    # present and the stub catches stray geocoding; an isolated run of a
    # WebMock-free file skips it harmlessly.
    setup do
      if defined?(WebMock)
        geocoder_stub_hosts.each do |host|
          WebMock.stub_request(:get, %r{\Ahttps?://#{Regexp.escape(host)}/})
                 .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
        end
      end
    end

    private

    # Pre-cutover work has no dated interval. These fixtures exercise historic
    # aggregate/read paths only; citizen claims must use normal model validation.
    def create_legacy_volunteer_log!(**attributes)
      Decidim::Bih::VolunteerLog.new(**attributes).tap { |log| log.save!(validate: false) }
    end

    def geocoder_stub_hosts
      [
        "nominatim.openstreetmap.org",
        geocoder_host_from(ENV.fetch("DECIDIM_BIH_GEOCODER_BASE_URL", nil)),
        geocoder_host_from(ENV.fetch("NOMINATIM_HOST", nil)),
        geocoder_host_from(Decidim::Bih.geocoder_base_url)
      ].compact.uniq
    end

    def geocoder_host_from(url)
      return if url.blank?

      URI(url).host
    rescue URI::InvalidURIError
      nil
    end
  end
end
