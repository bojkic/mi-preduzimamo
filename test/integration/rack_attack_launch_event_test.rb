# frozen_string_literal: true

require "test_helper"

class RackAttackLaunchEventTest < ActiveSupport::TestCase
  SESSION = Struct.new(:id)
  IP = "203.0.113.41"

  setup do
    @old_store = Rack::Attack.cache.store
    @old_enabled = Rack::Attack.enabled
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    Rack::Attack.reset!
    travel_to Time.utc(2026, 9, 17, 18, 0, 0)
    @app = Rack::Attack.new(->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok"]] })
  end

  teardown do
    travel_back
    Rack::Attack.reset!
    Rack::Attack.cache.store = @old_store
    Rack::Attack.enabled = @old_enabled
  end

  test "500 attendees can open links maps vote and refresh results behind one IP" do
    500.times do |person|
      token = "event-#{person.to_s.rjust(32, '0')}"
      assert_equal 200, request("/v/#{token}", session: person)
      assert_equal 200, request("/v/#{token}", method: "POST", session: person)
      assert_equal 200, request("/biceriseno/mapa", session: person)
      assert_equal 200, request("/biceriseno/mapa.json", session: person)
      assert_equal 200, request("/lansiranje/anketa", session: person)
      assert_equal 200, request("/lansiranje/anketa/glas", method: "POST", session: person)
      20.times { assert_equal 200, request("/lansiranje/anketa/rezultati", session: person) }
    end
    assert_equal 200, request("/ordinary-page")
  end

  test "one personal link still allows only ten consumption attempts per minute" do
    path = "/v/event-#{'a' * 32}"
    10.times { assert_equal 200, request(path, method: "POST") }
    assert_equal 429, request(path, method: "POST")
  end

  test "one voter still has a ten submission limit regardless of json suffix" do
    10.times { assert_equal 200, request("/lansiranje/anketa/glas", method: "POST", session: 1) }
    assert_equal 429, request("/lansiranje/anketa/glas.json", method: "POST", session: 1)
    assert_equal 200, request("/lansiranje/anketa/glas", method: "POST", session: 2)
  end

  test "one result reader is bounded separately from other viewers" do
    120.times { assert_equal 200, request("/lansiranje/anketa/rezultati", session: 1) }
    assert_equal 429, request("/lansiranje/anketa/rezultati.json", session: 1)
    assert_equal 200, request("/lansiranje/anketa/rezultati", session: 2)
  end

  test "crowd exemptions retain finite IP ceilings even without sessions" do
    {
      "mi/launch-link/ip" => "/v/event-#{'b' * 32}",
      "mi/launch-map/ip" => "/biceriseno/mapa.json",
      "mi/launch-poll-read/ip" => "/lansiranje/anketa/rezultati"
    }.each do |name, path|
      rule = Rack::Attack.throttles.fetch(name)
      rule.limit.times { Rack::Attack.cache.count("#{name}:#{IP}", rule.period) }
      assert_equal 429, request(path)
    end
  end

  test "lookalike paths unrelated pages and unsupported verbs keep generic protection" do
    [
      ["/lansiranje/anketa/rezultati-other", "GET"],
      ["/v/event-short", "GET"],
      ["/biceriseno/mapa", "POST"],
      ["/lansiranje/anketa/rezultati", "POST"],
      ["/ordinary-page", "GET"]
    ].each do |path, method|
      Rack::Attack.reset!
      Decidim.throttling_max_requests.times { assert_equal 200, request(path, method: method) }
      assert_equal 429, request(path, method: method)
    end
  end

  private

  def request(path, method: "GET", session: nil)
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => IP)
    env["rack.session"] = SESSION.new("person-#{session}") unless session.nil?
    @app.call(env).first
  end
end
