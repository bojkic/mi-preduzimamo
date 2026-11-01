# frozen_string_literal: true

require "test_helper"
# The sign-up form renders the Decidim layout, whose Decidim::UrlOptionResolver
# references Capybara.server_port in the test env. Plain integration tests don't
# load Capybara, so require it here (mirrors rack_attack_test.rb).
require "capybara"

# Rate-limiting coverage for the registration and phone-verification paths
# (delivery A). Every code or link this app sends is a paid Infobip message and
# sign-up itself had no ceiling at all, so each of these rules is load-bearing.
#
# The names, limits, periods AND discriminators are declared by
# Decidim::Bih.required_public_throttles, and
# script/mi_public_throttle_contract_smoke fails the release gate when the host
# configures them differently. So no test here hardcodes a ceiling: every loop
# bound is read from Rack::Attack.throttles, which means a registry change moves
# these tests with it instead of quietly leaving them asserting last month's
# numbers.
#
# The discriminator split is the point of the whole scheme. On 17.9. roughly 310
# citizens register from one room over ONE egress IP, so every surface a
# signed-in citizen touches during registration is keyed per SESSION; only
# anonymous sign-up stays per IP, and it is sized for a crowd (200/15 min) with
# MI_RACK_ATTACK_SAFELIST_IPS as the escape hatch for the event itself. Each
# session-keyed test therefore proves both halves: one session hits its ceiling,
# and a SECOND session from the same IP still gets through.
#
# The session-keyed tests drive REAL browsers (ActionDispatch's own
# open_session, its own cookie jar, the app's own Set-Cookie) rather than a
# pinned Cookie header. That is not fastidiousness: the discriminator reads the
# session ID, and a fabricated cookie decrypts to nothing, so a pinned header
# would silently fall back to the IP and every "per session" assertion here
# would be measuring per-IP behaviour instead.
#
# Determinism: the boot initializer points Rack::Attack at Redis. Here we swap
# in a fresh in-memory store and pin the clock so the suite never depends on (or
# pollutes) Redis and never straddles a period boundary. Each test uses its own
# non-localhost IP, because localhost is safelisted.
class RackAttackPhoneVerificationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  i_suck_and_my_tests_are_order_dependent!

  # TEST-NET-3 addresses: never a real client, never localhost. One per test so
  # a shared per-IP budget can never make a neighbouring test's assertion pass
  # or fail for the wrong reason.
  REGISTRATION_IP = "203.0.113.20"
  SMS_SESSION_IP = "203.0.113.21"
  SMS_PHONE_IP = "203.0.113.22"
  CODE_IP = "203.0.113.23"
  RESEND_IP = "203.0.113.24"
  CHANGE_IP = "203.0.113.25"
  STATUS_IP = "203.0.113.26"
  SMS_PRECEDENCE_IP = "203.0.113.27"
  SMS_SCALAR_IP = "203.0.113.28"
  SESSION_FLOW_IP = "203.0.113.29"
  CORE_CEILING_IP = "203.0.113.30"
  CORE_POLL_IP = "203.0.113.31"
  SAFELISTED_IP = "203.0.113.40"
  UNLISTED_IP = "203.0.113.41"
  ENGINE_SKEW_IP = "203.0.113.42"
  MALFORMED_BODY_IP = "203.0.113.43"
  STATUS_CEILING_IP = "203.0.113.44"
  STATUS_SHARED_IP = "203.0.113.45"
  STATUS_PREFIX_IP = "203.0.113.46"
  # Delivery D — the one-step registration's root paths.
  ONE_STEP_CREATE_IP = "203.0.113.50"
  ONE_STEP_CODE_IP = "203.0.113.51"
  ONE_STEP_RESEND_IP = "203.0.113.52"
  ONE_STEP_CHANGE_IP = "203.0.113.53"
  ONE_STEP_STATUS_IP = "203.0.113.54"
  ONE_STEP_STATUS_CORE_IP = "203.0.113.55"
  ONE_STEP_STATUS_IP_CEILING_IP = "203.0.113.56"
  EMAIL_CONFIRMATION_IP = "203.0.113.57"

  PHONE_VERIFICATION_PATH = "/biceriseno/verifikacija/telefon"

  # Delivery D serves the one-step registration twice: at the root path this
  # host owns (config/initializers/decidim_bih_registration.rb) and under the
  # engine mount, which goes on answering. Both are the same controller and the
  # same paid messages, so both must be metered — and by the SAME budget, or
  # alternating between them would silently double every ceiling.
  REGISTRATION_PATH = "/registracija"
  PENDING_PATH = "/registracija/potvrda"
  MOUNTED_REGISTRATION_PATH = "/biceriseno/registracija"
  MOUNTED_PENDING_PATH = "/biceriseno/registracija/potvrda"
  EMAIL_CONFIRMATION_PATH = "/biceriseno/potvrdi-email"

  setup do
    @original_store = Rack::Attack.cache.store
    @original_enabled = Rack::Attack.enabled
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    Rack::Attack.reset!

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

  test "POST /users is throttled once one IP passes the sign-up ceiling" do
    name = "bih/registration-create/ip"

    # 200 real sign-ups would be a slow, pointless way to prove a counter. Fill
    # the counter through Rack::Attack's own cache API instead — this is the
    # exact call Throttle#matched_by? makes — leaving room for one more.
    fill_counter(name, REGISTRATION_IP, to: throttle_for(name).limit - 1)

    post "/users", params: { user: sign_up_params(1) }, env: { "REMOTE_ADDR" => REGISTRATION_IP }
    assert_not_equal 429, response.status, "the request that reaches the ceiling must still be served"

    post "/users", params: { user: sign_up_params(2) }, env: { "REMOTE_ADDR" => REGISTRATION_IP }
    assert_equal 429, response.status, "the request past the ceiling must be throttled"
    assert_match(/too many requests/i, response.body)

    # Signing in is a different path and keeps its own budget: a throttled
    # sign-up flood must not lock the same household out of the login form.
    post "/users/sign_in",
         params: { user: { email: "nobody@example.org", password: "wrong" } },
         env: { "REMOTE_ADDR" => REGISTRATION_IP }

    assert_not_equal 429, response.status, "POST /users/sign_in must not share the sign-up budget"
  end

  # The per-IP ceiling above is set for a venue on one NAT and the safelist
  # relaxes it further, so it bounds nothing a script does from a few
  # addresses — and every POST spends a real message on whatever number was
  # typed. This budget keys on the NUMBER (review 2026-09-07, lane 2 M1).
  test "POST /registracija is throttled per phone number, whatever the IP" do
    name = "bih/registration-create/phone"
    limit = throttle_for(name).limit

    statuses = (limit + 1).times.map do |index|
      post "/registracija",
           params: { user: sign_up_params(index).merge(mobile_phone_number: "+387 65 123 456") },
           env: { "REMOTE_ADDR" => "203.0.113.#{index + 1}" }
      response.status
    end

    assert_equal 429, statuses.last, "the request past the per-phone ceiling must be throttled"
    assert_equal 1, statuses.count(429), "exactly the over-limit request is throttled"

    post "/registracija",
         params: { user: sign_up_params(99).merge(mobile_phone_number: "+38766999888") },
         env: { "REMOTE_ADDR" => "203.0.113.1" }

    assert_not_equal 429, response.status, "a different number keeps its own counter"
  end

  # Spacing must not buy another paid message: the discriminator normalises
  # before digesting, exactly as the sign-in and SMS-verification rules do.
  test "the per-phone sign-up budget ignores how the number is spelled" do
    name = "bih/registration-create/phone"
    limit = throttle_for(name).limit
    spellings = ["+38765123456", "+387 65 123 456", "+387-65-123-456", "+387 65 123-456", "+387 65 123 456 ", "+38765123456"]

    statuses = spellings.first(limit + 1).map.with_index do |spelling, index|
      post "/registracija",
           params: { user: sign_up_params(index).merge(mobile_phone_number: spelling) },
           env: { "REMOTE_ADDR" => "198.51.100.#{index + 1}" }
      response.status
    end

    assert_equal 429, statuses.last, "the same number written differently shares one budget"
  end

  test "MI_RACK_ATTACK_SAFELIST_IPS relaxes IP-keyed limits for the venue and nobody else" do
    # The list is parsed once at boot, so the seam the suite stubs is the
    # reader, not the environment variable.
    with_safelisted_venue_ip do
      # The new phone-first rule...
      assert_ip_rule_relaxed_for_venue("bih/registration-create/ip") do |ip, index|
        post "/users", params: { user: sign_up_params(index) }, env: { "REMOTE_ADDR" => ip }
      end

      # ...and a pre-existing one, because the helper is the discriminator of
      # every IP-keyed rule in the file, not a special case bolted onto sign-up.
      assert_ip_rule_relaxed_for_venue("bih/reports.create/ip") do |ip, _index|
        post "/biceriseno/prijave", params: { report: { description: "" } }, env: { "REMOTE_ADDR" => ip }
      end
    end
  end

  test "a safelisted venue IP is still counted by the per-phone and per-session limits" do
    # This is the whole reason the venue list is a discriminator and not a
    # Rack::Attack safelist. A safelist short-circuits ahead of every rule, so
    # listing the venue would also switch off the budget that stops ONE number
    # being billed over and over from that room — which is exactly the abuse a
    # crowded venue makes easy, not the abuse it excuses.
    with_safelisted_venue_ip do
      phone_name = "bih/sms-authorization-create/phone"
      statuses = (throttle_for(phone_name).limit + 1).times.map do
        post "/sms/authorizations",
             params: { mobile_phone: { mobile_phone_number: "+38765311311" } },
             env: { "REMOTE_ADDR" => SAFELISTED_IP }
        response.status
      end

      assert_equal 429, statuses.last, "the per-phone budget must still bite for a safelisted IP"

      session_name = "bih/sms-authorization-create/session"
      venue = browser_at(SAFELISTED_IP)
      statuses = (throttle_for(session_name).limit + 1).times.map do |index|
        send_sms_authorization(venue, "+3876532200#{index}", SAFELISTED_IP)
        venue.response.status
      end

      assert_equal 429, statuses.last, "the per-session budget must still bite for a safelisted IP"
    end
  end

  test "the per-phone budget keeps counting when the engine's Throttling constant is missing" do
    # Host and engine are separate repositories, and on this server production
    # loads the engine from a working tree through a Bundler local override. A
    # host that boots against an engine tree without Decidim::Bih::Throttling
    # would otherwise raise NameError INSIDE the Rack::Attack middleware —
    # a 500 on the paid-send endpoint, handed to anyone who posts the form,
    # rather than a throttle that keeps working.
    name = "bih/sms-authorization-create/phone"

    without_engine_throttling do
      statuses = (throttle_for(name).limit + 1).times.map do
        post "/sms/authorizations",
             params: { mobile_phone: { mobile_phone_number: "+38765414141" } },
             env: { "REMOTE_ADDR" => ENGINE_SKEW_IP }
        response.status
      end

      assert_not_includes statuses, 500, "an absent engine constant must never surface as a server error"
      assert_equal 429, statuses.last, "the fallback key must still count the same number"
      assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
      assert_match(/too many requests/i, response.body)
    end
  end

  test "a body Rack cannot parse does not turn the per-phone rule into a server error" do
    # The discriminator reads request.params, which parses the body. A truncated
    # multipart POST makes that raise, and it raises inside the middleware — so
    # without the rescue this endpoint hands an attacker an error on demand.
    boundary = "----MiTruncated"

    post "/sms/authorizations",
         headers: { "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}" },
         env: { "REMOTE_ADDR" => MALFORMED_BODY_IP },
         params: "--#{boundary}\r\nContent-Disposition: form-data; name=\"mobile_phone[mobile_phone_number]\"\r\n"

    assert_not_equal 500, response.status, "an unparseable body must not 500 the paid-send endpoint"

    # ...and the endpoint is still healthy for the next, well-formed request.
    post "/sms/authorizations",
         params: { mobile_phone: { mobile_phone_number: "+38765515151" } },
         env: { "REMOTE_ADDR" => MALFORMED_BODY_IP }

    assert_not_equal 500, response.status
    assert_not_equal 429, response.status
  end

  test "Decidim core's platform-wide per-IP ceiling still throttles an unlisted address" do
    name = "requests by ip"
    throttle = throttle_for(name)

    # Core's own numbers, read rather than copied, so DECIDIM_THROTTLING_* keeps
    # working and this test follows it.
    assert_equal Decidim.throttling_max_requests, throttle.limit
    assert_equal Decidim.throttling_period.to_i, throttle.period

    fill_counter(name, CORE_CEILING_IP, to: throttle.limit - 1)

    get PHONE_VERIFICATION_PATH, env: { "REMOTE_ADDR" => CORE_CEILING_IP }
    assert_not_equal 429, response.status, "the request that reaches the ceiling must still be served"

    get PHONE_VERIFICATION_PATH, env: { "REMOTE_ADDR" => CORE_CEILING_IP }
    assert_equal 429, response.status, "the request past the platform-wide ceiling must be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "a safelisted venue IP is not subject to the platform-wide per-IP ceiling" do
    # The reason this rule is re-registered at all: 100 requests a minute is the
    # tightest ceiling on the platform, and a room of 310 citizens shares one
    # address. Core keys it on the bare IP; here it goes through the same
    # MiRackAttack.ip_key as every other IP-keyed rule.
    name = "requests by ip"

    with_safelisted_venue_ip do
      fill_counter(name, SAFELISTED_IP, to: throttle_for(name).limit + 1)
      get PHONE_VERIFICATION_PATH, env: { "REMOTE_ADDR" => SAFELISTED_IP }

      assert_not_equal 429, response.status, "a listed venue IP must be served past the platform-wide ceiling"
    end
  end

  test "the verification status poll does not count toward the platform-wide ceiling" do
    # The page polls every three seconds. Counting that against a 100/minute
    # per-IP budget would let five citizens on one office or cafe NAT exhaust it
    # between them without doing anything wrong. The poll has its own
    # per-session ceiling instead.
    name = "requests by ip"
    fill_counter(name, CORE_POLL_IP, to: throttle_for(name).limit)

    3.times do
      get "#{PHONE_VERIFICATION_PATH}/status.json", env: { "REMOTE_ADDR" => CORE_POLL_IP }
      assert_not_equal 429, response.status, "the status poll must not spend the platform-wide budget"
    end

    # ...and the counter really was full, so the exemption above is the reason
    # those polls got through, not an empty budget.
    get PHONE_VERIFICATION_PATH, env: { "REMOTE_ADDR" => CORE_POLL_IP }
    assert_equal 429, response.status, "any non-poll request past the ceiling must be throttled"
  end

  test "the status poll keeps a per-IP ceiling of its own despite the platform-wide exemption" do
    # The poll is exempt from "requests by ip" so a cafe NAT is not eaten by it
    # — but an exemption with nothing behind it is an amplifier: a client that
    # simply carries no session would then have no IP bound at all. 600/minute
    # is fifty citizens polling from one address at the page's own five-second
    # cadence, so it cannot bite a real room.
    name = "bih/phone-verification-status/ip"
    throttle = throttle_for(name)

    assert_equal 600, throttle.limit
    assert_equal 60, throttle.period.to_i

    # 600 real polls would be a slow way to prove a counter; seed it through
    # Rack::Attack's own cache API, exactly as Throttle#matched_by? does.
    fill_counter(name, STATUS_CEILING_IP, to: throttle.limit - 1)

    get "#{PHONE_VERIFICATION_PATH}/status.json", env: { "REMOTE_ADDR" => STATUS_CEILING_IP }
    assert_not_equal 429, response.status, "the poll that reaches the ceiling must still be served"

    get "#{PHONE_VERIFICATION_PATH}/status.json", env: { "REMOTE_ADDR" => STATUS_CEILING_IP }
    assert_equal 429, response.status, "poll number 601 from one address must be throttled"
    assert_match(/too many requests/i, response.body)
  end

  test "a safelisted venue IP is not counted by the status poll's per-IP ceiling" do
    # Same rule as everywhere else: the poll ceiling is IP-keyed, so it goes
    # through MiRackAttack.ip_key and the venue address is relaxed here too.
    name = "bih/phone-verification-status/ip"

    with_safelisted_venue_ip do
      fill_counter(name, SAFELISTED_IP, to: throttle_for(name).limit + 1)

      get "#{PHONE_VERIFICATION_PATH}/status.json", env: { "REMOTE_ADDR" => SAFELISTED_IP }
      assert_not_equal 429, response.status, "a listed venue IP must poll past the ceiling"
    end
  end

  test "the extension-less and .json poll paths share one per-IP budget" do
    # Two spellings of one endpoint. Counting them separately would quietly
    # double the ceiling for anyone who alternates.
    name = "bih/phone-verification-status/ip"
    fill_counter(name, STATUS_SHARED_IP, to: throttle_for(name).limit - 1)

    get "#{PHONE_VERIFICATION_PATH}/status", env: { "REMOTE_ADDR" => STATUS_SHARED_IP }
    assert_not_equal 429, response.status

    get "#{PHONE_VERIFICATION_PATH}/status.json", env: { "REMOTE_ADDR" => STATUS_SHARED_IP }
    assert_equal 429, response.status, "the .json form must spend the same budget as the plain one"
  end

  test "a path that merely begins with the poll path is not exempt from the platform-wide ceiling" do
    # The exemption used to be a start_with? match, which meant naming any URL
    # with that prefix opted it out of the tightest rule on the platform.
    name = "requests by ip"
    fill_counter(name, STATUS_PREFIX_IP, to: throttle_for(name).limit)

    get "#{PHONE_VERIFICATION_PATH}/statusfoo", env: { "REMOTE_ADDR" => STATUS_PREFIX_IP }

    assert_equal 429, response.status, "only the exact poll path may skip the platform-wide ceiling"
  end

  test "POST /sms/authorizations is throttled per session, not per IP" do
    name = "bih/sms-authorization-create/session"
    first = browser_at(SMS_SESSION_IP)

    # A different number each time, so the tighter per-phone rule (3) cannot be
    # what trips here — this test is about the per-session ceiling alone.
    statuses = (throttle_for(name).limit + 1).times.map do |index|
      send_sms_authorization(first, "+3876512300#{index}", SMS_SESSION_IP)
      first.response.status
    end

    assert_equal 429, statuses.last, "expected the send past the session ceiling to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, first.response.body)

    # Reading the form is free; only sending a (paid) message is metered.
    first.get "/sms/authorizations/new", env: { "REMOTE_ADDR" => SMS_SESSION_IP }
    assert_not_equal 429, first.response.status, "GET /sms/authorizations/new must not be counted as a send"

    # The venue case: a second citizen behind the same NAT is a second browser
    # with its own session, and must be untouched by the first one's ceiling.
    second = browser_at(SMS_SESSION_IP)
    send_sms_authorization(second, "+38765124000", SMS_SESSION_IP)

    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"
  end

  test "POST /sms/authorizations is throttled per phone number" do
    name = "bih/sms-authorization-create/phone"
    limit = throttle_for(name).limit
    # The same number written four ways. The discriminator strips everything but
    # digits and "+" (the same normalisation as bih/phone-login/phone) before
    # digesting, so spacing tricks must not buy another message.
    spellings = ["+38765123456", "+387 65 123 456", "+387-65-123-456", "+387 65 123-456"]
    assert_equal limit + 1, spellings.size

    statuses = spellings.map do |spelling|
      post "/sms/authorizations",
           params: { mobile_phone: { mobile_phone_number: spelling } },
           env: { "REMOTE_ADDR" => SMS_PHONE_IP }
      response.status
    end

    assert_equal 429, statuses.last, "expected the fourth send to one number to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, response.body)

    post "/sms/authorizations",
         params: { mobile_phone: { mobile_phone_number: "+38766999888" } },
         env: { "REMOTE_ADDR" => SMS_PHONE_IP }

    assert_not_equal 429, response.status, "a different number must not inherit the throttled one's counter"
  end

  test "the per-phone limit follows the nested param, which is the number that gets the SMS" do
    name = "bih/sms-authorization-create/phone"
    limit = throttle_for(name).limit
    victim = "+38765700700"

    # Decidim::AttributeObject::Form.from_params merges the nested
    # mobile_phone[mobile_phone_number] OVER the flat mobile_phone_number, so
    # when a request carries both it is the NESTED value that is texted. Each
    # request here pairs a throwaway flat number with the same victim in the
    # nested key: a discriminator reading the flat key first would see four
    # different numbers and never throttle, billing the victim indefinitely.
    statuses = (limit + 1).times.map do |index|
      post "/sms/authorizations",
           params: {
             mobile_phone_number: "+3876590000#{index}",
             mobile_phone: { mobile_phone_number: victim }
           },
           env: { "REMOTE_ADDR" => SMS_PRECEDENCE_IP }
      response.status
    end

    assert_equal 429, statuses.last, "the nested number's budget must be the one that is spent"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
  end

  test "a scalar mobile_phone param does not break the send throttle" do
    # The discriminator runs inside the middleware, ahead of every controller
    # and rescue: if reading a crafted "mobile_phone=x" raised there, an
    # attacker would get a 500 out of the very endpoint this rule protects.
    # Unauthenticated, the request redirects to sign-in, exactly as it would
    # without the crafted param.
    post "/sms/authorizations",
         params: { mobile_phone: "x" },
         env: { "REMOTE_ADDR" => SMS_SCALAR_IP }

    assert_response :redirect
  end

  test "POST /biceriseno/verifikacija/telefon/kod is throttled per session" do
    name = "bih/phone-verification-code/session"
    path = "#{PHONE_VERIFICATION_PATH}/kod"

    # Throttling runs in middleware ahead of the controller, so the limiter
    # trips regardless of whether the visitor is signed in or has a pending
    # authorization. The typed code also has a per-authorization Redis budget
    # (PhoneVerification::AttemptLimiter) — that, not this, is the real control.
    first = browser_at(CODE_IP)
    statuses = drive_to_ceiling(name, :post, path, first, CODE_IP)

    assert_equal 429, statuses.last, "expected the code attempt past the ceiling to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, first.response.body)

    second = browser_at(CODE_IP)
    second.post path, env: { "REMOTE_ADDR" => CODE_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"

    # Resending is a separate (and much tighter) budget, not a shared one.
    first.post "#{PHONE_VERIFICATION_PATH}/ponovo", env: { "REMOTE_ADDR" => CODE_IP }
    assert_not_equal 429, first.response.status, "the resend path must not share the code-attempt budget"
  end

  test "POST /biceriseno/verifikacija/telefon/ponovo is throttled per session" do
    name = "bih/phone-verification-resend/session"
    path = "#{PHONE_VERIFICATION_PATH}/ponovo"

    # A resend spends a paid Infobip message, so this is the tighter budget.
    first = browser_at(RESEND_IP)
    statuses = drive_to_ceiling(name, :post, path, first, RESEND_IP)

    assert_equal 429, statuses.last, "expected the resend past the ceiling to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, first.response.body)

    second = browser_at(RESEND_IP)
    second.post path, env: { "REMOTE_ADDR" => RESEND_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"

    first.post "#{PHONE_VERIFICATION_PATH}/kod", env: { "REMOTE_ADDR" => RESEND_IP }
    assert_not_equal 429, first.response.status, "the code path must not share the resend budget"
  end

  test "DELETE /biceriseno/verifikacija/telefon is throttled per session" do
    name = "bih/phone-verification-change/session"
    first = browser_at(CHANGE_IP)
    statuses = drive_to_ceiling(name, :delete, PHONE_VERIFICATION_PATH, first, CHANGE_IP)

    assert_equal 429, statuses.last, "expected the number change past the ceiling to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, first.response.body)

    second = browser_at(CHANGE_IP)
    second.delete PHONE_VERIFICATION_PATH, env: { "REMOTE_ADDR" => CHANGE_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"

    # Same path, different method: reading the page must not be metered as a
    # number change.
    first.get PHONE_VERIFICATION_PATH, env: { "REMOTE_ADDR" => CHANGE_IP }
    assert_not_equal 429, first.response.status, "GET on the same path must not be counted as a change"
  end

  test "GET /biceriseno/verifikacija/telefon/status is throttled per session" do
    name = "bih/phone-verification-status/session"
    limit = throttle_for(name).limit
    # The page polls every three seconds while the citizen taps the link on
    # their phone, so this ceiling is generous — but it is a ceiling, and the
    # .json and extension-less forms share it rather than doubling it.
    forms = ["#{PHONE_VERIFICATION_PATH}/status.json", "#{PHONE_VERIFICATION_PATH}/status"].cycle
    first = browser_at(STATUS_IP)
    statuses = (limit + 1).times.map do
      first.get forms.next, env: { "REMOTE_ADDR" => STATUS_IP }
      first.response.status
    end

    assert_equal 429, statuses.last, "expected the poll past the ceiling to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, first.response.body)

    second = browser_at(STATUS_IP)
    second.get "#{PHONE_VERIFICATION_PATH}/status.json", env: { "REMOTE_ADDR" => STATUS_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"

    # The page itself is not the poll endpoint and keeps its own (unmetered) path.
    first.get PHONE_VERIFICATION_PATH, env: { "REMOTE_ADDR" => STATUS_IP }
    assert_not_equal 429, first.response.status, "the verification page must not be counted as a poll"
  end

  test "one browser's per-session ceiling survives the session cookie rotating under it" do
    # The regression test for the discriminator itself. With CookieStore the
    # session COOKIE is AES-GCM ciphertext, rewritten on every response that
    # touches the session — a flash is enough — while the session ID behind it
    # stays put. Keying on the cookie therefore filed each request under its own
    # counter and no per-session throttle could ever fire; keying on the id
    # counts one browser as one browser.
    #
    # Nothing is pinned here: Devise signs the user in, the app sets its own
    # cookies, and ActionDispatch's jar carries them, exactly as a browser would.
    name = "bih/phone-verification-code/session"
    path = "#{PHONE_VERIFICATION_PATH}/kod"
    user = FactoryBot.create(:user, :confirmed, organization: @organization)
    # A pending (not granted) authorization is what makes #confirm run and set
    # its "code expired" flash — which is what rotates the cookie.
    Decidim::Authorization.create!(
      user:, name: "sms", unique_id: "rack-attack-session-flow", verification_metadata: {}
    )
    sign_in user

    # The sign-in lands on the next request; this one establishes the session
    # and receives its cookie, and is not counted under the session key because
    # it arrives without one.
    get PHONE_VERIFICATION_PATH, env: { "REMOTE_ADDR" => SESSION_FLOW_IP }

    session_key = Rails.application.config.session_options.fetch(:key)
    observed_cookies = []
    statuses = (throttle_for(name).limit + 1).times.map do
      post path, params: { verification_code: "000000" }, env: { "REMOTE_ADDR" => SESSION_FLOW_IP }
      observed_cookies << cookies[session_key]
      response.status
    end

    # Guard the guard: if the cookie ever stopped rotating, this test would pass
    # against the broken discriminator too and quietly stop being a regression
    # test at all.
    assert_operator observed_cookies.uniq.size, :>, 1,
                    "the session cookie must rotate during the run, or this proves nothing"
    assert_equal 429, statuses.last, "one browser must hit the ceiling even as its cookie rotates"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
  end

  # ------------------------------------------------- delivery D: /registracija

  test "POST /registracija spends the same sign-up ceiling as POST /users" do
    # Two doors into the same room. A flood through either buys nothing without
    # a verified phone behind each account, so they share one budget rather
    # than handing an attacker a second ceiling by changing the URL.
    name = "bih/registration-create/ip"

    fill_counter(name, ONE_STEP_CREATE_IP, to: throttle_for(name).limit - 1)

    post REGISTRATION_PATH, params: { user: { name: "Bot" } }, env: { "REMOTE_ADDR" => ONE_STEP_CREATE_IP }
    assert_not_equal 429, response.status, "the request that reaches the ceiling must still be served"

    # Decidim's own path, past the shared ceiling.
    post "/users", params: { user: sign_up_params(1) }, env: { "REMOTE_ADDR" => ONE_STEP_CREATE_IP }
    assert_equal 429, response.status, "the two sign-up doors must not each get their own ceiling"

    # ...and so is the engine-mounted form, which goes on answering after this
    # delivery. A third door with a budget of its own would make the other two
    # ceilings decorative.
    post MOUNTED_REGISTRATION_PATH, params: { user: { name: "Bot" } }, env: { "REMOTE_ADDR" => ONE_STEP_CREATE_IP }
    assert_equal 429, response.status, "the engine-mounted form must spend the same sign-up ceiling"
  end

  test "POST /registracija/potvrda/kod shares the code budget with the verification page" do
    name = "bih/phone-verification-code/session"
    first = browser_at(ONE_STEP_CODE_IP)
    statuses = drive_to_ceiling(name, :post, "#{PENDING_PATH}/kod", first, ONE_STEP_CODE_IP)

    assert_equal 429, statuses.last, "expected the code attempt past the ceiling to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"

    # Same budget, three spellings of the same page: the signed-in verification
    # page, the root registration path and the engine-mounted one.
    first.post "#{PHONE_VERIFICATION_PATH}/kod", env: { "REMOTE_ADDR" => ONE_STEP_CODE_IP }
    assert_equal 429, first.response.status, "delivery A's path must share this session's spent budget"

    first.post "#{MOUNTED_PENDING_PATH}/kod", env: { "REMOTE_ADDR" => ONE_STEP_CODE_IP }
    assert_equal 429, first.response.status, "the engine-mounted path must share this session's spent budget"

    second = browser_at(ONE_STEP_CODE_IP)
    second.post "#{PENDING_PATH}/kod", env: { "REMOTE_ADDR" => ONE_STEP_CODE_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"
  end

  test "POST /registracija/potvrda/ponovo shares the resend budget with the verification page" do
    name = "bih/phone-verification-resend/session"
    first = browser_at(ONE_STEP_RESEND_IP)
    statuses = drive_to_ceiling(name, :post, "#{PENDING_PATH}/ponovo", first, ONE_STEP_RESEND_IP)

    assert_equal 429, statuses.last, "expected the resend past the ceiling to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"

    first.post "#{MOUNTED_PENDING_PATH}/ponovo", env: { "REMOTE_ADDR" => ONE_STEP_RESEND_IP }
    assert_equal 429, first.response.status, "the engine-mounted path must share this session's spent budget"

    # The code path keeps its own (looser) budget.
    first.post "#{PENDING_PATH}/kod", env: { "REMOTE_ADDR" => ONE_STEP_RESEND_IP }
    assert_not_equal 429, first.response.status, "the code path must not share the resend budget"

    second = browser_at(ONE_STEP_RESEND_IP)
    second.post "#{PENDING_PATH}/ponovo", env: { "REMOTE_ADDR" => ONE_STEP_RESEND_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"
  end

  test "changing the number and starting over spend ONE budget across both verbs" do
    # "Start over" throws the whole pending registration away — the heavier
    # version of the same "this number is wrong" move. Two budgets would just
    # be a way to walk around whichever one bit first.
    name = "bih/phone-verification-change/session"
    limit = throttle_for(name).limit
    first = browser_at(ONE_STEP_CHANGE_IP)

    # Alternate the two verbs and the two paths so nothing here can pass by
    # counting only one of them.
    moves = [
      [:delete, PENDING_PATH],
      [:post, "#{PENDING_PATH}/pocni-ispocetka"],
      [:delete, MOUNTED_PENDING_PATH],
      [:post, "#{MOUNTED_PENDING_PATH}/pocni-ispocetka"]
    ].cycle

    statuses = (limit + 1).times.map do
      method, path = moves.next
      first.public_send(method, path, env: { "REMOTE_ADDR" => ONE_STEP_CHANGE_IP })
      first.response.status
    end

    assert_equal 429, statuses.last, "expected the #{limit + 1}th change/start-over to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"

    # Reading the pending page is not a change.
    second = browser_at(ONE_STEP_CHANGE_IP)
    second.get PENDING_PATH, env: { "REMOTE_ADDR" => ONE_STEP_CHANGE_IP }
    assert_not_equal 429, second.response.status, "GET on the pending page must not be counted as a change"

    second.delete PENDING_PATH, env: { "REMOTE_ADDR" => ONE_STEP_CHANGE_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"
  end

  test "POST /registracija/potvrda/status is throttled per session like delivery A's poll" do
    name = "bih/phone-verification-status/session"
    limit = throttle_for(name).limit
    # Two spellings of one endpoint; they share the budget instead of doubling it.
    forms = ["#{PENDING_PATH}/status", "#{PENDING_PATH}/status.json"].cycle
    first = browser_at(ONE_STEP_STATUS_IP)

    statuses = (limit + 1).times.map do
      first.post forms.next, env: { "REMOTE_ADDR" => ONE_STEP_STATUS_IP }
      first.response.status
    end

    assert_equal 429, statuses.last, "expected poll number #{limit + 1} to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"

    first.post "#{MOUNTED_PENDING_PATH}/status.json", env: { "REMOTE_ADDR" => ONE_STEP_STATUS_IP }
    assert_equal 429, first.response.status, "the engine-mounted poll must share this session's spent budget"

    second = browser_at(ONE_STEP_STATUS_IP)
    second.post "#{PENDING_PATH}/status.json", env: { "REMOTE_ADDR" => ONE_STEP_STATUS_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"
  end

  test "the registration poll is exempt from the platform-wide ceiling only as a POST" do
    # Same reasoning as delivery A's GET poll: the pending page asks every few
    # seconds, and counting that against 100/minute would let a handful of
    # citizens on one NAT exhaust the whole room's budget. The exemption is for
    # the endpoint the page actually calls — a GET on that path is not it.
    name = "requests by ip"
    fill_counter(name, ONE_STEP_STATUS_CORE_IP, to: throttle_for(name).limit)

    3.times do
      post "#{PENDING_PATH}/status.json", env: { "REMOTE_ADDR" => ONE_STEP_STATUS_CORE_IP }
      assert_not_equal 429, response.status, "the registration poll must not spend the platform-wide budget"
    end

    get "#{PENDING_PATH}/status", env: { "REMOTE_ADDR" => ONE_STEP_STATUS_CORE_IP }
    assert_equal 429, response.status, "a GET is not the poll and must not inherit its exemption"
  end

  test "the registration poll keeps the same per-IP ceiling as delivery A's" do
    # An exemption with nothing behind it is an amplifier: a client carrying no
    # session would otherwise have no IP bound at all on this path.
    name = "bih/phone-verification-status/ip"
    throttle = throttle_for(name)

    fill_counter(name, ONE_STEP_STATUS_IP_CEILING_IP, to: throttle.limit - 1)

    post "#{PENDING_PATH}/status.json", env: { "REMOTE_ADDR" => ONE_STEP_STATUS_IP_CEILING_IP }
    assert_not_equal 429, response.status, "the poll that reaches the ceiling must still be served"

    post "#{PENDING_PATH}/status.json", env: { "REMOTE_ADDR" => ONE_STEP_STATUS_IP_CEILING_IP }
    assert_equal 429, response.status, "poll number #{throttle.limit + 1} from one address must be throttled"
  end

  test "POST /biceriseno/potvrdi-email is throttled per session" do
    # Every request spends a real e-mail to an address the platform has NOT
    # proven, so this endpoint is a way to point our own outbound mail at a
    # stranger's inbox. Per session, not per IP: the venue shares one NAT.
    name = "bih/email-confirmation-request/session"
    first = browser_at(EMAIL_CONFIRMATION_IP)
    statuses = drive_to_ceiling(name, :post, EMAIL_CONFIRMATION_PATH, first, EMAIL_CONFIRMATION_IP)

    assert_equal 429, statuses.last, "expected the request past the ceiling to be throttled"
    assert_equal 1, statuses.count(429), "expected exactly the over-limit request to be throttled"
    assert_match(/too many requests/i, first.response.body)

    second = browser_at(EMAIL_CONFIRMATION_IP)
    second.post EMAIL_CONFIRMATION_PATH, env: { "REMOTE_ADDR" => EMAIL_CONFIRMATION_IP }
    assert_not_equal 429, second.response.status, "a second session on the same IP must not inherit the ceiling"
  end

  test "the venue list relaxes the one-step sign-up ceiling and NONE of the four session budgets" do
    with_safelisted_venue_ip do
      # IP-keyed: relaxed for the listed address, still enforced for anyone else.
      assert_ip_rule_relaxed_for_venue("bih/registration-create/ip") do |ip, index|
        post REGISTRATION_PATH, params: { user: { name: "Bot #{index}" } }, env: { "REMOTE_ADDR" => ip }
      end

      # ...and every session-keyed budget on the pending page still counts a
      # listed address exactly as it counts anyone else. This is the whole
      # reason the venue list is a DISCRIMINATOR and not a Rack::Attack
      # safelist: a safelist short-circuits ahead of every rule, so listing the
      # venue on 17.9. would switch off the paid-message budgets for the entire
      # room — the one abuse a crowded hall makes easy, not the one it excuses.
      #
      # All four, not a representative one: each is a separate `if` in the
      # initializer, and any one of them could pick up MiRackAttack.ip_key by a
      # copy-paste without the other three noticing.
      venue = browser_at(SAFELISTED_IP)

      [
        ["bih/phone-verification-code/session", :post, "#{PENDING_PATH}/kod"],
        ["bih/phone-verification-resend/session", :post, "#{PENDING_PATH}/ponovo"],
        ["bih/phone-verification-change/session", :delete, PENDING_PATH],
        ["bih/phone-verification-status/session", :post, "#{PENDING_PATH}/status"]
      ].each do |name, method, path|
        statuses = drive_to_ceiling(name, method, path, venue, SAFELISTED_IP)

        assert_equal 429, statuses.last, "#{name} must still bite for a safelisted IP"
        assert_equal 1, statuses.count(429), "#{name}: expected exactly the over-limit request to be throttled"
      end
    end
  end

  private

  # A fresh browser: its own cookie jar, no pinned headers. The warm-up request
  # is a failed sign-in, chosen because it deterministically writes a flash and
  # therefore makes the app issue a real session cookie — without one the
  # discriminator falls back to the IP and every per-session assertion silently
  # becomes a per-IP one.
  def browser_at(ip)
    session = open_session
    session.host! @organization.host
    session.post "/users/sign_in",
                 params: { user: { email: "nobody-#{SecureRandom.hex(3)}@example.org", password: "wrong" } },
                 env: { "REMOTE_ADDR" => ip }

    session_key = Rails.application.config.session_options.fetch(:key)
    assert session.cookies[session_key].present?,
           "the warm-up must leave a real session cookie, otherwise this is a per-IP test in disguise"

    session
  end

  def send_sms_authorization(session, number, ip)
    session.post "/sms/authorizations",
                 params: { mobile_phone: { mobile_phone_number: number } },
                 env: { "REMOTE_ADDR" => ip }
  end

  def with_safelisted_venue_ip(&)
    MiRackAttackSafelist.stub(:entries, [IPAddr.new("#{SAFELISTED_IP}/32")], &)
  end

  # Hide the constant the way an engine skew does — it is simply not there —
  # rather than stubbing a predicate, so an unguarded reference anywhere on the
  # request path shows up here as the 500 it would be in production.
  def without_engine_throttling
    # Reference it first: Zeitwerk registers the constant as an AUTOLOAD until
    # something touches it, and remove_const on an unresolved autoload drops the
    # autoload and returns nil — which would leave the constant gone for the
    # rest of this worker process and fail whichever test runs next. Loading it
    # first makes the removal (and the restore) real.
    hidden = Decidim::Bih::Throttling
    Decidim::Bih.send(:remove_const, :Throttling)
    yield
  ensure
    Decidim::Bih.const_set(:Throttling, hidden) if hidden
  end

  # Seed both addresses past the ceiling, then send one real request from each:
  # the listed one must be served (its discriminator is nil, so the rule never
  # counted it in the first place), the unlisted one must be throttled.
  def assert_ip_rule_relaxed_for_venue(name)
    over = throttle_for(name).limit + 1

    fill_counter(name, SAFELISTED_IP, to: over)
    yield(SAFELISTED_IP, 3)
    assert_not_equal 429, response.status, "#{name}: a listed venue IP must be served past the ceiling"

    fill_counter(name, UNLISTED_IP, to: over)
    yield(UNLISTED_IP, 4)
    assert_equal 429, response.status, "#{name}: an unlisted IP past the ceiling must still be throttled"
  end

  def throttle_for(name)
    Rack::Attack.throttles.fetch(name)
  end

  # Exactly the call Rack::Attack::Throttle#matched_by? makes, so seeding it
  # here is indistinguishable from having made that many requests.
  def fill_counter(name, discriminator, to:)
    period = throttle_for(name).period
    to.times { Rack::Attack.cache.count("#{name}:#{discriminator}", period) }
  end

  def drive_to_ceiling(name, method, path, session, ip)
    (throttle_for(name).limit + 1).times.map do
      session.public_send(method, path, env: { "REMOTE_ADDR" => ip })
      session.response.status
    end
  end

  def sign_up_params(index)
    {
      name: "Bot #{index}",
      email: "rack-attack-signup-#{index}-#{SecureRandom.hex(3)}@example.org",
      password: "Stronger-password-2026",
      tos_agreement: "1"
    }
  end
end
