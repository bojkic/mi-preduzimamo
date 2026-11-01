# frozen_string_literal: true

require "test_helper"
require "support/route_smoke_helpers"

class SecurityHeadersTest < ActionDispatch::IntegrationTest
  include RouteSmokeHelpers

  PUBLIC_HTML_ROUTES = [
    "/",
    "/biceriseno/prijave/new",
    "/biceriseno/mapa"
  ].freeze

  setup do
    setup_smoke_organization!
    reset_smoke_concierge!
  end

  teardown { reset_smoke_concierge! }

  PUBLIC_HTML_ROUTES.each do |path|
    test "#{path} emits browser security headers" do
      get path

      assert_security_headers(path)
    end
  end

  test "admin pages emit browser security headers" do
    sign_in_smoke_admin!

    get "/admin/bih/goodwill"

    assert_security_headers("/admin/bih/goodwill")
  end

  private

  def assert_security_headers(path)
    assert_response :success, smoke_failure_message(path)

    permissions = response.headers["Permissions-Policy"].to_s
    assert_includes permissions, "geolocation=(self)"
    assert_includes permissions, "camera=()"
    assert_includes permissions, "microphone=()"
    assert_includes permissions, "payment=()"
    assert_includes permissions, "usb=()"
    assert_includes permissions, "unload=(self)"

    assert_equal "strict-origin-when-cross-origin", response.headers["Referrer-Policy"]
    assert_equal "same-origin-allow-popups", response.headers["Cross-Origin-Opener-Policy"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "noopen", response.headers["X-Download-Options"]
    assert_equal "none", response.headers["X-Permitted-Cross-Domain-Policies"]
    assert_equal "SAMEORIGIN", response.headers["X-Frame-Options"]

    csp = response.headers["Content-Security-Policy"].to_s
    assert_includes csp, "default-src 'self'"
    assert_includes csp, "script-src 'self'"
    assert_includes csp, "style-src"
    assert_includes csp, "font-src"
    assert_not_includes csp, "fonts.googleapis.com"
    assert_not_includes csp, "fonts.gstatic.com"
    assert_includes csp, "img-src"
    assert_includes csp, "*.tile.openstreetmap.org"

    directives = csp_directives(csp)
    assert_equal ["'self'"], directives.fetch("base-uri")
    assert_equal ["'self'"], directives.fetch("manifest-src")
    assert_equal ["'none'"], directives.fetch("object-src")
  end

  def csp_directives(header)
    header.split(";").each_with_object({}) do |directive, directives|
      name, *values = directive.strip.split
      directives[name] = values if name.present?
    end
  end
end
