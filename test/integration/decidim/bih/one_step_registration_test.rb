# frozen_string_literal: true

require "test_helper"
# The Decidim layout's UrlOptionResolver reads Capybara.server_port in the test
# environment, and a plain integration test does not load Capybara.
require "capybara"

module Decidim
  module Bih
    # Delivery D, host side: the engine's one-step registration is served at the
    # ROOT paths this app declares (`/registracija…`), and Decidim's own sign-up
    # routes redirect there so every poster, SMS and old bookmark keeps working.
    #
    # What can only break here is the host half: a route that was never
    # declared, an initializer that left `registration_base_path` unset (which
    # would have the engine build every in-flow URL under `/biceriseno`), or a
    # redirect that swallowed more of `/users` than sign-up.
    class OneStepRegistrationTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      REGISTRATION_PATH = "/registracija"
      PENDING_PATH = "/registracija/potvrda"

      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "localized registration doors retain the phone-first flow" do
        %w[sr sr-Cyrl bs hr].each do |locale|
          get "/#{locale}/users/sign_up"
          assert_response :found
          assert_redirected_to "/registracija?locale=#{locale}"
          post "/#{locale}/users"
          assert_response :found
          assert_redirected_to "/registracija?locale=#{locale}"
        end
      end

      test "compact registration only asks for name phone and terms and keeps sign in visible" do
        get REGISTRATION_PATH
        assert_response :success
        assert_select "#mi-registration-name[required]"
        assert_select "#mi-registration-phone[required]"
        assert_select "#mi-registration-tos[required]"
        assert_select "#mi-registration-email, #mi-registration-komsiluk, #mi-registration-newsletter", count: 0
        assert_select ".mi-registration-login a[href='/users/sign_in']"
      end

      test "the short invite link /p/<nadimak> is a 302 to the root registration form with the code" do
        get "/p/ana_poziva"

        assert_response :found
        assert_redirected_to "/registracija?ref=ana_poziva"

        get "/p/#{"a" * 61}"
        assert_redirected_to "/registracija"
      end

      test "the host builds shared invite links on the short path" do
        assert_equal "/p", Decidim::Bih.invite_short_path
        assert_equal "/p/ana_poziva", Decidim::Bih.invite_short_path_for("ana_poziva")
      end

      test "validation errors preserve unaccepted terms without restoring removed fields" do
        post REGISTRATION_PATH, params: { user: { name: "", newsletter: "0", tos_agreement: "0" } }

        assert_response :unprocessable_entity
        assert_select "#mi-registration-newsletter", count: 0
        assert_select "#mi-registration-newsletter[checked]", count: 0
        assert_select "#mi-registration-tos[checked]", count: 0
      end

      # ------------------------------------------------------------ the switch

      test "the host serves the one-step registration at the root path" do
        assert_equal REGISTRATION_PATH, Decidim::Bih.registration_path
        assert_equal PENDING_PATH, Decidim::Bih.registration_path_for("/potvrda")
        # Both settings, not one. registration_path is where every "register"
        # link points; registration_base_path is what the engine builds the
        # rest of the flow from. A host that set only the first would send
        # citizens to /registracija and then walk them under /biceriseno.
        assert_equal REGISTRATION_PATH, Decidim::Bih.registration_base_path
      end

      test "every root path of the flow reaches the engine's registrations controller" do
        expected = {
          [:get, REGISTRATION_PATH] => "new",
          [:post, REGISTRATION_PATH] => "create",
          [:get, PENDING_PATH] => "pending",
          [:post, "#{PENDING_PATH}/ponovo"] => "resend",
          [:post, "#{PENDING_PATH}/kod"] => "confirm",
          [:post, "#{PENDING_PATH}/status"] => "status",
          [:delete, PENDING_PATH] => "change",
          [:post, "#{PENDING_PATH}/pocni-ispocetka"] => "start_over"
        }

        expected.each do |(method, path), action|
          route = Rails.application.routes.recognize_path(path, method:)

          assert_equal "decidim/bih/registrations", route[:controller], "#{method.upcase} #{path}"
          assert_equal action, route[:action], "#{method.upcase} #{path}"
        end
      end

      test "the status poll is a POST and is not reachable as a GET" do
        # R-D4: this endpoint can sign the waiting browser in, so it must never
        # be something a prefetch, a crawler or an <img> can trigger.
        assert_raises(ActionController::RoutingError) do
          Rails.application.routes.recognize_path("#{PENDING_PATH}/status", method: :get)
        end
      end

      # ----------------------------------------------------------- the redirects

      test "the old Decidim sign-up routes redirect to the one-step form" do
        get "/users/sign_up"

        assert_response :found
        assert_redirected_to REGISTRATION_PATH

        post "/users", params: { user: { name: "X" } }

        assert_response :found
        assert_redirected_to REGISTRATION_PATH
      end

      test "the redirects are 302 so a rollback is not cached in every browser" do
        # A 301 outlives the deploy that made it: browsers cache it, and a
        # revert would leave citizens bouncing to a path that no longer exists.
        get "/users/sign_up"

        assert_equal 302, response.status

        post "/users", params: { user: { name: "X" } }

        assert_equal 302, response.status
      end

      test "only sign-up is redirected — the rest of /users is untouched" do
        # Decidim's devise_for exposes only new/create under /users (account
        # edit lives at /account, deletion at DELETE /account), so PUT /users
        # was a 404 before this delivery and must still be one: a redirect that
        # widened to the other verbs would be inventing a route Decidim never
        # had, and would shadow whatever Decidim puts there next.
        put "/users", params: { user: { name: "X" } }

        assert_response :not_found

        # Sign-in, password recovery and the account page are all still
        # themselves — none of them may be swallowed by the sign-up redirect.
        get "/users/sign_in"

        assert_response :success

        get "/users/password/new"

        assert_response :success

        get "/account"

        assert_response :redirect
        assert_not_equal REGISTRATION_PATH, redirect_path
      end

      test "every register link this app owns points at the one-step form" do
        get "/biceriseno/vodic"

        assert_response :success
        assert_select ".mi-guide-account a[href=?]", REGISTRATION_PATH
        assert_select ".mi-guide-account a[href='/users/sign_up']", count: 0
      end

      test "any stock sign-up link left in the layout lands on the one-step form" do
        # Decidim core's own layout may still render sign-up links from
        # decidim.new_user_registration_path (the off-canvas menu and the login
        # dialog do today). Whether it does is core's business and changes with
        # the Decidim version — so this asserts the property that matters
        # either way: NO such link may end in a 404 or on a form that no longer
        # opens an account. Zero of them is a fine outcome; a broken one is not.
        get "/"

        assert_response :success
        stale = css_select("a[href='/users/sign_up']")

        stale.each do
          get "/users/sign_up"
          follow_redirect!

          assert_response :success
          assert_select "form#mi-registration-form"
        end

        # And the redirect itself is proved unconditionally, so this test still
        # says something on the day core stops rendering those links.
        get "/users/sign_up"

        assert_redirected_to REGISTRATION_PATH
        follow_redirect!

        assert_response :success
        assert_select "form#mi-registration-form"
      end

      # ------------------------------------------------------------- the pages

      test "the registration form renders and stays indexable" do
        get REGISTRATION_PATH

        assert_response :success
        assert_select "form#mi-registration-form[action=?]", REGISTRATION_PATH
        # The front door is a page the platform WANTS found.
        assert_nil response.headers["X-Robots-Tag"]
      end

      test "the engine mount keeps serving the same form beside the root path" do
        # The root routes are an addition, not a replacement. This is asserted
        # as a real 200 with the form in it, because every throttle test that
        # touches the mounted path only proves it is METERED — and a 404 would
        # satisfy those just as well as the page does.
        get "/biceriseno/registracija"

        assert_response :success
        assert_select "form#mi-registration-form"
        # It posts to the base THIS host serves, so a citizen who arrives on the
        # mounted URL is not walked back under the mount by the form itself.
        assert_select "form#mi-registration-form[action=?]", REGISTRATION_PATH
      end

      test "the name and phone form has no password email or geography fields" do
        # This replaces the two-step Decidim sign-up page (whose own test this
        # file supersedes): every field the account needs is here, and there is
        # deliberately no password — the phone is the credential.
        get REGISTRATION_PATH

        assert_response :success
        assert_select "#mi-registration-name"
        assert_select "#mi-registration-email", count: 0
        assert_select "#mi-registration-phone"
        assert_select "#mi-registration-komsiluk", count: 0
        assert_select "#mi-registration-tos"
        assert_select "form#mi-registration-form input[type=password]", count: 0
        # A citizen who already has an account is sent to the passwordless
        # login rather than left looking for a password field.
        assert_select "a[href=?]", "/users/sign_in"
      end

      test "the pending page is noindex and never stored" do
        register!

        get PENDING_PATH

        assert_response :success
        assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
        assert_match(/no-store/, response.headers["Cache-Control"].to_s)
        assert_match(/private/, response.headers["Cache-Control"].to_s)
      end

      test "the pending page builds its own actions from the root base" do
        register!

        get PENDING_PATH

        assert_response :success
        # A citizen who arrived at the short path must not be walked under the
        # engine mount halfway through the flow. Every action the page can take
        # is checked, because each is built from registration_base_path
        # independently and any one of them could have been left behind.
        assert_select "[data-mi-phone-verification][data-status-url=?]", "#{PENDING_PATH}/status"
        assert_select "[data-mi-phone-verification][data-status-method=?]", "post"
        assert_select "form[action=?]", "#{PENDING_PATH}/kod"
        assert_select "form[action=?]", "#{PENDING_PATH}/ponovo"
        # This is the browser that did the registering, so it gets the hand-off
        # sentence rather than the start-over button (that one belongs to the
        # citizen holding only the mailed link). Its route is covered above.
        assert_select "[data-mi-handoff]"
        # The layout's own hreflang alternates are built by Decidim from the
        # engine-mounted route and are not the flow's actions, so this looks at
        # the forms only.
        assert_select "form[action^='/biceriseno/registracija']", count: 0
      end

      # -------------------------------------------------- the overlays and head

      test "Milica and the install prompt stay on both registration pages" do
        # _head_extra.html.erb suppresses the overlays on /users/* and on a
        # short list of form surfaces. /registracija is in neither, and that is
        # deliberate: this is the page a first-time citizen is most likely to
        # need help on. No change to the partial — this test is the proof.
        get REGISTRATION_PATH

        assert_response :success
        assert_includes response.body, "mi-chat-loader"
        assert_includes response.body, "mi-install.js"

        register!
        get PENDING_PATH

        assert_response :success
        assert_includes response.body, "mi-chat-loader"
        assert_includes response.body, "mi-install.js"
      end

      # -------------------------------------------------------- the social door

      test "MI_SOCIAL_REGISTRATION_ENABLED is the only thing still holding the social entry shut" do
        # Both halves, because only the pair says anything. Off proves the
        # entry is default-closed; ON proves it is closed by the FLAG and not
        # by something unbuilt — this delivery is what supplies the other three
        # gates (the canonical path, the root route, and a controller carrying
        # SocialRegistrationPrefill), so with the flag set it must open.
        previous = ENV.fetch("MI_SOCIAL_REGISTRATION_ENABLED", nil)

        ENV.delete("MI_SOCIAL_REGISTRATION_ENABLED")

        assert_equal REGISTRATION_PATH, Decidim::Bih.registration_path
        assert_not DecidimApp::Bijeljina::SocialRegistrationHandoff.available?,
                   "the social entry must be closed by default"

        ENV["MI_SOCIAL_REGISTRATION_ENABLED"] = "true"

        assert DecidimApp::Bijeljina::SocialRegistrationHandoff.available?,
               "with the flag set, isporuka D's route and initializer must be enough to arm it"
      ensure
        if previous.nil?
          ENV.delete("MI_SOCIAL_REGISTRATION_ENABLED")
        else
          ENV["MI_SOCIAL_REGISTRATION_ENABLED"] = previous
        end
      end

      private

      def redirect_path = response.location.to_s.sub(%r{\Ahttps?://[^/]+}, "")

      # One real registration through the root path, so the pending page has the
      # session-variant token it is gated by.
      def register!
        komsiluk = Decidim::Bih::LocalArea.create!(
          decidim_organization_id: @organization.id,
          kind: "komsiluk",
          slug: "k-#{SecureRandom.hex(4)}",
          name: { "sr" => "Test komšiluk" }
        )

        post REGISTRATION_PATH, params: {
          user: {
            name: "Mila Gradjanka",
            email: "mila-#{SecureRandom.hex(3)}@example.org",
            mobile_phone_number: "+38765123456",
            komsiluk_id: komsiluk.id,
            tos_agreement: "1"
          }
        }

        assert_redirected_to PENDING_PATH
      end
    end
  end
end
