# frozen_string_literal: true

require "test_helper"
require "support/fake_redis"

module Decidim
  module Bih
    module Concierge
      # Exercises the multi-turn account-linking conversation layered onto the
      # Responder, plus the safe report-form handoff after linking. The existing
      # ResponderTest (whose Message has no #sender, and which wires no
      # account_linking) proves the single-turn path stays green.
      class ResponderLinkTest < ActiveSupport::TestCase
        # Inbound message WITH a #sender (real Viber messages carry one).
        Message = Struct.new(:text, :image_url, :latitude, :longitude, :sender, keyword_init: true) do
          def initialize(text: nil, image_url: nil, latitude: nil, longitude: nil, sender: nil)
            super
          end
        end

        # Records OTP sends; ->(phone, text) callable gateway shape.
        class StubGateway
          attr_reader :sends

          def initialize = (@sends = [])

          def call(phone, text) = (@sends << { phone: phone, text: text })
        end

        setup do
          @organization = create_organization
          @redis = FakeRedis.new
          @gateway = StubGateway.new
          @account_linking = Decidim::Bih::Viber::AccountLinking.new(
            organization: @organization,
            gateway: @gateway,
            otp_store: Decidim::Bih::Viber::OtpStore.new(redis: @redis)
          )
          @session = Decidim::Bih::Concierge::SessionStore.new(redis: @redis)
                                                          .for_organization(@organization.id)
          @responder = build_responder
        end

        def build_responder
          Responder.new(
            organization: @organization,
            directory: Object.new.tap { |o| o.define_singleton_method(:search) { |*, **| [] } },
            waste_schedule: Object.new.tap { |o| o.define_singleton_method(:collection_days_for) { |_| nil } },
            account_linking: @account_linking,
            session_store: @session
          )
        end

        def last_code = @gateway.sends.last[:text][/\d{6}/]

        test "a link keyword opens the flow and asks for a phone number" do
          reply = @responder.respond(Message.new(text: "želim da poveži nalog", sender: "s1"))

          assert_nil reply.report
          assert_includes reply.text, "broj telefona"
          assert_equal "awaiting_phone", @session.get(sender: "s1")
          assert_equal "account_linking", reply.answer_intent
        end

        test "sending a phone while awaiting_phone triggers an OTP send and awaits the code" do
          @responder.respond(Message.new(text: "verifikuj", sender: "s1"))
          reply = @responder.respond(Message.new(text: "065 123 456", sender: "s1"))

          assert_equal 1, @gateway.sends.size, "the OTP gateway must be called"
          assert_includes reply.text, "kod"
          assert_equal "awaiting_code", @session.get(sender: "s1")
          assert_equal "account_linking", reply.answer_intent
        end

        test "the full keyword -> phone -> code flow verifies the sender" do
          @responder.respond(Message.new(text: "poveži", sender: "s1"))
          @responder.respond(Message.new(text: "065123456", sender: "s1"))
          reply = @responder.respond(Message.new(text: last_code, sender: "s1"))

          assert_includes reply.text, "potvrđen"
          assert_nil @session.get(sender: "s1"), "state is cleared after success"
          assert_equal "065123456", @account_linking.linked_phone(sender: "s1")
          assert_equal "account_linking", reply.answer_intent
        end

        test "a wrong code while awaiting_code reports failure and keeps the state" do
          @responder.respond(Message.new(text: "registruj", sender: "s1"))
          @responder.respond(Message.new(text: "065123456", sender: "s1"))
          real = last_code
          wrong = format("%06d", (real.to_i + 1) % 1_000_000)

          reply = @responder.respond(Message.new(text: wrong, sender: "s1"))

          assert_includes reply.text, "nije tačan"
          assert_equal "awaiting_code", @session.get(sender: "s1")
        end

        test "a verified sender's problem description does not create an attributed report" do
          @responder.respond(Message.new(text: "poveži", sender: "s1"))
          @responder.respond(Message.new(text: "065123456", sender: "s1"))
          @responder.respond(Message.new(text: last_code, sender: "s1"))

          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = @responder.respond(Message.new(text: "kako da prijavim veliku rupu na putu", sender: "s1"))
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "an unlinked sender's problem description also stays read-only" do
          reply = nil
          assert_no_difference -> { Decidim::Bih::Report.count } do
            reply = @responder.respond(Message.new(text: "kako da prijavim pokvarenu rasvjetu", sender: "nope"))
          end

          assert_nil reply.report
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "a photo mid-link gets report-form guidance without intake or OTP send" do
          # Sender is mid awaiting_phone, but a photo is evidence, not a phone.
          @responder.respond(Message.new(text: "poveži", sender: "s1"))

          reply = @responder.respond(
            Message.new(text: "rupa", image_url: "https://cdn.viber.com/x.jpg", sender: "s1")
          )

          assert_nil reply.report
          assert_empty @gateway.sends, "no OTP is sent: the photo is not a phone number"
          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "a 6-digit code is accepted even alongside a stray report signal (mid-code-entry)" do
          @responder.respond(Message.new(text: "poveži", sender: "s1"))
          @responder.respond(Message.new(text: "065123456", sender: "s1"))
          code = last_code

          # A photo accompanies the code, yet verification still wins so the user
          # can't get stuck.
          reply = @responder.respond(
            Message.new(text: code, image_url: "https://cdn.viber.com/x.jpg", sender: "s1")
          )

          assert_nil reply.report
          assert_includes reply.text, "potvrđen"
          assert_equal "account_linking", reply.answer_intent
        end

        test "linking stays disabled (single-turn) when deps are not wired" do
          bare = Responder.new(
            organization: @organization,
            directory: Object.new.tap { |o| o.define_singleton_method(:search) { |*, **| [] } },
            waste_schedule: Object.new.tap { |o| o.define_singleton_method(:collection_days_for) { |_| nil } }
          )
          reply = bare.respond(Message.new(text: "poveži", sender: "s1"))

          # No linking dep => keyword falls through to the help fallback.
          assert_includes reply.text, "Ne treba ti naziv odjeljenja"
          assert_equal "help", reply.answer_intent
        end
      end
    end
  end
end
