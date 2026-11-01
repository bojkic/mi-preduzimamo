# frozen_string_literal: true

require "test_helper"
require "support/fake_redis"

module Decidim
  module Bih
    module Concierge
      # The concierge keeps board reads, while every legacy post request hands
      # off to the moderated board where category choice and publication have a
      # separate confirmation. Chat text/category input never publishes.
      class ResponderKomsilukTest < ActiveSupport::TestCase
        Message = Struct.new(:text, :image_url, :latitude, :longitude, :sender, keyword_init: true) do
          def initialize(text: nil, image_url: nil, latitude: nil, longitude: nil, sender: nil)
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
          @user = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       name: "Stvarno Ime", nickname: "komsija_x")
          @komsiluk = LocalArea.create!(organization: @organization, kind: "komsiluk",
                                        slug: "k-r22", name: { "sr" => "Test Komšiluk" })
          @other_komsiluk = LocalArea.create!(organization: @organization, kind: "komsiluk",
                                              slug: "k-r22-other", name: { "sr" => "Drugi Komšiluk" })
          @profile = CitizenProfile.for_user(@user, organization: @organization)
          @profile.assign_komsiluk!(@komsiluk, source: "dropdown")
          grant_sms_auth(@user)
        end

        def grant_sms_auth(user)
          Decidim::Authorization.find_or_initialize_by(user: user, name: "sms").tap do |auth|
            auth.granted_at = Time.current
            auth.save!
          end
        end

        def build_responder(resolver: ->(_m) { @user })
          Responder.new(organization: @organization, directory: FakeDirectory.new,
                        waste_schedule: FakeWaste.new, goodwill_user_resolver: resolver)
        end

        def respond(text, sender: "vib-1", resolver: ->(_m) { @user })
          build_responder(resolver:).respond(Message.new(text:, sender:))
        end

        # ── POST ─────────────────────────────────────────────────────────────

        test "a verified member is guided to the board without a chat publication" do
          reply = nil
          assert_no_difference -> { KomsilukPost.count } do
            reply = respond("objavi u komšiluku: Tražim majstora za česmu")
          end

          assert_nil reply.report
          assert_nil reply.sticker
          assert_equal "komsiluk_post", reply.answer_intent
          assert_includes reply.text, "/biceriseno/komsiluk-board"
          assert_includes reply.text, "potvrđuješ"
        end

        test "an unlinked sender receives the same safe board handoff" do
          assert_no_difference -> { KomsilukPost.count } do
            reply = respond("objavi u komšiluku: nešto", resolver: ->(_m) {})
            assert_nil reply.report
            assert_equal "komsiluk_post", reply.answer_intent
            assert_includes reply.text, "/biceriseno/komsiluk-board"
          end
        end

        test "an objavi command without content still uses the safe board handoff" do
          assert_no_difference -> { KomsilukPost.count } do
            reply = respond("objavi")
            assert_nil reply.report
            assert_includes reply.text, "/biceriseno/komsiluk-board"
          end
        end

        test "a Cyrillic post request stays read-only and is answered in Cyrillic" do
          reply = nil
          assert_no_difference -> { KomsilukPost.count } do
            reply = respond("објави у комшилуку: Нашао сам мачку")
          end
          assert_nil reply.report
          assert_match(/\p{Cyrillic}/, reply.text)
        end

        # ── CATEGORY PICKER (multi-turn, Viber/session only) ──────────────────

        def session_store
          @session_store ||= Decidim::Bih::Concierge::SessionStore.new(redis: FakeRedis.new)
                                                                  .for_organization(@organization.id)
        end

        def picker_responder
          Responder.new(organization: @organization, directory: FakeDirectory.new,
                        waste_schedule: FakeWaste.new, goodwill_user_resolver: ->(_m) { @user },
                        session_store: session_store)
        end

        test "a new post request does not create pending publication state" do
          responder = picker_responder
          reply = nil
          assert_no_difference -> { KomsilukPost.count } do
            reply = responder.respond(Message.new(text: "objavi u komšiluku: Nestao pas Reks", sender: "vib-1"))
          end
          assert_nil session_store.get(sender: "vib-1")
          assert_includes reply.text, "/biceriseno/komsiluk-board"
          assert_nil reply.report
          assert_equal "komsiluk_post", reply.answer_intent
        end

        test "an exact category number in an old pending state never publishes" do
          responder = picker_responder
          session_store.set(sender: "vib-1", state: "awaiting_komsiluk_category:Nestao pas Reks")

          reply = nil
          assert_no_difference -> { KomsilukPost.count } do
            reply = responder.respond(Message.new(text: "1", sender: "vib-1"))
          end
          assert_nil session_store.get(sender: "vib-1")
          assert_includes reply.text, "/biceriseno/komsiluk-board"
          assert_equal "komsiluk_post", reply.answer_intent
        end

        test "an exact category keyword in an old pending state never publishes" do
          responder = picker_responder
          session_store.set(sender: "vib-2", state: "awaiting_komsiluk_category:Provala u zgradi")

          reply = nil
          assert_no_difference -> { KomsilukPost.count } do
            reply = responder.respond(Message.new(text: "bezbjednost", sender: "vib-2"))
          end
          assert_nil session_store.get(sender: "vib-2")
          assert_includes reply.text, "/biceriseno/komsiluk-board"
        end

        test "an embedded category number is not accepted as a category" do
          responder = picker_responder
          session_store.set(sender: "vib-3", state: "awaiting_komsiluk_category:nešto")

          assert_no_difference -> { KomsilukPost.count } do
            reply = responder.respond(Message.new(text: "imam 2 psa", sender: "vib-3"))
            assert_equal "help", reply.answer_intent
          end
          assert_nil session_store.get(sender: "vib-3")
        end

        test "a photo mid-pick yields form guidance and no report or post" do
          responder = picker_responder
          session_store.set(sender: "vib-4", state: "awaiting_komsiluk_category:nestao pas")

          reply = nil
          assert_no_difference -> { KomsilukPost.count } do
            assert_no_difference -> { Decidim::Bih::Report.count } do
              reply = responder.respond(Message.new(text: "opasnost na putu",
                                                    image_url: "https://cdn.viber.com/x.jpg", sender: "vib-4"))
            end
          end
          assert_nil reply.report
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "without a sender (web chat), posting guides to the board instead of writing" do
          reply = nil
          assert_no_difference -> { KomsilukPost.count } do
            reply = build_responder.respond(Message.new(text: "objavi u komšiluku: Direktno"))
          end
          assert_nil reply.report
          assert_equal "komsiluk_post", reply.answer_intent
          assert_includes reply.text, "/biceriseno/komsiluk-board"
        end

        # ── READ ─────────────────────────────────────────────────────────────

        test "reading lists the komšiluk's recent posts by nickname only" do
          KomsilukPost.create!(organization: @organization, author: @user, komsiluk: @komsiluk,
                               category: "general", title: "Roštilj u subotu", body: "Dođite svi u park")

          reply = respond("šta ima u komšiluku?")

          assert_includes reply.text, "Roštilj u subotu"
          assert_includes reply.text, "@komsija_x", "author shown by nickname"
          assert_not_includes reply.text, "Stvarno Ime", "real name must never appear"
          assert_nil reply.report
          assert_equal "komsiluk_read", reply.answer_intent
        end

        test "reading never shows posts from another komšiluk" do
          KomsilukPost.create!(organization: @organization, author: @user, komsiluk: @other_komsiluk,
                               category: "general", title: "Tudja objava", body: "Iz drugog komšiluka")

          reply = respond("šta ima u komšiluku")

          assert_not_includes reply.text, "Tudja objava"
        end

        test "reading an empty board returns a friendly empty reply (not a report)" do
          reply = respond("šta ima u komšiluku")
          assert_nil reply.report
          assert reply.text.present?
        end

        test "reading from anonymous web chat points to the public board and setup path" do
          reply = build_responder(resolver: ->(_m) {}).respond(Message.new(text: "šta ima u komšiluku?"))

          assert_nil reply.report
          assert_equal "komsiluk_read", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_path
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.edit_komsiluk_path

          labels = reply.quick_replies.map { |chip| chip[:label] }
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.komsiluk", locale: "sr")
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.setup", locale: "sr")
        end

        test "a hidden post is not shown in the digest" do
          post = KomsilukPost.create!(organization: @organization, author: @user, komsiluk: @komsiluk,
                                      category: "general", title: "Skriveni", body: "tekst")
          post.update!(status: "hidden")

          reply = respond("šta ima u komšiluku")
          assert_not_includes reply.text, "Skriveni"
        end
      end
    end
  end
end
