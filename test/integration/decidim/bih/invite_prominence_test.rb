# frozen_string_literal: true

require "test_helper"
require "capybara"
require "nokogiri"

module Decidim
  module Bih
    # "Pozovi komšije" was built but buried: a non-default tab on a hub whose
    # every nav entry lands on a different tab. These are the surfaces that make
    # it reachable — the desktop header pill, the site-wide nudge and the mobile
    # "Još" sheet — and the rules that keep them from colliding with what is
    # already on screen.
    class InviteProminenceTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      INVITE_PATH = "/biceriseno/zajednistvo?tab=pozovi"

      setup do
        @organization = create_organization
        host! @organization.host
        # SAVE the values, do not assume nil. config/initializers/decidim_bih_race.rb
        # sets this window for the whole process, and LaunchModeNavigationTest
        # relies on it without setting its own — so a teardown that nils these
        # turns launch mode off for every later test in the same worker.
        @previous_race_window_from = Decidim::Bih.race_window_from
        @previous_race_window_to = Decidim::Bih.race_window_to
        Decidim::Bih.race_window_from = "2026-09-06 00:00:00"
        Decidim::Bih.race_window_to = "2026-10-14 20:00:00"
        @user = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana_poziva")
      end

      teardown do
        Decidim::Bih.race_window_from = @previous_race_window_from
        Decidim::Bih.race_window_to = @previous_race_window_to
      end

      def in_launch_window(&) = travel_to(Time.utc(2026, 9, 17, 12, 0, 0), &)

      def after_freeze(&) = travel_to(Time.utc(2026, 10, 20, 12, 0, 0), &)

      def verify!(user = @user)
        FactoryBot.create(:authorization, :granted, user:, name: "sms")
      end

      def doc = Nokogiri::HTML(response.body)

      # ---- desktop header pill ------------------------------------------- #

      # The pill takes the slot "Registruj se" occupies for a visitor, so a
      # signed-in citizen gains an action rather than the header gaining width.
      test "a signed-in citizen gets an invite pill in the desktop header" do
        in_launch_window do
          verify!
          sign_in @user
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          pill = doc.at_css("a.mi-main-bar-pill--invite")
          assert pill, "the signed-in header carries an invite pill"
          assert_equal INVITE_PATH, pill["href"]
          assert_match I18n.t("decidim.bih.menu.invite", locale: :sr), pill.text
        end
      end

      test "a signed-out visitor gets the register pill, not the invite pill" do
        in_launch_window do
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          assert_nil doc.at_css("a.mi-main-bar-pill--invite")
          assert doc.at_css("a.mi-main-bar-pill--register"), "a visitor is still asked to register"
        end
      end

      # Everything here is campaign furniture. It has to leave by itself at the
      # freeze, with no deploy, exactly as the rest of launch mode does.
      test "the invite pill is gone after the race freezes" do
        after_freeze do
          verify!
          sign_in @user
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          assert_nil doc.at_css("a.mi-main-bar-pill--invite")
        end
      end

      # ---- the site-wide nudge ------------------------------------------- #
      #
      # Deliberate asymmetry, recorded here because it looks like an oversight:
      # the NUDGE requires a granted verification, but the pill and the sheet do
      # not. The nudge's condition is not about who deserves to be asked — it is
      # about not stacking two bars in one strip, since the verify nudge owns
      # that slot for exactly the citizens this one skips. A pill and a menu
      # entry occupy no shared real estate, so they are offered to everyone
      # signed in; an unverified citizen can invite, and the invitee's
      # verification is what pays.

      test "a verified citizen sees the invite nudge with a link to the invite tab" do
        in_launch_window do
          verify!
          sign_in @user
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          nudge = doc.at_css(".mi-invite-nudge")
          assert nudge, "a verified citizen is nudged to invite"
          assert_equal INVITE_PATH, nudge.at_css("a")["href"]
          assert nudge.at_css("[data-invite-nudge-dismiss]"), "the nudge can be dismissed"
          assert_match I18n.t("decidim.bih.invite.nudge.action", locale: :sr), nudge.at_css("a").text,
                       "the copy comes from the engine locales, so sr-Cyrl is generated not hand-written"
        end
      end

      # The verify nudge occupies the same strip and is shown to exactly the
      # citizens this one is not. Two bars stacked on a phone is the collision
      # this rule exists to prevent — they are mutually exclusive by audience,
      # not by luck.
      test "an unverified citizen sees the verify nudge and not the invite nudge" do
        in_launch_window do
          sign_in @user
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          assert_includes response.body, "verify-nudge"
          assert_nil doc.at_css(".mi-invite-nudge")
        end
      end

      test "a signed-out visitor sees no invite nudge" do
        in_launch_window do
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          assert_nil doc.at_css(".mi-invite-nudge")
        end
      end

      # Asking someone to go to the page they are already reading is noise.
      test "the nudge stays off the invite tab itself" do
        in_launch_window do
          verify!
          sign_in @user
          get INVITE_PATH

          assert_response :success
          assert_nil doc.at_css(".mi-invite-nudge")
        end
      end

      test "the nudge is gone after the race freezes" do
        after_freeze do
          verify!
          sign_in @user
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          assert_nil doc.at_css(".mi-invite-nudge")
        end
      end

      # A citizen from another tenant is a visitor here, the same rule the
      # verify nudge already follows.
      test "a citizen of another organization is treated as a visitor" do
        in_launch_window do
          other = create_organization
          stranger = FactoryBot.create(:user, :confirmed, organization: other)
          FactoryBot.create(:authorization, :granted, user: stranger, name: "sms")

          sign_in stranger
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          assert_nil doc.at_css(".mi-invite-nudge")
          assert_nil doc.at_css("a.mi-main-bar-pill--invite")
        end
      end

      # ---- the account checklist ----------------------------------------- #

      # A permanent home that outlives the campaign: unlike the pill and the
      # nudge, this one is not gated on launch mode. It is offered, never
      # required — the completion percentage must not move (the engine's
      # AccountSummary unit test owns that half).
      test "the account setup checklist offers the invite step" do
        verify!
        sign_in @user
        get "/biceriseno/moj-nalog"

        assert_response :success
        assert_includes response.body,
                        I18n.t("decidim.bih.account.show.setup.steps.invite.title", locale: :sr)
        assert_includes response.body, INVITE_PATH
      end

      test "the account checklist still offers the invite step after the freeze" do
        after_freeze do
          verify!
          sign_in @user
          get "/biceriseno/moj-nalog"

          assert_response :success
          assert_includes response.body,
                          I18n.t("decidim.bih.account.show.setup.steps.invite.title", locale: :sr)
        end
      end

      # ---- the mobile sheet ---------------------------------------------- #

      # The mobile bar is full at four slots plus "Još" — its own source says a
      # fifth will not fit a 320px phone — so the sheet is where the invite
      # lives on a phone, first in the list rather than at the bottom of it.
      test "the mobile more-sheet carries the invite link first" do
        in_launch_window do
          verify!
          sign_in @user
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          links = doc.css(".mi-mobile-more-sheet__links a").map { |a| a["href"] }
          assert_includes links, INVITE_PATH
          assert_equal INVITE_PATH, links.first, "the invite is the first thing in the sheet"
        end
      end

      # The sheet entry is permanent, unlike the pill and the nudge. What the
      # freeze changes is its position: a campaign-priority slot above "Početna"
      # while the race runs, an ordinary menu item below it afterwards.
      test "the sheet keeps the invite after the freeze, below Pocetna" do
        after_freeze do
          verify!
          sign_in @user
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          links = doc.css(".mi-mobile-more-sheet__links a").map { |a| a["href"] }
          assert_includes links, INVITE_PATH, "the invite outlives the campaign"
          assert_equal "/", links.first, "after the freeze Početna leads again"
          assert_operator links.index(INVITE_PATH), :>, links.index("/")
        end
      end

      test "the mobile sheet offers no invite link to a signed-out visitor" do
        in_launch_window do
          get "/biceriseno/zajednistvo?tab=tabla"

          assert_response :success
          links = doc.css(".mi-mobile-more-sheet__links a").map { |a| a["href"] }
          assert_not_includes links, INVITE_PATH
        end
      end
    end
  end
end
