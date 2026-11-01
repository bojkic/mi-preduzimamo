# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Concierge
      # R3 — the concierge "moji bodovi" (personal goodwill) intent. For a linked
      # Decidim::User it returns balance + level + leaderboard rank; for an
      # anonymous/unlinked chat it returns the graceful verify/link fallback. It
      # is READ-ONLY: asking for points never mutates the ledger.
      class ResponderGoodwillTest < ActiveSupport::TestCase
        # Minimal inbound message (no sender/identity of its own).
        Message = Struct.new(:text, :image_url, :latitude, :longitude, keyword_init: true) do
          def initialize(text: nil, image_url: nil, latitude: nil, longitude: nil)
            super
          end
        end

        class FakeDirectory
          def search(_query, **) = []
        end

        class FakeWaste
          def collection_days_for(_query) = nil
        end

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        # +resolver+ is a callable message -> Decidim::User|nil (the host bridge).
        def build_responder(resolver:)
          Responder.new(
            organization: @organization,
            directory: FakeDirectory.new,
            waste_schedule: FakeWaste.new,
            goodwill_user_resolver: resolver
          )
        end

        def respond(text, resolver:)
          build_responder(resolver: resolver).respond(Message.new(text: text))
        end

        # --- linked user: balance + level + rank ----------------------------

        test "returns balance, level and rank for a linked user with points" do
          @ledger.award(@user, 100, reason: "volunteer_hour") # contribution 100 -> "aktivista"

          reply = respond("koliko imam bodova", resolver: ->(_m) { @user })

          account = @ledger.account_for(@user)
          assert_includes reply.text, account.balance.to_s
          assert_includes reply.text, I18n.t("decidim.bih.goodwill.levels.aktivista", locale: "sr")
          # Sole citizen with earn credits -> rank #1.
          assert_includes reply.text, "#1"
          assert_nil reply.report
          assert_equal "goodwill", reply.answer_intent
        end

        test "rank reflects higher-scoring citizens ahead of the user" do
          leader = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(leader, 300, reason: "volunteer_hour")
          @ledger.award(@user, 100, reason: "volunteer_hour")

          reply = respond("moj rang", resolver: ->(_m) { @user })
          assert_includes reply.text, "#2"
        end

        test "earns the celebratory glas sticker for a linked user" do
          @ledger.award(@user, 100, reason: "volunteer_hour")
          reply = respond("moji bodovi", resolver: ->(_m) { @user })
          assert_equal :glas, reply.sticker
        end

        # --- linked user with no points -------------------------------------

        test "returns the 'none' reply for a linked user with zero points" do
          reply = respond("koliko imam bodova", resolver: ->(_m) { @user })

          expected = I18n.t("decidim.bih.concierge.goodwill.none",
                            url: Decidim::Bih::Engine.routes.url_helpers.wallet_path, locale: "sr")
          assert_equal expected, reply.text
          assert_nil reply.sticker
        end

        # --- anonymous / unlinked: graceful fallback ------------------------

        test "returns the not_linked fallback when no user can be resolved" do
          reply = respond("koliko imam bodova", resolver: ->(_m) {})

          expected = I18n.t("decidim.bih.concierge.goodwill.not_linked",
                            url: Decidim::Bih::Engine.routes.url_helpers.wallet_path, locale: "sr")
          # Task 6 appends the sign-in route to this fallback, so assert the
          # composition: the citizen is told why, and where to go.
          assert_includes reply.text, expected
          assert_includes reply.text, I18n.t("decidim.bih.dialogue.handoff_sign_in", url: "/users/sign_in", locale: "sr")
          assert_nil reply.report
          assert_equal "goodwill", reply.answer_intent
        end

        test "a goodwill question never falls through to a report" do
          reply = respond("koliko bodova imam u zajednici", resolver: ->(_m) {})
          assert_nil reply.report, "an unlinked points question must not file a report"
        end

        # --- a resolved GROUP is treated as no personal rank ----------------

        test "a resolved group user gets the not_linked fallback" do
          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          reply = respond("koliko bodova imam", resolver: ->(_m) { group })

          expected = I18n.t("decidim.bih.concierge.goodwill.not_linked",
                            url: Decidim::Bih::Engine.routes.url_helpers.wallet_path, locale: "sr")
          # Task 6 appends the sign-in route to this fallback, so assert the
          # composition: the citizen is told why, and where to go.
          assert_includes reply.text, expected
          assert_includes reply.text, I18n.t("decidim.bih.dialogue.handoff_sign_in", url: "/users/sign_in", locale: "sr")
        end

        # --- a since-blocked/deleted linked user confers no points ----------

        test "a blocked linked user gets the not_linked fallback (resolve_goodwill_user rejects)" do
          # A pre-existing linkage may point at an account that was blocked AFTER
          # it was created. resolve_goodwill_user must reject a non-active user so
          # the blocked account stops conferring points/recognition via the bot.
          @ledger.award(@user, 100, reason: "volunteer_hour")
          @user.update!(blocked: true, blocked_at: Time.current, extended_data: {})

          reply = respond("koliko imam bodova", resolver: ->(_m) { @user })

          expected = I18n.t("decidim.bih.concierge.goodwill.not_linked",
                            url: Decidim::Bih::Engine.routes.url_helpers.wallet_path, locale: "sr")
          # Task 6 appends the sign-in route to this fallback, so assert the
          # composition: the citizen is told why, and where to go.
          assert_includes reply.text, expected
          assert_includes reply.text, I18n.t("decidim.bih.dialogue.handoff_sign_in", url: "/users/sign_in", locale: "sr")
        end

        test "a deleted linked user gets the not_linked fallback (resolve_goodwill_user rejects)" do
          @ledger.award(@user, 100, reason: "volunteer_hour")
          @user.update!(deleted_at: Time.current)

          reply = respond("koliko imam bodova", resolver: ->(_m) { @user })

          expected = I18n.t("decidim.bih.concierge.goodwill.not_linked",
                            url: Decidim::Bih::Engine.routes.url_helpers.wallet_path, locale: "sr")
          # Task 6 appends the sign-in route to this fallback, so assert the
          # composition: the citizen is told why, and where to go.
          assert_includes reply.text, expected
          assert_includes reply.text, I18n.t("decidim.bih.dialogue.handoff_sign_in", url: "/users/sign_in", locale: "sr")
        end

        # --- cross-org safety: a foreign user's account is never returned ---

        test "a user from a different org than the responder yields no foreign account" do
          # The account lookup must be scoped to the RESPONDER's injected
          # organization, not the resolved user's own org. A resolver that
          # (erroneously) returns a user belonging to another organization must
          # never expose that foreign org's goodwill account.
          foreign_org = create_organization
          foreign_user = FactoryBot.create(:user, :confirmed, organization: foreign_org)
          # The foreign user has real points in their OWN org.
          @ledger.award(foreign_user, 100, reason: "volunteer_hour")
          assert Decidim::Bih::Goodwill::Account.exists?(decidim_organization_id: foreign_org.id)

          # Responder is wired to @organization, but the resolver returns the
          # foreign user. Task 6 resolves identity through own_state_user, which
          # is tenant-scoped, so the foreign user is rejected at RESOLUTION and
          # gets the not-linked hand-off.
          #
          # That is stricter than the "none" nudge this asserted before: "you
          # have no points yet" would itself have implied an account exists in
          # THIS organization. The hand-off states nothing about the actor.
          reply = respond("koliko imam bodova", resolver: ->(_m) { foreign_user })

          assert_includes reply.text,
                          I18n.t("decidim.bih.concierge.goodwill.not_linked",
                                 url: Decidim::Bih::Engine.routes.url_helpers.wallet_path, locale: "sr")
          # The property this test exists for: the foreign balance never leaks.
          refute_match(/\b100\b/, reply.text)
          assert_nil reply.sticker
        end

        # --- a resolver error degrades gracefully ---------------------------

        test "a raising resolver degrades to the not_linked fallback" do
          reply = respond("koliko bodova", resolver: ->(_m) { raise "boom" })

          expected = I18n.t("decidim.bih.concierge.goodwill.not_linked",
                            url: Decidim::Bih::Engine.routes.url_helpers.wallet_path, locale: "sr")
          # Task 6 appends the sign-in route to this fallback, so assert the
          # composition: the citizen is told why, and where to go.
          assert_includes reply.text, expected
          assert_includes reply.text, I18n.t("decidim.bih.dialogue.handoff_sign_in", url: "/users/sign_in", locale: "sr")
        end

        # --- READ-ONLY: asking for points never mutates the ledger ----------

        test "asking for points does not create an account or change the balance" do
          before = Decidim::Bih::Goodwill::Account.count
          respond("koliko imam bodova", resolver: ->(_m) { @user })
          # No account was minted for a user who had none.
          assert_equal before, Decidim::Bih::Goodwill::Account.count
        end

        test "a non-goodwill message is not handled by the goodwill intent" do
          reply = respond("zdravo", resolver: ->(_m) { @user })
          # Falls through to the help/fallback menu, not a points reply.
          assert_equal I18n.t("decidim.bih.concierge.help", locale: "sr"), reply.text
          assert_equal "help", reply.answer_intent
        end
      end
    end
  end
end
