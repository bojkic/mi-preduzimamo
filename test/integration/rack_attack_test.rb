# frozen_string_literal: true

require "test_helper"
# The intake form renders the Decidim layout, whose Decidim::UrlOptionResolver
# references Capybara.server_port in the test env. Plain integration tests don't
# load Capybara, so require it here (mirrors the intake test).
require "capybara"

# Rate-limiting coverage for anonymous and authenticated mounted write routes.
# The intake endpoint (POST /biceriseno/prijave) fans out to paid AI + SMTP, so
# Rack::Attack throttles it to ~10 req/min/IP. Here we drive past that ceiling
# from a single non-local IP and assert the final response is 429.
#
# Determinism: the boot initializer points Rack::Attack at Redis. For the test
# we swap in a fresh in-memory store and reset counters between examples so the
# suite never depends on (or pollutes) Redis. We also use a non-localhost IP so
# the safelist does not exempt the request.
class RackAttackTest < ActionDispatch::IntegrationTest
  i_suck_and_my_tests_are_order_dependent!

  BOT_IP = "203.0.113.7" # TEST-NET-3, never a real client / never localhost

  setup do
    @original_store = Rack::Attack.cache.store
    @original_enabled = Rack::Attack.enabled
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    Rack::Attack.reset!

    # Pin time so tests never start near a Rack::Attack period boundary. Some
    # tests advance time to avoid per-minute IP throttles while staying inside
    # the one-hour session throttle window.
    travel_to Time.zone.local(2026, 1, 1, 12, 0, 0)

    @organization = create_organization
    host! @organization.host
  end

  teardown do
    travel_back
    Rack::Attack.reset!
    Rack::Attack.cache.store = @original_store
    Rack::Attack.enabled = @original_enabled
  end

  test "localized registration paths share the same paid-message budget" do
    middleware = Rack::Attack.new(->(_env) { [204, {}, []] })
    limit = Rack::Attack.throttles.fetch("bih/registration-create/phone").limit
    paths = %w[/users /sr/users /sr-Cyrl/users /bs/users /hr/users /registracija]
    statuses = (limit + 1).times.map do |index|
      env = Rack::MockRequest.env_for(paths[index % paths.length], method: "POST",
                                     params: { "user" => { "mobile_phone_number" => "+38765000001" } })
      env["REMOTE_ADDR"] = BOT_IP
      middleware.call(env).first
    end
    assert_equal Array.new(limit, 204) + [429], statuses
  end

  test "POST /biceriseno/prijave is throttled to 429 after the per-IP limit" do
    limit = 10
    statuses = []

    # One request over the limit. A blank description is fine: throttling runs
    # in middleware, ahead of the controller, so the limiter trips regardless of
    # whether the body would have validated.
    (limit + 1).times do
      post "/biceriseno/prijave",
           params: { report: { description: "" } },
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/prijave/:reference/potvrdi (corroborate) is throttled to 429 after the per-IP limit" do
    limit = 15
    statuses = []

    # Throttling runs in middleware ahead of the controller, so the limiter trips
    # regardless of whether the reference exists — a nonexistent ref is fine here.
    (limit + 1).times do
      post "/biceriseno/prijave/BR-2026-9999/potvrdi",
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/chat is throttled to 429 after the per-IP limit" do
    limit = 30
    statuses = []

    # The chat endpoint is a same-origin JSON fetch; throttling runs in
    # middleware ahead of the controller, so the limiter trips regardless of the
    # body or the same-origin header.
    (limit + 1).times do
      post "/biceriseno/chat",
           params: { message: "zdravo" }.to_json,
           headers: { "Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest" },
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/chat/feedback is throttled to 429 after the per-IP limit" do
    limit = 60
    statuses = []

    # Feedback is a public write endpoint. The limiter runs before the
    # controller validates the signed token, so a minimal JSON body is enough.
    (limit + 1).times do
      post "/biceriseno/chat/feedback",
           params: { reply_id: SecureRandom.uuid, token: "invalid", value: "helpful" }.to_json,
           headers: { "Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest" },
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/viber/webhook is throttled to 429 after the per-IP limit" do
    limit = 60
    statuses = []

    # The webhook endpoint is public and intentionally answers quickly; the
    # throttle still runs before the controller and caps a single IP.
    (limit + 1).times do
      post "/biceriseno/viber/webhook",
           params: { results: [] }.to_json,
           headers: { "Content-Type" => "application/json" },
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "external Infobip chat webhook routes share one per-IP throttle" do
    paths = %w(whatsapp messenger instagram).map { |channel| "/biceriseno/#{channel}/webhook" }.cycle
    statuses = 61.times.map do
      post paths.next,
           params: { results: [] }.to_json,
           headers: { "Content-Type" => "application/json" },
           env: { "REMOTE_ADDR" => BOT_IP }
      response.status
    end

    assert_equal 429, statuses.last
    assert_equal 1, statuses.count(429)
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/komsiluk/suggest is throttled after the per-IP limit" do
    limit = 20
    statuses = []

    (limit + 1).times do
      post "/biceriseno/komsiluk/suggest",
           params: { address: "Glavna" },
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/komsiluk/suggest is throttled after the per-session limit" do
    limit = Rack::Attack.throttles.fetch("bih/komsiluk.suggest/session").limit
    statuses = []
    browser = browser_with_real_session

    (limit + 1).times do |index|
      # Avoid the 20/min IP throttle while staying inside the one-hour session
      # window, proving the separate session throttle is active.
      travel 61.seconds if [20, 40, 60].include?(index)

      browser.post "/biceriseno/komsiluk/suggest",
                   params: { address: "Glavna" },
                   env: { "REMOTE_ADDR" => BOT_IP }
      statuses << browser.response.status
    end

    assert_equal 429, statuses.last, "expected the request past the session limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, browser.response.body)
  end

  test "community contribution write paths share the per-IP throttle" do
    statuses = []
    writes = community_contribution_writes.cycle

    11.times do
      method, path = writes.next
      public_send(method, path, env: { "REMOTE_ADDR" => BOT_IP })
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected mixed contribution writes past the per-IP limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "community contribution write paths share the per-session throttle" do
    statuses = []
    browser = browser_with_real_session
    writes = community_contribution_writes.cycle
    over_limit = Rack::Attack.throttles.fetch("bih/community-contributions.write/session").limit + 1

    over_limit.times do |index|
      # Avoid the 10/min IP limit while keeping the combined one-hour session
      # window active.
      travel 61.seconds if index.positive? && (index % 10).zero?

      method, path = writes.next
      browser.public_send(method, path, env: { "REMOTE_ADDR" => BOT_IP })
      statuses << browser.response.status
    end

    assert_equal 429, statuses.last, "expected mixed contribution writes past the session limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, browser.response.body)
  end

  test "organization and membership write paths share the per-IP throttle" do
    writes = [
      [:post, "/biceriseno/organizacije"],
      [:post, "/biceriseno/organizacija/999/clanovi"],
      [:patch, "/biceriseno/organizacija/clanstvo/999/prihvati"],
      [:patch, "/biceriseno/organizacija/clanstvo/999/odbij"],
      [:delete, "/biceriseno/organizacija/clanstvo/999/napusti"]
    ].cycle
    statuses = 11.times.map do
      method, path = writes.next
      public_send(method, path, env: { "REMOTE_ADDR" => BOT_IP })
      response.status
    end

    assert_equal 429, statuses.last
    assert_equal 1, statuses.count(429)
  end

  test "POST /biceriseno/komsiluk-board is throttled after the per-IP limit" do
    assert_komsiluk_write_path_throttled(:post, "/biceriseno/komsiluk-board")
  end

  test "POST /biceriseno/komsiluk-board/:id/prijavi is throttled after the per-IP limit" do
    assert_komsiluk_write_path_throttled(:post, "/biceriseno/komsiluk-board/999999/prijavi")
  end

  test "PATCH /biceriseno/komsiluk-board/:id/zatvori is throttled after the per-IP limit" do
    assert_komsiluk_write_path_throttled(:patch, "/biceriseno/komsiluk-board/999999/zatvori")
  end

  test "Komšiluk board write paths share the per-session throttle" do
    limit = Rack::Attack.throttles.fetch("bih/komsiluk-board.write/session").limit
    statuses = []
    browser = browser_with_real_session
    paths = [
      [:post, "/biceriseno/komsiluk-board"],
      [:post, "/biceriseno/komsiluk-board/999999/prijavi"],
      [:patch, "/biceriseno/komsiluk-board/999999/zatvori"]
    ].cycle

    (limit + 1).times do |index|
      # Keep the one-hour session window active while avoiding the 5/min IP
      # throttle. This proves the separate per-session throttle is doing work.
      travel 61.seconds if [5, 10].include?(index)

      method, path = paths.next
      browser.public_send(method, path, env: { "REMOTE_ADDR" => BOT_IP })
      statuses << browser.response.status
    end

    assert_equal 429, statuses.last, "expected mixed Komšiluk writes past the session limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, browser.response.body)
  end

  test "requests from localhost are safelisted and never throttled" do
    20.times do
      post "/biceriseno/prijave",
           params: { report: { description: "" } },
           env: { "REMOTE_ADDR" => "127.0.0.1" }
    end

    assert_not_equal 429, response.status, "localhost must be exempt from throttling"
  end

  test "POST /v/:token is throttled after magic-link limit per IP" do
    limit = 10
    statuses = []

    (limit + 1).times do
      post "/v/garbage-token",
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    # The first `limit` requests return 422 (invalid token) from the controller;
    # the (limit+1)th should be 429 from Rack::Attack.
    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/v/:token is throttled after magic-link limit per IP" do
    limit = 10
    statuses = []

    # The engine also mounts the consume action at /biceriseno/v/:token.
    # This is the path the confirm form actually posts to, so the throttle
    # must match it exactly (previously keyed on /v/ only and missed this path).
    (limit + 1).times do
      post "/biceriseno/v/garbage-token",
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected /biceriseno/v/... requests past the limit to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/prijava is throttled per IP after phone-login limit" do
    limit = Rack::Attack.throttles.fetch("bih/phone-login/ip").limit
    statuses = []

    (limit + 1).times do
      post "/biceriseno/prijava",
           params: { phone: "+38765123456" },
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected IP throttle to kick in"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/prijava is throttled per phone after phone-login-phone limit" do
    limit = Rack::Attack.throttles.fetch("bih/phone-login/phone").limit
    statuses = []
    phone = "+38765000001"
    # Use a fresh IP so the per-IP throttle doesn't trip first.
    fresh_ip = "203.0.113.8"

    (limit + 1).times do
      post "/biceriseno/prijava",
           params: { phone: phone },
           env: { "REMOTE_ADDR" => fresh_ip }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected per-phone throttle to kick in"
    assert_match(/too many requests/i, response.body)

    # The discriminator comes from Decidim::Bih::Throttling.phone_key: a salted
    # digest, not the number and not a bare SHA-256 of it. It ends up in a
    # Rack::Attack cache key (and, on a throttled request, in the logs), and a
    # bare digest of a BiH mobile number is one lookup table away from being the
    # number. The positive assertion is the load-bearing one — it proves the
    # helper's key is what the counter actually used.
    keys = Rack::Attack.cache.store.instance_variable_get(:@data).keys
    digest = Decidim::Bih::Throttling.phone_key(phone)

    assert_not_equal Digest::SHA256.hexdigest(phone), digest, "the phone key must be salted, not a bare digest"

    assert keys.any? { |key| key.include?("bih/phone-login/phone:#{digest}") },
           "expected the per-phone counter to be keyed on the digest"
    assert_not keys.any? { |key| key.include?(phone) },
               "the raw phone number must never appear in a Rack::Attack cache key"
  end

  test "POST /biceriseno/prijava/kod is throttled after login-code limit per IP" do
    limit = Rack::Attack.throttles.fetch("bih/phone-login-code/ip").limit
    statuses = []
    fresh_ip = "203.0.113.9"

    (limit + 1).times do
      post "/biceriseno/prijava/kod",
           params: { verification_code: "000000" },
           env: { "REMOTE_ADDR" => fresh_ip }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected login-code IP throttle to kick in"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "GET and POST /registracija/drustvene-mreze share one per-IP handoff budget" do
    # Read the ceiling from the rule rather than restating it, so changing the
    # limit moves this test with it instead of leaving it asserting an old one.
    limit = Rack::Attack.throttles.fetch("bih/social-registration-handoff/ip").limit

    # Both verbs are counted: the GET renders the claim page and already does
    # the Redis peek for the pending handoff, so it costs what the POST costs.
    # Alternating them proves they share the budget rather than each getting a
    # full one of their own.
    statuses = (limit + 1).times.map do |index|
      if index.even?
        get "/registracija/drustvene-mreze", env: { "REMOTE_ADDR" => "203.0.113.10" }
      else
        post "/registracija/drustvene-mreze", env: { "REMOTE_ADDR" => "203.0.113.10" }
      end
      response.status
    end

    assert_equal 429, statuses.last
    assert_equal 1, statuses.count(429)
    assert_match(/too many requests/i, response.body)
  end

  test "POST /biceriseno/pozivnica/potvrdi is throttled to 429 after the per-IP limit" do
    limit = 10
    statuses = []

    # Throttling runs in middleware ahead of the controller, so the limiter
    # trips regardless of whether the visitor is signed in or holds a
    # launch invitation.
    (limit + 1).times do
      post "/biceriseno/pozivnica/potvrdi",
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "POST /admin/bih/pozivnice/provjera is throttled to 429 after the per-IP limit" do
    limit = 60
    statuses = []

    # Throttling runs in middleware ahead of the controller, so the limiter
    # trips regardless of admin/operator authentication or the submitted code.
    (limit + 1).times do
      post "/admin/bih/pozivnice/provjera",
           params: { entry_code: "MI-XXXXX-XXXXX" },
           env: { "REMOTE_ADDR" => BOT_IP }
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected the request past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end

  private

  # A browser with a REAL session, not a pinned Cookie header.
  #
  # These tests used to inject a fabricated cookie value. That was enough while
  # the per-session discriminator keyed on the cookie STRING, but the string is
  # AES-GCM ciphertext that rotates on nearly every response, so keying on it
  # meant no per-session throttle ever fired in production. Now the
  # discriminator reads the session ID — and a fabricated cookie decrypts to
  # nothing, which would make these fall back to the IP and quietly stop being
  # per-session tests. So: mint a real session the way the app does. A failed
  # sign-in is the cheapest deterministic way (it writes a flash, so the app
  # issues a session cookie) and leaves the visitor anonymous, as these
  # endpoints expect.
  def browser_with_real_session
    session = open_session
    session.host! @organization.host
    session.post "/users/sign_in",
                 params: { user: { email: "nobody-#{SecureRandom.hex(3)}@example.org", password: "wrong" } },
                 env: { "REMOTE_ADDR" => BOT_IP }

    session_key = Rails.application.config.session_options.fetch(:key)
    assert session.cookies[session_key].present?,
           "the warm-up must leave a real session cookie, otherwise this is a per-IP test in disguise"

    session
  end

  def community_contribution_writes
    [
      [:post, "/biceriseno/projekti"],
      [:patch, "/biceriseno/projekti/prijave/999999"],
      [:post, "/biceriseno/volontiranje/potrebe"],
      [:post, "/biceriseno/volontiranje/potrebe/999999/otkazi"],
      [:post, "/biceriseno/volontiranje/potrebe/999999/ponude"],
      [:post, "/biceriseno/volontiranje/ponude/999999/prihvati"],
      [:post, "/biceriseno/volontiranje/ponude/999999/odbij"],
      [:post, "/biceriseno/volontiranje/ponude/999999/povuci"],
      [:post, "/biceriseno/volontiranje/ponude/999999/isporuceno"],
      [:post, "/biceriseno/volontiranje/ponude/999999/potvrdi"]
    ]
  end

  def assert_komsiluk_write_path_throttled(method, path)
    limit = 5
    statuses = []

    (limit + 1).times do
      public_send(method, path, env: { "REMOTE_ADDR" => BOT_IP })
      statuses << response.status
    end

    assert_equal 429, statuses.last, "expected #{method.to_s.upcase} #{path} past the limit to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)
  end
end
