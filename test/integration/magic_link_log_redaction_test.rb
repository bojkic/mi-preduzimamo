# frozen_string_literal: true

require "test_helper"
# These paths render the Decidim layout, whose Decidim::UrlOptionResolver
# references Capybara.server_port in the test env (mirrors rack_attack_test.rb).
require "capybara"

# The magic-link token is the credential on this platform: a passwordless
# citizen signs in by opening /v/<token>. Rails::Rack::Logger writes the
# requested path into the application log on every request, so without
# config/initializers/mi_log_redaction.rb the log file is a list of usable
# sign-in links — for as long as it is retained, to everyone who can read it.
class MagicLinkLogRedactionTest < ActionDispatch::IntegrationTest
  # Same shape as production: SecureRandom.urlsafe_base64(24) is 32 characters.
  TOKEN = "AbCdEfGhIjKlMnOpQrStUvWxYz012345"

  setup do
    @organization = create_organization
    host! @organization.host
  end

  test "the raw token never reaches the request log on either magic-link route" do
    # The short host route and the engine's mounted route are the same
    # credential on two paths, and both must be covered.
    ["/v", "/biceriseno/v"].each do |prefix|
      [:get, :post].each do |verb|
        log = capture_request_log { public_send(verb, "#{prefix}/#{TOKEN}") }

        assert_not_includes log, TOKEN, "#{verb.upcase} #{prefix}/:token leaked the raw token into the log"
        assert_includes log, "#{prefix}/[FILTERED]", "#{verb.upcase} #{prefix}/:token must still log the path shape"
      end
    end
  end

  test "a token carried as a query parameter is filtered too" do
    log = capture_request_log { get "/biceriseno/prijava?pending_token=#{TOKEN}&token=#{TOKEN}" }

    assert_not_includes log, TOKEN
    assert_includes log, "[FILTERED]"
  end

  # Isporuka D. The one-step registration's pending page is resumed by a link
  # whose credential rides the QUERY STRING, and the "prove your address" link
  # carries its token as a PATH SEGMENT. Two different mechanisms cover them —
  # config/initializers/filter_parameter_logging.rb for the first (Rails'
  # request.filtered_path applies it to the "Started" line as well, not just to
  # "Parameters:"), and this initializer for the second, because filter_parameters
  # cannot reach a path. Both are pinned here so neither can be dropped quietly.
  test "the pending-registration resume token never reaches the request log" do
    ["/registracija/potvrda", "/biceriseno/registracija/potvrda"].each do |path|
      log = capture_request_log { get "#{path}?pending_token=#{TOKEN}" }

      assert_not_includes log, TOKEN, "#{path} leaked the pending token into the log"
      assert_includes log, "[FILTERED]", "#{path} must still log the path shape"
    end
  end

  test "the e-mail confirmation token never reaches the request log" do
    path = "/biceriseno/potvrdi-email/#{TOKEN}"
    log = capture_request_log { get path }

    assert_not_includes log, TOKEN, "the e-mail confirmation token leaked into the log"
    assert_includes log, "/biceriseno/potvrdi-email/[FILTERED]"
  end

  test "any other path is logged exactly as before" do
    log = capture_request_log { get "/biceriseno/prijave" }

    assert_includes log, 'Started GET "/biceriseno/prijave"'
    assert_not_includes log, "[FILTERED]"
  end

  test "redact_path leaves a path with no token segment untouched" do
    assert_equal "/biceriseno/prijave", MiMagicLinkLogRedaction.redact_path("/biceriseno/prijave")
    assert_equal "/verifikacija/telefon", MiMagicLinkLogRedaction.redact_path("/verifikacija/telefon")
    assert_equal "/v/[FILTERED]", MiMagicLinkLogRedaction.redact_path("/v/#{TOKEN}")
    assert_equal "/biceriseno/v/[FILTERED]", MiMagicLinkLogRedaction.redact_path("/biceriseno/v/#{TOKEN}")
    assert_equal "/biceriseno/potvrdi-email/[FILTERED]",
                 MiMagicLinkLogRedaction.redact_path("/biceriseno/potvrdi-email/#{TOKEN}")
    # The bare "ask for a message" POST carries no token and keeps its shape.
    assert_equal "/biceriseno/potvrdi-email", MiMagicLinkLogRedaction.redact_path("/biceriseno/potvrdi-email")
  end

  private

  # Rails::Rack::Logger reads Rails.logger on every request, so swapping it for
  # a StringIO-backed logger captures exactly the line under test.
  def capture_request_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(io).tap { |logger| logger.level = :info })
    yield
    io.string
  ensure
    Rails.logger = original
  end
end
