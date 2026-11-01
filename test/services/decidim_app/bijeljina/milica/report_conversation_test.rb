# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      # A courtesy turn after a report preview keeps the unexpired preview and
      # its confirm/cancel buttons; every other text still invalidates it.
      #
      # It is also where the EMERGENCY boundary is proven, because this is the
      # outermost layer of every production chat turn: the web widget and every
      # channel with report intake enter through here, so this is the boundary
      # that actually answers "gori mi kuća". The emergency cases run with the
      # real coordinator behind them and a model that RAISES if it is called.
      class ReportConversationTest < ActiveSupport::TestCase
        Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
        Outcome = Data.define(:state, :resolution, :fact_ids)

        ModelForbidden = Class.new(StandardError)

        # The dialogue state store's own Redis: separate from the draft store's,
        # and deliberately in-memory so every trial starts from nothing.
        class DialogueRedis
          def initialize = @values = {}

          def get(key) = @values[key]

          def del(key)
            @values.delete(key)
            1
          end

          # Mirrors Redis#eval for the state store's bounded Lua script on this
          # in-memory double; nothing is interpreted as Ruby.
          def eval(_script, keys:, argv:)
            stored = @values[keys.first]
            version = stored ? JSON.parse(stored).fetch("version") : 0
            return 0 unless version == argv.first

            @values[keys.first] = argv[1]
            1
          end
        end

        class InlineRuntime
          def call
            Decidim::Bih::Concierge::Dialogue::AdmissionControl::Result.new(
              status: :admitted, value: yield(Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 1))
            )
          end
        end

        class RaisingProcedures
          def call(**)
            raise ModelForbidden, "the procedures were reached on a safety turn"
          end
        end

        class RedisMemory
          attr_reader :data

          def initialize
            @data = {}
          end

          def get(key) = @data[key]

          def del(key) = @data.delete(key)

          # Mirrors Redis#eval for the store's bounded Lua scripts on this
          # in-memory double; nothing is interpreted as Ruby.
          def eval(script, keys:, argv:) # rubocop:disable Metrics/CyclomaticComplexity
            if script == ReportConversationStore::ACQUIRE
              return -1 if @data.has_key?(keys[1])
              return 0 if @data.has_key?(keys[0])

              @data[keys[0]] = argv[0]
              return 1
            end
            return 0 unless @data[keys.first] == argv.first
            return 0 if [ReportConversationStore::WRITE, ReportConversationStore::CLEAR].include?(script) && @data.has_key?(keys[2])

            case script
            when ReportConversationStore::RELEASE then @data.delete(keys.first)
            when ReportConversationStore::WRITE then @data[keys[1]] = argv[1]
                                                     1
            when ReportConversationStore::CLEAR then @data.delete(keys[1])
                                                     1
            else raise "Unexpected script"
            end
          end
        end

        setup do
          @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                   capabilities: ["report_guidance"], now: Time.now.utc)
          @store = ReportConversationStore.new(redis: RedisMemory.new,
                                               encryptor: ActiveSupport::MessageEncryptor.new("x" * 32, cipher: "aes-256-gcm", serializer: JSON))
          state_store = Object.new
          state_store.define_singleton_method(:read) { |**| nil }
          @submission = Object.new
          @submission.define_singleton_method(:call) { |**| raise "no submission expected" }
          @model_calls = 0
          @dialogue_store = Decidim::Bih::Concierge::Dialogue::StateStore.new(redis: DialogueRedis.new)
          @flow = ReportConversation.new(store: @store, submission: @submission, state_store:)
        end

        test "a courtesy after the preview keeps the draft and shows the buttons again" do
          I18n.with_locale(:sr) do
            preview = prepare
            command = preview.quick_replies.first.fetch(:send)

            { "hvala" => "thanks", "Hvala ti puno!" => "thanks", "zdravo" => "greeting", "doviđenja" => "farewell", "šta sve znaš?" => "capabilities" }.each do |text, kind|
              reply, outcome = turn(text) { flunk "a courtesy must not reach the model (#{text})" }

              assert_nil outcome
              draft = @store.read(context: @context)
              assert_equal "Oštećena klupa", draft.fetch("description"), text
              assert_equal command, reply.quick_replies.first.fetch(:send), "the same confirmation stays valid after #{text}"
              labels = reply.quick_replies.map { |chip| chip.fetch(:label) }
              assert_equal [I18n.t("bijeljina.milica_report.confirm_button", locale: :sr), I18n.t("bijeljina.milica_report.cancel_button", locale: :sr)], labels
              assert reply.text.start_with?(I18n.t("decidim.bih.dialogue.#{kind}", locale: :sr)), "#{text} answers with the #{kind} line"
              assert_includes reply.text, "Oštećena klupa"
            end
          end
        end

        test "a correction or an unrelated message still invalidates the preview" do
          I18n.with_locale(:sr) do
            ["Ispravka: opis je drugačiji", "hvala, a kad se odvozi smeće", "nerazumljiva poruka"].each do |text|
              prepare
              turn(text) { [plain, nil] }

              assert_nil @store.read(context: @context), text
            end
          end
        end

        # --- the emergency boundary ----------------------------------------

        test "every historical emergency opener names the right service in twenty trials with no model call" do
          I18n.with_locale(:sr) do
            emergency_openers.each do |scenario, (text, key, locale)|
              TRIALS.times do |trial|
                fresh_boundary
                reply, outcome = boundary(text)

                assert_equal "safety", reply.answer_intent, "#{scenario} trial #{trial + 1}"
                assert reply.text.start_with?(card(key, locale:)), "#{scenario} trial #{trial + 1}: #{reply.text}"
                assert_includes reply.text, card("emergency_disclaimer", locale:), "#{scenario} answers in #{locale}"
                assert_equal "safety_guidance", outcome.resolution, "#{scenario} must record safety guidance without report submission"
                assert_nil reply.report
                assert_empty reply.quick_replies
                assert_equal 0, @model_calls, "#{scenario} reached the model on trial #{trial + 1}"
                assert_nil @store.read(context: @context), "#{scenario} left a confirmable draft"
              end
            end
          end
        end

        test "no emergency card claims to have called anyone" do
          I18n.with_locale(:sr) do
            emergency_openers.each_value do |(text, _key, _locale)|
              fresh_boundary
              reply, = boundary(text)

              assert_no_match(/poslala sam|zvala sam|obavijestila sam|prosledila|dispatch|i have called|on the way/i, reply.text)
              assert_no_match(/\b\d+\s*(?:minut|minuta|minute|minutes)\b/i, reply.text, "no response time may be promised")
            end
          end
        end

        test "an emergency opener followed by its own follow-up is answered from bounded context" do
          I18n.with_locale(:sr) do
            emergency_chains.each do |scenario, (opener, follow_up, number)|
              TRIALS.times do |trial|
                fresh_boundary
                first, = boundary(opener)
                assert_equal "safety", first.answer_intent, "#{scenario} opener trial #{trial + 1}"

                second, outcome = boundary(follow_up)
                assert_equal "safety", second.answer_intent, "#{scenario} follow-up trial #{trial + 1}"
                assert_includes second.text, number, "#{scenario} follow-up trial #{trial + 1}"
                # The follow-up is a dialogue turn, so it carries the turn's
                # outcome — but it must still write no report and no draft.
                assert_equal "safety_guidance", outcome.resolution, "#{scenario} follow-up trial #{trial + 1}"
                assert_nil second.report
                assert_nil @store.read(context: @context), "#{scenario} left a confirmable draft"
                assert_equal 0, @model_calls, "#{scenario} reached the model on trial #{trial + 1}"
              end
            end
          end
        end

        test "a busy or unavailable draft store never turns an emergency into try again later" do
          I18n.with_locale(:sr) do
            [ReportConversationStore::Busy, ReportConversationStore::LeaseLost, Redis::BaseError].each do |failure|
              TRIALS.times do
                fresh_boundary
                prepare
                # The draft exists, so the emergency turn HAS to reach the
                # store to destroy it — and the store refuses.
                @store.define_singleton_method(:synchronize) { |**| raise failure }
                reply, outcome = boundary("Gori kontejner ispred zgrade!")

                assert_equal "safety", reply.answer_intent, failure.name
                assert reply.text.start_with?(card("emergency_fire")), failure.name
                assert_equal "safety_guidance", outcome.resolution
                assert_equal 0, @model_calls
              end
            end
          end
        end

        test "an unreadable draft store never turns an emergency into try again later" do
          I18n.with_locale(:sr) do
            fresh_boundary
            @store.define_singleton_method(:read) { |**| raise Redis::BaseError, "synthetic read failure" }
            reply, outcome = boundary("Gori kontejner ispred zgrade!")

            assert_equal "safety", reply.answer_intent
            assert reply.text.start_with?(card("emergency_fire"))
            assert_equal "safety_guidance", outcome.resolution
            assert_equal 0, @model_calls
          end
        end

        test "an emergency destroys a pending confirmation so no unreviewed report can follow it" do
          I18n.with_locale(:sr) do
            fresh_boundary
            preview = prepare
            command = preview.quick_replies.first.fetch(:send)
            reply, = boundary("U zgradi jako smrdi na plin i komšija se onesvijestio.")

            assert_equal "safety", reply.answer_intent
            assert reply.text.start_with?(card("emergency_gas"))
            assert_includes reply.text, card("emergency_also_medical")
            assert_nil @store.read(context: @context)
            expired, = turn(command) { flunk "a stale confirmation must not reach the model" }

            assert_includes expired.text, I18n.t("bijeljina.milica_report.expired", locale: :sr)
          end
        end

        test "a draft whose own description reports danger is never previewed or submitted" do
          I18n.with_locale(:sr) do
            fresh_boundary
            reply, outcome = turn("Prijava") { [plain, outcome(description: "Gori kontejner ispred zgrade")] }

            assert_equal "safety", reply.answer_intent
            assert reply.text.start_with?(card("emergency_fire"))
            assert_equal "safety_guidance", outcome.resolution
            assert_nil @store.read(context: @context)
          end
        end

        test "benign controls are never escalated and still reach the ordinary brain" do
          I18n.with_locale(:sr) do
            benign_controls.each do |scenario, text|
              TRIALS.times do |trial|
                fresh_boundary
                reached = false
                reply, = @flow.call(message: Decidim::Bih::Concierge::WebMessage.new(text), context: @context) do
                  reached = true
                  [plain, nil]
                end

                assert reached, "#{scenario} never reached the ordinary brain on trial #{trial + 1}"
                assert_not_equal "safety", reply.answer_intent, "#{scenario} escalated on trial #{trial + 1}"
                assert_no_match(/12[234]/, reply.text, "#{scenario} escalated on trial #{trial + 1}")
              end
            end
          end
        end

        private

        TRIALS = 20

        # scenario => [message, the card line it must lead with, the locale]
        def emergency_openers
          {
            "repeat-trial noun" => ["požar u kontejneru ispred zgrade, šta da radim?", "emergency_fire", :sr],
            "repeat-trial verb" => ["gori kontejner ispred zgrade, šta da radim?", "emergency_fire", :sr],
            "b1c06 chemical" => ["Izlio se neki hemijski otpad iz kamiona kod škole, ima dim, šta da radimo?", "emergency_gas", :sr],
            "b1c27 fire" => ["Gori kontejner ispred zgrade!", "emergency_fire", :sr],
            "b1c28 cyrillic fire" => ["Пожар у подруму зграде, шири се дим!", "emergency_fire", :"sr-Cyrl"],
            "b1c29 mixed intent" => ["Treba mi raspored smeća ali HITNO sada požar u kontejneru ispred škole!", "emergency_fire", :sr],
            "b1c30 collapse" => ["Čovjek se upravo srušio na ulici i ne reaguje, koga da zovem?", "emergency_medical", :sr],
            "b1c31 gas" => ["U zgradi jako smrdi na plin i komšija se onesvijestio.", "emergency_gas", :sr],
            "b1c36 flood" => ["Voda iz rijeke trenutno ulazi u kuće u Janji, ljudi su unutra. Koga da zovem odmah?", "emergency_flood", :sr],
            "unlisted object" => ["Gori krov na susjednoj kući!", "emergency_fire", :sr],
            "english" => ["The container is on fire, what do I do?", "emergency_fire", :en],
            "trapped" => ["Ne mogu izaći iz lifta", "emergency_trapped", :sr]
          }
        end

        # scenario => [opener, follow-up, the number the follow-up must name]
        def emergency_chains
          {
            "b1c06" => ["Izlio se neki hemijski otpad iz kamiona kod škole, ima dim, šta da radimo?",
                        "Djeca su pored toga sada. Daj broj službe, kratko.", "123"],
            "b1c27" => ["Gori kontejner ispred zgrade!", "Koga da zovem odmah?", "123"],
            "b1c28" => ["Пожар у подруму зграде, шири се дим!", "Људи су још унутра. Кога да зовем одмах?", "123"],
            "b1c30" => ["Čovjek se upravo srušio na ulici i ne reaguje, koga da zovem?", "Treba mi broj hitne pomoći, odmah.", "124"],
            "b1c31" => ["U zgradi jako smrdi na plin i komšija se onesvijestio.", "Koji je broj hitne pomoći?", "124"],
            "b1c36" => ["Voda iz rijeke trenutno ulazi u kuće u Janji, ljudi su unutra. Koga da zovem odmah?",
                        "To je opasnost sada, ne tražim mjerenje vodostaja.", "123"]
          }
        end

        def benign_controls
          {
            "waste" => "Kad se odvozi smeće u Dvorovima?",
            "parking" => "Koliko košta parking u crvenoj zoni?",
            "bench report" => "Prijavljujem oštećenu klupu u parku",
            "fire insurance" => "Koliko košta osiguranje od požara?",
            "past fire" => "Juče je bio požar u kontejneru",
            "street light" => "Gori li ulična rasvjeta u mom komšiluku?"
          }
        end

        def card(key, locale: :sr)
          I18n.t("decidim.bih.dialogue.#{key}", locale:, raise: true)
        end

        # One fresh conversation: a fresh draft store, a fresh dialogue state
        # and a zeroed model counter, so no trial can inherit another's state.
        def fresh_boundary
          @store = ReportConversationStore.new(redis: RedisMemory.new,
                                               encryptor: ActiveSupport::MessageEncryptor.new("x" * 32, cipher: "aes-256-gcm", serializer: JSON))
          @dialogue_store = Decidim::Bih::Concierge::Dialogue::StateStore.new(redis: DialogueRedis.new)
          @model_calls = 0
          @flow = ReportConversation.new(store: @store, submission: @submission, state_store: @dialogue_store)
          true
        end

        # The production composition: the host boundary wrapping the real
        # coordinator, with a model that raises the moment it is reached.
        def boundary(text)
          @flow.call(message: Decidim::Bih::Concierge::WebMessage.new(text), context: @context) { coordinator_turn(text) }
        end

        def coordinator_turn(text)
          understanding = lambda do |**|
            @model_calls += 1
            raise ModelForbidden, "the model was reached on a safety turn"
          end
          coordinator = Decidim::Bih::Concierge::Dialogue::Coordinator.new(
            understanding:, procedures: RaisingProcedures.new, state_store: @dialogue_store, runtime: InlineRuntime.new
          )
          result = coordinator.call(message: Decidim::Bih::Concierge::WebMessage.new(text), context: @context)
          [result.reply, result]
        end

        def plain = Decidim::Bih::Concierge::Responder::Reply.new(text: "normal reply")

        def outcome(description: "Oštećena klupa")
          Outcome.new(state: { "version" => 0, "active_task" => "report_problem", "pending_slot" => nil, "report_handoff_offered" => true,
                               "entities" => { "description" => description, "address" => "Testna ulica" }, "locale" => "sr" },
                      resolution: "handoff", fact_ids: [])
        end

        def prepare
          reply, _outcome = turn("Prijavljujem oštećenu klupu") { [plain, outcome] }
          assert_equal 2, reply.quick_replies.size
          reply
        end

        def turn(text, &)
          @flow.call(message: Decidim::Bih::Concierge::WebMessage.new(text), context: @context, &)
        end
      end
    end
  end
end
