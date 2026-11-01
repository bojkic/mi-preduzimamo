# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class ManifestTest < ActionDispatch::IntegrationTest
      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "manifest exposes the MI mobile app contract" do
        get "/manifest.webmanifest"
        assert_response :success
        assert_includes response.body, '"short_name"'
        # application/manifest+json is not registered as JSON by Rails test helpers,
        # so response.parsed_body returns a string; parse manually.
        body = JSON.parse(response.body) # rubocop:disable Rails/ResponseParsedBody
        assert_equal "MI!", body["short_name"]
        assert_equal "/?app=1", body["start_url"]
        assert_equal "/", body["scope"]
        assert_equal "/?source=pwa", body["id"]
        assert_equal "standalone", body["display"]
        assert_includes body["display_override"], "standalone"
        assert_includes body["display_override"], "minimal-ui"
        assert_includes body["categories"], "community"
        assert_includes body["categories"], "government"

        maskable_icon = body["icons"].find { |icon| icon["purpose"].to_s.include?("maskable") }
        assert_not_nil maskable_icon, "expected manifest to include a maskable icon"
        assert_equal "/icon.png", maskable_icon["src"]
        assert_equal "512x512", maskable_icon["sizes"]

        shortcut_urls = body.fetch("shortcuts").map { |shortcut| shortcut.fetch("url") }
        assert_includes shortcut_urls, "/biceriseno/prijave/new?app=1"
        assert_includes shortcut_urls, "/biceriseno/mapa?app=1"
        assert_includes shortcut_urls, "/biceriseno/projekti?app=1"
        assert_includes shortcut_urls, "/biceriseno/zajednistvo?app=1"
      end

      test "public layout advertises installable app metadata" do
        get "/"

        assert_response :success
        assert_select "link[rel='manifest'][href='/manifest.webmanifest']"
        assert_select "meta[name='theme-color']"
        assert_select "meta[name='application-name'][content='MI!']"
        assert_select "meta[name='mobile-web-app-capable'][content='yes']"
        assert_select "meta[name='apple-mobile-web-app-capable'][content='yes']"
        assert_select "meta[name='apple-mobile-web-app-title'][content='MI!']"
        assert_select "link[rel='apple-touch-icon'][href='/icon.png']"
        install_script_selector = "script[src^='/mi/mi-install.js']" \
          "[data-install-text][data-ios-text][data-manual-text]" \
          "[data-webview-text][data-install-label][data-dismiss-label]"
        assert_select install_script_selector
      end

      test "offline fallback is localized and renderable" do
        get "/offline"

        assert_response :success
        assert_select "#offline-fallback-html"
        assert_includes response.body, I18n.t("decidim.offline.name", locale: :sr)
      end

      test "rails service worker compatibility endpoint delegates to the compiled worker" do
        get "/service-worker.js"

        assert_response :success
        assert_includes response.body, 'importScripts("/sw.js")'
      end

      test "host service worker source avoids caching private citizen pages" do
        source = Rails.root.join("app/packs/src/decidim/sw/sw.js").read

        assert_includes source, "/biceriseno/moj-doprinos"
        assert_includes source, "/biceriseno/komsiluk-board"
        assert_includes source, "/biceriseno/chat"
        assert_includes source, 'offlineFallback({ pageFallback: "/offline" })'
        # Navigations are handled per pathname (private + public) and never by a
        # blanket navigate route.
        assert_includes source, "isPublicNavigationPath(url.pathname)"
        assert_includes source, "isPrivateNavigationPath(url.pathname)"
        assert_not_includes source, '({ request }) => request.mode === "navigate"'
      end

      test "host service worker never serves navigations from a stale cache" do
        source = Rails.root.join("app/packs/src/decidim/sw/sw.js").read

        # The previous NetworkFirst/networkTimeoutSeconds strategy on a shared
        # navigation cache swapped in a stale or wrong page while online. Live
        # navigations must go to the network only; the /offline page stays the
        # genuine-offline fallback via the catch handler. Strip comments before
        # asserting so the explanatory note about the old strategy doesn't match.
        code = source.gsub(%r{^\s*//.*$}, "")
        assert_includes code, "new NetworkOnly()"
        assert_not_includes code, "NetworkFirst"
        assert_not_includes code, "networkTimeoutSeconds"
        assert_not_includes code, "mi-public-pages"
        assert_includes code, 'offlineFallback({ pageFallback: "/offline" })'
      end

      test "host service worker allowlists the podrzi gift page" do
        source = Rails.root.join("app/packs/src/decidim/sw/sw.js").read

        # The public allowlist pattern is escaped for a regex literal in the JS.
        assert_includes source, '/^\/biceriseno\/podrzi\/?$/'
      end

      test "host service worker classifies public project pages and private submission forms" do
        source = Rails.root.join("app/packs/src/decidim/sw/sw.js").read

        assert_includes source, '/^\/biceriseno\/projekti\/?$/'
        assert_includes source, '/^\/biceriseno\/projekti\/\d+\/?$/'
        assert_includes source, '"/biceriseno/projekti/novi"'
        assert_includes source, '"/biceriseno/projekti/prijave/"'
      end
    end
  end
end
