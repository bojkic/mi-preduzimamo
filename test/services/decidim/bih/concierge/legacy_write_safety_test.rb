# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Concierge
      # Adversarial gate for the legacy adapter. Model labels, text, media,
      # location and obsolete category state may select guidance; none is
      # authority to create a report, post or identity effect.
      class LegacyWriteSafetyTest < ActiveSupport::TestCase
        Message = Struct.new(:text, :image_url, :latitude, :longitude, :sender, keyword_init: true) do
          def location_context? = false
        end

        class EmptyDirectory
          def search(*) = []
        end

        class EmptyWaste
          def collection_days_for(*) = nil
        end

        class RecordingIntake
          attr_reader :calls

          def initialize = (@calls = [])

          def call(**attributes)
            @calls << attributes
            raise "legacy responder must not invoke ReportIntake"
          end
        end

        class RecordingImageFetcher
          attr_reader :calls

          def initialize = (@calls = [])

          def call(url)
            @calls << url
            raise "legacy responder must not fetch report evidence"
          end
        end

        class RecordingAccountLinking
          attr_reader :starts, :verifications

          def initialize
            @starts = []
            @verifications = []
          end

          def start(**attributes)
            @starts << attributes
            :otp_sent
          end

          def verify(**attributes)
            @verifications << attributes
            :verified
          end
        end

        class MemorySessionStore
          attr_reader :states

          def initialize = (@states = {})

          def get(sender:) = states[sender]

          def set(sender:, state:) = (states[sender] = state)

          def clear(sender:) = states.delete(sender)
        end

        class FixedClassifier
          def initialize(intent) = (@intent = intent)

          def configured? = true

          def classify(_text)
            Decidim::Bih::Concierge::IntentClassifier::Result.new(intent: @intent, query: nil)
          end
        end

        class FailingClassifier
          SECRET = "citizen-secret-8462"

          def configured? = true

          def classify(*) = raise("classifier unavailable #{SECRET}")
        end

        setup do
          @organization = create_organization
          @intake = RecordingIntake.new
          @image_fetcher = RecordingImageFetcher.new
          @account_linking = RecordingAccountLinking.new
          @sessions = MemorySessionStore.new
        end

        def responder(classifier: nil, allow_classifier_text_report: false)
          Responder.new(
            organization: @organization,
            directory: EmptyDirectory.new,
            waste_schedule: EmptyWaste.new,
            report_intake: @intake,
            image_fetcher: @image_fetcher,
            account_linking: @account_linking,
            session_store: @sessions,
            classifier:,
            allow_classifier_text_report:
          )
        end

        def assert_no_legacy_writes
          Decidim::Bih::Komsiluk::PostCreator.stub(
            :new,
            ->(*) { flunk "legacy responder must not instantiate PostCreator" }
          ) { yield }

          assert_empty @intake.calls
        end

        test "safety beats a pending OTP even when the threat contains six digits" do
          @sessions.set(sender: "citizen", state: Responder::STATE_AWAITING_CODE)

          reply = nil
          assert_no_legacy_writes do
            reply = responder.respond(Message.new(text: "Neko mi prijeti 123456", sender: "citizen"))
          end

          assert_equal "safety", reply.answer_intent
          assert_empty @account_linking.verifications
          assert_equal Responder::STATE_AWAITING_CODE, @sessions.get(sender: "citizen")
        end

        test "explicit negation cancels an obsolete pending post before category parsing" do
          @sessions.set(sender: "citizen", state: "#{Responder::STATE_AWAITING_KOMSILUK_CATEGORY}:tekst")

          reply = nil
          assert_no_legacy_writes do
            reply = responder.respond(Message.new(text: "Ne objavljuj 2", sender: "citizen"))
          end

          assert_equal "help", reply.answer_intent
          assert_nil @sessions.get(sender: "citizen")
        end

        test "explicit cancellation with numeric noise clears pending OTP without verification" do
          @sessions.set(sender: "citizen", state: Responder::STATE_AWAITING_CODE)

          reply = nil
          assert_no_legacy_writes do
            reply = responder.respond(Message.new(text: "odustani 123456", sender: "citizen"))
          end

          assert_equal "help", reply.answer_intent
          assert_empty @account_linking.verifications
          assert_nil @sessions.get(sender: "citizen")
        end

        test "embedded category numbers are not category input" do
          @sessions.set(sender: "citizen", state: "#{Responder::STATE_AWAITING_KOMSILUK_CATEGORY}:tekst")

          reply = nil
          assert_no_legacy_writes do
            reply = responder.respond(Message.new(text: "izaberi 2 molim", sender: "citizen"))
          end

          assert_equal "help", reply.answer_intent
          assert_nil @sessions.get(sender: "citizen")
        end

        test "an exact category from obsolete state returns board guidance but never publishes" do
          @sessions.set(sender: "citizen", state: "#{Responder::STATE_AWAITING_KOMSILUK_CATEGORY}:tekst")

          reply = nil
          assert_no_legacy_writes do
            reply = responder.respond(Message.new(text: "2", sender: "citizen"))
          end

          assert_equal "komsiluk_post", reply.answer_intent
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_path
          assert_nil @sessions.get(sender: "citizen")
        end

        test "a category choice from a different sender cannot consume pending state" do
          @sessions.set(sender: "first", state: "#{Responder::STATE_AWAITING_KOMSILUK_CATEGORY}:tekst")

          reply = nil
          assert_no_legacy_writes do
            reply = responder.respond(Message.new(text: "2", sender: "second"))
          end

          assert_equal "help", reply.answer_intent
          assert_equal "#{Responder::STATE_AWAITING_KOMSILUK_CATEGORY}:tekst", @sessions.get(sender: "first")
        end

        test "phone digits embedded in registration prose do not start identity verification" do
          @sessions.set(sender: "citizen", state: Responder::STATE_AWAITING_PHONE)

          assert_no_legacy_writes do
            responder.respond(Message.new(text: "registruj me, broj je 065123456", sender: "citizen"))
          end

          assert_empty @account_linking.starts
        end

        test "OTP digits embedded in prose do not verify identity" do
          @sessions.set(sender: "citizen", state: Responder::STATE_AWAITING_CODE)

          assert_no_legacy_writes do
            responder.respond(Message.new(text: "kod je 123456", sender: "citizen"))
          end

          assert_empty @account_linking.verifications
          assert_equal Responder::STATE_AWAITING_CODE, @sessions.get(sender: "citizen")
        end

        test "bare image and GPS each return form guidance without intake or image fetch" do
          replies = []
          assert_no_legacy_writes do
            replies << responder.respond(Message.new(image_url: "https://cdn.example/photo.jpg", sender: "citizen"))
            replies << responder.respond(Message.new(latitude: 44.756, longitude: 19.216, sender: "citizen"))
          end

          assert_empty @image_fetcher.calls
          replies.each do |reply|
            assert_nil reply.report
            assert_equal "report_guidance", reply.answer_intent
            assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
          end
        end

        test "classifier failure leaves unknown text at clarification with zero writes" do
          reply = nil
          warnings = []
          Rails.logger.stub(:warn, ->(message) { warnings << message }) do
            assert_no_legacy_writes do
              reply = responder(classifier: FailingClassifier.new)
                      .respond(Message.new(text: "duga nejasna poruka bez poznate namjere", sender: "citizen"))
            end
          end

          assert_equal "help", reply.answer_intent
          assert_nil reply.report
          assert_equal 1, warnings.size
          assert_includes warnings.first, "intent_classifier_failed"
          assert_includes warnings.first, "error_class=RuntimeError"
          assert_not_includes warnings.first, FailingClassifier::SECRET
          assert_not_includes warnings.first, "classifier unavailable"
        end

        test "classifier report label can offer guidance but cannot authorize intake" do
          reply = nil
          assert_no_legacy_writes do
            reply = responder(classifier: FixedClassifier.new(:report), allow_classifier_text_report: true)
                    .respond(Message.new(text: "nejasna poruka", sender: "citizen"))
          end

          assert_equal "report_guidance", reply.answer_intent
          assert_nil reply.report
          assert_includes reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
        end

        test "explicit report and post requests preserve supported handoffs without effects" do
          report_reply = nil
          post_reply = nil
          assert_no_legacy_writes do
            report_reply = responder.respond(Message.new(text: "želim da prijavim rupu", sender: "citizen"))
            post_reply = responder.respond(Message.new(text: "objavi u komšiluku: druženje", sender: "citizen"))
          end

          assert_equal "report_guidance", report_reply.answer_intent
          assert_includes report_reply.text, Decidim::Bih::Engine.routes.url_helpers.new_report_path
          assert_equal "komsiluk_post", post_reply.answer_intent
          assert_includes post_reply.text, Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_path
        end

        test "optional civic turn receives only the civic block exactly once and old calls remain compatible" do
          calls = []
          civic_turn = lambda do |*arguments, &work|
            calls << { arguments:, work: }
            work.call
          end

          latin_reply = responder.respond(Message.new(text: "hej", sender: "citizen"), civic_turn:)
          cyrillic_reply = responder.respond(Message.new(text: "ћао", sender: "citizen"), civic_turn:)
          legacy_reply = responder.respond(Message.new(text: "hej", sender: "citizen"))

          assert_equal 2, calls.length
          calls.each do |call|
            assert_empty call.fetch(:arguments)
            assert_respond_to call.fetch(:work), :call
          end
          assert_equal "help", latin_reply.answer_intent
          assert_equal legacy_reply.text, latin_reply.text
          assert_equal legacy_reply.answer_intent, latin_reply.answer_intent
          assert_match(/\p{Cyrillic}/, cyrillic_reply.text)
          assert_equal "help", legacy_reply.answer_intent
        end

        test "a server civic turn may return without yielding to civic work" do
          classifier = Class.new do
            attr_reader :calls

            def initialize = (@calls = 0)

            def configured? = true

            def classify(_text)
              @calls += 1
              Decidim::Bih::Concierge::IntentClassifier::Result.new(intent: :help, query: nil)
            end
          end.new
          sentinel = Responder::Reply.new(text: "server handoff", report: nil, answer_intent: "server")
          adapter_calls = 0
          civic_turn = lambda do
            adapter_calls += 1
            sentinel
          end

          reply = responder(classifier:).respond(Message.new(text: "hej", sender: "citizen"), civic_turn:)

          assert_same sentinel, reply
          assert_equal 1, adapter_calls
          assert_equal 0, classifier.calls
        end

        test "the civic turn cannot retry after an adapter error and responder state is cleaned" do
          attempts = 0
          civic_turn = lambda do |&work|
            attempts += 1
            work.call
            raise "civic adapter failed"
          end

          assert_raises(RuntimeError) do
            responder.respond(Message.new(text: "hej", sender: "citizen"), civic_turn:)
          end

          assert_equal 1, attempts
          assert_nil Thread.current[Responder::REPLY_LOCALE_KEY]
          assert_nil Thread.current[Responder::PROMOTED_INTENT_KEY]
          assert_nil Thread.current[Responder::PROMOTED_QUERY_KEY]
        end

        test "the civic turn is denied by every prelude-owned response" do
          calls = 0
          denied_civic_turn = lambda do
            calls += 1
            flunk "civic turn must not receive prelude-owned responses"
          end

          safety_reply = responder.respond(
            Message.new(text: "Neko mi prijeti 123456", sender: "safety"), civic_turn: denied_civic_turn
          )

          @sessions.set(sender: "cancel", state: Responder::STATE_AWAITING_CODE)
          cancellation_reply = responder.respond(
            Message.new(text: "odustani", sender: "cancel"), civic_turn: denied_civic_turn
          )

          link_reply = responder.respond(
            Message.new(text: "poveži nalog", sender: "link"), civic_turn: denied_civic_turn
          )

          @sessions.set(sender: "phone", state: Responder::STATE_AWAITING_PHONE)
          phone_reply = responder.respond(
            Message.new(text: "065123456", sender: "phone"), civic_turn: denied_civic_turn
          )

          @sessions.set(sender: "code", state: Responder::STATE_AWAITING_CODE)
          code_reply = responder.respond(
            Message.new(text: "123456", sender: "code"), civic_turn: denied_civic_turn
          )

          @sessions.set(
            sender: "category",
            state: "#{Responder::STATE_AWAITING_KOMSILUK_CATEGORY}:tekst"
          )
          category_reply = responder.respond(
            Message.new(text: "2", sender: "category"), civic_turn: denied_civic_turn
          )

          assert_equal 0, calls
          assert_equal "safety", safety_reply.answer_intent
          assert_equal "help", cancellation_reply.answer_intent
          assert_equal "account_linking", link_reply.answer_intent
          assert_equal "account_linking", phone_reply.answer_intent
          assert_equal "account_linking", code_reply.answer_intent
          assert_equal "komsiluk_post", category_reply.answer_intent
          assert_equal Responder::STATE_AWAITING_PHONE, @sessions.get(sender: "link")
          assert_equal Responder::STATE_AWAITING_CODE, @sessions.get(sender: "phone")
          assert_nil @sessions.get(sender: "cancel")
          assert_nil @sessions.get(sender: "code")
          assert_nil @sessions.get(sender: "category")
          assert_equal [{ sender: "phone", phone: "065123456" }], @account_linking.starts
          assert_equal [{ sender: "code", code: "123456" }], @account_linking.verifications
        end
      end
    end
  end
end
