# frozen_string_literal: true

require "test_helper"

# Unit coverage for the two helper modules defined in
# config/initializers/rack_attack.rb. The rules themselves are exercised end to
# end in test/integration/rack_attack_test.rb and
# test/integration/rack_attack_phone_verification_test.rb; what is proved here
# is the parsing and the two failure modes that would otherwise only show up in
# production — an unreadable request body and a missing engine constant.
class MiRackAttackTest < ActiveSupport::TestCase
  test "the venue safelist parses exact IPv4, CIDR and IPv6 entries" do
    entries = MiRackAttackSafelist.parse(" 203.0.113.7 ,198.51.100.0/24, 2001:db8::1 ")

    assert_equal ["203.0.113.7/32", "198.51.100.0/24", "2001:db8::1/128"], (entries.map { |entry| "#{entry}/#{entry.prefix}" })
    assert entries.frozen?, "the parsed list is read on every request and must not be mutable"
  end

  test "the venue safelist ignores blanks and an empty value" do
    assert_empty MiRackAttackSafelist.parse("")
    assert_empty MiRackAttackSafelist.parse(nil)
    assert_equal 1, MiRackAttackSafelist.parse(",, 203.0.113.7 ,,").size
  end

  test "a malformed venue safelist entry is warned about and skipped, never fatal" do
    # A typo in .env must not cost the site the boot. The operator sets this
    # variable by hand, under time pressure, on the evening of the launch.
    entries = nil
    log = capture_rails_log { entries = MiRackAttackSafelist.parse("203.0.113.7,not-an-ip,198.51.100.0/24") }

    assert_equal ["203.0.113.7/32", "198.51.100.0/24"], (entries.map { |entry| "#{entry}/#{entry.prefix}" })
    assert_match(/MI_RACK_ATTACK_SAFELIST_IPS entry "not-an-ip" is not an IP or CIDR/, log)
  end

  test "match? answers for exact addresses and CIDR ranges and never raises on junk" do
    MiRackAttackSafelist.stub(:entries, MiRackAttackSafelist.parse("203.0.113.7,198.51.100.0/24,2001:db8::/32")) do
      assert MiRackAttackSafelist.match?("203.0.113.7")
      assert MiRackAttackSafelist.match?("198.51.100.42")
      assert MiRackAttackSafelist.match?("2001:db8::dead")

      assert_not MiRackAttackSafelist.match?("203.0.113.8")
      assert_not MiRackAttackSafelist.match?("not-an-ip")
      assert_not MiRackAttackSafelist.match?(nil)

      # Documented caveat, mirrored in docs/RELEASE_CHECKLIST.md step 6: IPAddr
      # compares within one family, so a client that arrives as an IPv4-mapped
      # IPv6 address does NOT match an IPv4 CIDR. List the address in the form
      # the app actually sees.
      assert_not MiRackAttackSafelist.match?("::ffff:198.51.100.42")
    end
  end

  test "params returns an empty hash when the request body cannot be parsed" do
    # A truncated multipart body makes Rack raise while parsing — and it would
    # raise INSIDE the Rack::Attack middleware, i.e. an attacker-triggered error
    # on the very endpoint the phone rules exist to protect.
    request = truncated_multipart_request

    assert_raises(StandardError) { request.params }

    result = nil
    log = capture_rails_log { result = MiRackAttack.params(request) }

    assert_equal({}, result)
    # Warned, so a real one is visible in the log rather than silently swallowed
    # — but the CLASS NAME only. A body parser's message can quote the body it
    # choked on, and the body here is a phone number.
    assert_match(/\[rack-attack\] request params unreadable: \w+/, log)
    assert_not_includes log, "mobile_phone_number"
  end

  test "params reads a well-formed body normally" do
    request = ActionDispatch::Request.new(
      Rack::MockRequest.env_for(
        "/sms/authorizations",
        method: "POST",
        params: { "mobile_phone" => { "mobile_phone_number" => "+38765123456" } }
      )
    )

    assert_equal "+38765123456", MiRackAttack.params(request).dig("mobile_phone", "mobile_phone_number")
  end

  test "phone_key delegates to the engine's salted helper when it is loaded" do
    assert_equal Decidim::Bih::Throttling.phone_key("+38765123456"), MiRackAttack.phone_key(" +387 65/123-456 ")
    assert_not_includes MiRackAttack.phone_key("+38765123456").to_s, "38765123456"
    assert_nil MiRackAttack.phone_key("")
  end

  test "a top-level ::Throttling does not satisfy the engine guard" do
    # Module#const_defined? searches Object as well unless inherit is false, so
    # without that flag any gem that happens to define a top-level ::Throttling
    # would answer true here — and send phone_key straight to
    # Decidim::Bih::Throttling, the constant we just established is missing.
    without_engine_throttling do
      Object.const_set(:Throttling, Module.new)

      begin
        assert_equal "+38765123456", MiRackAttack.phone_key("+387 65 123 456")
      ensure
        Object.send(:remove_const, :Throttling)
      end
    end
  end

  test "status_poll? matches the exact poll path and its .json form, nothing else" do
    # start_with? used to be enough here, which meant any URL beginning with the
    # poll path was exempt from the platform-wide per-IP ceiling. An exemption
    # has to be exact.
    assert MiRackAttack.status_poll?(poll_request("/biceriseno/verifikacija/telefon/status"))
    assert MiRackAttack.status_poll?(poll_request("/biceriseno/verifikacija/telefon/status.json"))

    assert_not MiRackAttack.status_poll?(poll_request("/biceriseno/verifikacija/telefon/statusfoo"))
    assert_not MiRackAttack.status_poll?(poll_request("/biceriseno/verifikacija/telefon/status/kod"))
    assert_not MiRackAttack.status_poll?(poll_request("/biceriseno/verifikacija/telefon/status.xml"))
    assert_not MiRackAttack.status_poll?(poll_request("/biceriseno/verifikacija/telefon"))
    assert_not MiRackAttack.status_poll?(poll_request("/biceriseno/verifikacija/telefon/status", method: "POST"))
  end

  test "the one-step registration poll counts as a POST at both bases, and only as a POST" do
    # Isporuka D: the pending page's poll can sign the waiting browser in, so it
    # is a POST (R-D4) — the opposite verb from delivery A's page, on the same
    # budget. The base is a host switch, and both the root path and the engine
    # mount answer, so both are listed.
    %w(/registracija/potvrda /biceriseno/registracija/potvrda).each do |base|
      assert MiRackAttack.status_poll?(poll_request("#{base}/status", method: "POST")), base
      assert MiRackAttack.status_poll?(poll_request("#{base}/status.json", method: "POST")), base

      # A GET here is not the poll and must not inherit its exemption from the
      # platform-wide per-IP ceiling.
      assert_not MiRackAttack.status_poll?(poll_request("#{base}/status")), base
      # Same exactness rule as above: never a prefix match.
      assert_not MiRackAttack.status_poll?(poll_request("#{base}/statusfoo", method: "POST")), base
      assert_not MiRackAttack.status_poll?(poll_request("#{base}/status/kod", method: "POST")), base
      assert_not MiRackAttack.status_poll?(poll_request(base, method: "POST")), base
    end

    # The paths really were derived from the configured base, rather than typed
    # a second time next to it — and this host has the two in agreement, which
    # is the state the release is supposed to ship in.
    assert_equal Decidim::Bih.registration_path_for, MiRackAttack::REGISTRATION_BASE_PATH
    assert_equal MiRackAttack::HOST_REGISTRATION_BASE_PATH, MiRackAttack::REGISTRATION_BASE_PATH,
                 "config/routes.rb and Decidim::Bih.registration_base_path must name the same root path"
    assert_includes MiRackAttack::REGISTRATION_PENDING_PATHS, "#{Decidim::Bih.registration_path_for}/potvrda"
    assert_includes MiRackAttack::REGISTRATION_PENDING_PATHS, Decidim::Bih.public_path("registracija/potvrda")
    # Two bases, not three: the host root path and the engine mount.
    assert_equal 2, MiRackAttack::REGISTRATION_PENDING_PATHS.size
  end

  test "phone_key falls back to the normalised number when the engine constant is missing" do
    # Host and engine are separate repositories and production loads the engine
    # from a working tree, so a host boot can briefly see an engine without
    # Decidim::Bih::Throttling. Unguarded that is a 500 in the middleware, not a
    # skipped throttle — the rule has to keep counting instead.
    without_engine_throttling do
      assert_equal "+38765123456", MiRackAttack.phone_key(" +387 65/123-456 ")
      assert_nil MiRackAttack.phone_key("")
      assert_nil MiRackAttack.phone_key(nil)
    end
  end

  private

  def poll_request(path, method: "GET")
    ActionDispatch::Request.new(Rack::MockRequest.env_for(path, method:))
  end

  def truncated_multipart_request
    boundary = "----MiRackAttackTest"
    body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"mobile_phone[mobile_phone_number]\"\r\n"

    ActionDispatch::Request.new(
      Rack::MockRequest.env_for(
        "/sms/authorizations",
        :method => "POST",
        "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
        :input => body
      )
    )
  end

  # Hide the constant the way an engine skew does — it is simply not there —
  # rather than stubbing a predicate, so the guard is proved against the real
  # failure and not against a mock of it.
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

  def capture_rails_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(io))
    yield
    io.string
  ensure
    Rails.logger = original
  end
end
