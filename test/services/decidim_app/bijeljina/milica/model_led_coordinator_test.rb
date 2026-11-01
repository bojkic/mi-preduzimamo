# frozen_string_literal: true

require "test_helper"
require "ostruct"

module DecidimApp
  module Bijeljina
    module Milica
      class ModelLedCoordinatorTest < ActiveSupport::TestCase
        Dialogue = Decidim::Bih::Concierge::Dialogue

        class Store
          attr_reader :state, :writes
          attr_accessor :conflict

          def initialize(context)
            @normalizer = Dialogue::StateStore.new
            @state = @normalizer.empty_state(context)
            @writes = 0
          end

          def read(**) = @state

          def reset(context)
            @state = @normalizer.empty_state(context)
          end

          def write(context:, state:, expected_version:)
            return :conflict if conflict || expected_version != @state["version"]

            @state = @normalizer.send(:normalize_state, state.merge("version" => expected_version + 1), now: context.now)
            @writes += 1
            :saved
          end
        end

        setup do
          @organization = Struct.new(:id).new(19)
          @context = Dialogue::Contracts::TrustedContext.new(organization_id: 19, actor_id: nil,
                                                             conversation_key: "a" * 64, capabilities: %w(public_reads report_guidance), now: Time.utc(2026, 9, 16, 10))
          @store = Store.new(@context)
          @requests = []
          @responses = []
          @client = Object.new
          requests = @requests
          responses = @responses
          @client.define_singleton_method(:generate_content) do |**request|
            requests << request
            responses.shift || raise("unexpected extra model call")
          end
          @registry = Dialogue::ReadToolRegistry.new(definitions: [{ "name" => "read_public", "description" => "Public source",
                                                                     "parameters" => { "type" => "object", "properties" => {}, "required" => [], "additionalProperties" => false },
                                                                     "handler" => ->(**) { raise "unused reader" } }])
          tools = OpenStruct.new(registry: @registry, eligibility: ->(**) { true })
          tools.define_singleton_method(:initial_evidence) { |**| [] }
          @runtime = Object.new
          @runtime.define_singleton_method(:call) do |&block|
            OpenStruct.new(admitted?: true, value: block.call(Dialogue::TurnBudget.new(timeout: 9)))
          end
          @workflow = Object.new
          @coordinator = ModelLedCoordinator.new(organization: @organization, client: @client, tools_factory: ->(**) { tools },
                                                 workflow: @workflow, state_store: @store, runtime: @runtime,
                                                 accounting_factory: -> { ->(**, &block) { block.call } })
        end

        def answer(text = "Koje stajalište želiš?")
          OpenStruct.new(function_calls: [], finish_reason: "STOP", usage: {},
                         structured: { "kind" => "clarification", "answer" => text, "evidence_ids" => [] },
                         content: { "role" => "model", "parts" => [{ "text" => text }] })
        end

        def citizen_message(text)
          Decidim::Bih::Concierge::WebMessage.new(text, trusted_context: @context)
        end

        test "board reference accepts generated locales and requires an exact deliberate reference" do
          ["Pročitaj objavu sa table #42.", "Прочитај објаву са табле #42.", "Read board notice #42."].each do |text|
            assert_equal 42, BoardNoticeReference.post_id(text)
          end
          ["Objava #42", "Read board notice #0.", "Read board notice #-42.", "Read board notice #42. More text",
           "Read board notice 42", "Read board notice #42 #43"].each do |text|
            assert_nil BoardNoticeReference.post_id(text)
          end
        end

        test "private board reference stays outside public model history and rechecks visibility" do
          organization = create_organization
          actor = FactoryBot.create(:user, :confirmed, organization:)
          area = Decidim::Bih::LocalArea.create!(organization:, kind: "komsiluk", slug: "private-milica-board", name: { sr: "Komšiluk" })
          Decidim::Bih::CitizenProfile.for_user(actor, organization:).assign_komsiluk!(area, source: "dropdown")
          notice = Decidim::Bih::KomsilukPost.create!(organization:, komsiluk: area, category: "general", title: "Privatna objava",
                                                    body: "Privatni detalj samo za članove")
          context = Dialogue::Contracts::TrustedContext.new(organization_id: organization.id, actor_id: actor.id,
                                                            account_state: "registered", conversation_key: "b" * 64,
                                                            capabilities: %w(public_reads neighborhood_reads report_guidance), now: Time.current)
          store = Store.new(context)
          coordinator = ModelLedCoordinator.new(organization:, client: @client, tools_factory: ->(**) { raise "unexpected public tools" },
                                                 workflow: @workflow, state_store: store, runtime: @runtime,
                                                 accounting_factory: -> { ->(**, &block) { block.call } })
          message = Decidim::Bih::Concierge::WebMessage.new("Pročitaj objavu sa table ##{notice.id}.", trusted_context: context)
          assert_no_difference("Decidim::Bih::Report.count") do
            result = coordinator.call(message:, context:)
            assert_equal "answered", result.resolution
            assert_includes result.reply.text, notice.body
            assert_includes result.reply.text, "/biceriseno/komsiluk-board/#{notice.id}"
            assert_includes result.reply.text, "/biceriseno/prijave"
          end
          assert_empty @requests
          assert_not_includes store.state.to_json, notice.body
          notice.update!(status: "hidden")
          hidden = coordinator.call(message:, context:)
          assert_equal "source_unavailable", hidden.resolution
          assert_not_includes hidden.reply.text, notice.title
          assert_not_includes hidden.reply.text, notice.body
          assert_empty @requests
        end

        test "report guidance shortcut distinguishes filing a problem from account registration status" do
          assert @coordinator.send(:report_guidance_question?, "Kako da prijavim rupu na putu?")
          refute @coordinator.send(:report_guidance_question?, "Gdje sam prijavljen?")
        end

        test "an established named location is recalled from slots without a model call" do
          @store.state[Dialogue::ConversationSlots::KEY] = Dialogue::ConversationSlots.empty.merge(
            "location" => { "kind" => "named", "label" => "Dvorovi", "place_id" => "komsiluk-45", "at" => @context.now.to_f }
          )
          ConversationMemory.stub(:enabled?, true) do
            result = @coordinator.call(message: citizen_message("Koje mjesto sam navela kao svoju trenutnu lokaciju?"), context: @context)
            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "Dvorovi"
            assert_empty @requests
            assert_equal "Dvorovi", @store.state.dig(Dialogue::ConversationSlots::KEY, "location", "label")
          end
        end

        test "consented location survives frame expiry and renews on citizen activity" do
          at = @context.now
          payload = { latitude: 44.758, longitude: 19.216, accuracy: 15, purpose: "current_location",
                      consent: true, provenance: "browser_geolocation", retain_for_conversation: true }
          message = Decidim::Bih::Concierge::WebMessage.new("odavde do Janje", location: payload)
          later = Dialogue::Contracts::TrustedContext.new(organization_id: 19, actor_id: nil,
                                                          conversation_key: "a" * 64, capabilities: %w(public_reads report_guidance),
                                                          now: at + 29.minutes)
          @responses << answer << answer("Provjeravam.")

          ConversationMemory.stub(:enabled?, true) do
            ConversationMemory.stub(:exact_enabled?, true) do
              @coordinator.call(message:, context: @context)
              assert_equal "exact", @store.state.dig(Dialogue::ConversationSlots::KEY, "location", "kind")
              refute_includes JSON.generate(@store.state[Dialogue::ConversationSlots::KEY]), '"latitude"'
              @coordinator.call(message: citizen_message("I dalje odavde?"), context: later)
              assert_equal at.to_f + 59.minutes, @store.state.fetch("expires_at")
              assert_equal "exact", Dialogue::StateStore.new.validate(
                context: later.with(now: at + 45.minutes), state: @store.state
              ).dig(Dialogue::ConversationSlots::KEY, "location", "kind")
              assert_raises(Dialogue::Contracts::Invalid) do
                Dialogue::StateStore.new.validate(context: later.with(now: at + 60.minutes), state: @store.state)
              end
              refute_includes JSON.generate(@requests), '"latitude"'
            end
          end
        end

        test "public pair is retained once and delivered correction is last in model context" do
          @responses << answer << answer("Koje polazište želiš?")
          first = @coordinator.call(message: citizen_message("Do Janje 16.9.2026."), context: @context)
          assert_equal "clarification", first.resolution
          assert_equal 0, first.state["version"], "handoff result uses pre-CAS version"
          assert_equal 1, @store.state["version"], "durable state advances exactly once"
          frame = @store.state.fetch(Dialogue::ConversationFrame::KEY)
          assert_equal 1, frame["history"].size
          assert_empty frame.fetch("constraints")
          @coordinator.call(message: citizen_message("Ipak do Dvorova."), context: @context)
          assert_equal 2, @store.state.dig(Dialogue::ConversationFrame::KEY, "history").size
          assert_equal "Ipak do Dvorova.", @requests.last[:contents].last.dig("parts", 0, "text")
          assert_includes JSON.generate(@requests.last[:contents]), "16.9.2026."
        end

        test "validated public subject survives a later composition failure" do
          previous = ENV["MILICA_CONVERSATION_SLOTS_ENABLED"]
          ENV["MILICA_CONVERSATION_SLOTS_ENABLED"] = "1"
          read = { "name" => "read_procedure", "args" => { "key" => "parking-permit" }, "id" => "read1" }
          @responses << OpenStruct.new(function_calls: [read], content: { "role" => "model", "parts" => [{ "functionCall" => read }] },
                                       finish_reason: "STOP", usage: {})
          @responses << OpenStruct.new(function_calls: [], content: { "role" => "model", "parts" => [{ "text" => "invalid" }] },
                                       structured: { "kind" => "answer", "answer" => "Unsupported assertion", "evidence_ids" => [] },
                                       finish_reason: "STOP", usage: {})
          registry = Dialogue::ReadToolRegistry.new(definitions: [{ "name" => "read_procedure", "description" => "Public procedure",
            "parameters" => { "type" => "object", "properties" => { "key" => { "type" => "string", "maxLength" => 160 } }, "required" => ["key"], "additionalProperties" => false },
            "handler" => lambda { |**|
              Dialogue::EvidenceEnvelope.new(organization_id: 19, registry_epoch: "r1", status: "ok",
                                             evidence: [{ "id" => "r1", "document_id" => "procedure:parking-permit", "revision" => "v1", "text" => "Procedure" }])
            } }])
          tools = OpenStruct.new(registry:, eligibility: ->(**) { true })
          tools.define_singleton_method(:initial_evidence) { |**| [] }
          @coordinator = ModelLedCoordinator.new(
            organization: @organization, client: @client, tools_factory: ->(**) { tools },
            workflow: @workflow, state_store: @store, runtime: @runtime,
            accounting_factory: -> { ->(**, &block) { block.call } },
            execution_mode: "fixed", prefetch_guidance: false
          )
          result = @coordinator.call(message: citizen_message("Kako do parking dozvole?"), context: @context)
          assert_equal "busy", result.resolution
          assert_includes @store.state.dig(Dialogue::ConversationSlots::KEY, "subjects"),
                          { "kind" => "read_procedure", "id" => "parking-permit" }
        ensure
          ENV["MILICA_CONVERSATION_SLOTS_ENABLED"] = previous
        end

        test "legacy ordinary public task is retired without promoting its old slots into model history" do
          @store.state.merge!("active_task" => "ask_information", "topic" => "transport", "pending_slot" => "stop",
                              "entities" => { "query" => "legacy source text must not enter public history" }, "entity_provenance" => { "query" => "citizen" })
          @responses << answer("Sa kojeg stajališta ideš?") << answer("Do kojeg odredišta?")
          first = @coordinator.call(message: citizen_message("Idem do Janje."), context: @context)
          assert_equal "clarification", first.resolution
          assert_nil @store.state["active_task"]
          assert_nil @store.state["pending_slot"]
          assert_empty @store.state["entities"]
          assert_equal 1, @store.state.dig(Dialogue::ConversationFrame::KEY, "history").size
          @coordinator.call(message: citizen_message("Krećem sa NAS."), context: @context)
          assert_includes JSON.generate(@requests.last[:contents]), "Idem do Janje."
          assert_not_includes JSON.generate(@requests), "legacy source text"
          assert_equal 2, @store.writes
          assert_equal 2, @store.state["version"]
        end

        test "legacy private topic and pending protected task are not converted into public history" do
          [%w(ask_information account), %w(report_problem report), %w(registration account), %w(neighborhood_information neighborhood)].each do |task, topic|
            @store.reset(@context)
            @store.state.merge!("active_task" => task, "topic" => topic,
                                "entities" => { "query" => "private retained context" }, "entity_provenance" => { "query" => "citizen" })
            @responses << answer("Koji javni podatak želiš?")
            result = @coordinator.call(message: citizen_message("Javni parking?"), context: @context)
            assert_equal "clarification", result.resolution
            assert_equal task, @store.state["active_task"]
            assert_equal "private retained context", @store.state.dig("entities", "query")
            assert_empty @store.state.dig(Dialogue::ConversationFrame::KEY, "history")
            assert_not_includes JSON.generate(@requests.last), "private retained context"
          end
        end

        test "ordinary task carrying an opaque draft is preserved without putting its reference into the prompt" do
          draft = { "reference" => "private_draft_reference_123", "revision" => 2, "expires_at" => @context.now.to_f + 600 }
          @store.state.merge!("active_task" => "ask_information", "topic" => "parking", "draft" => draft)
          @responses << answer("Koju parking zonu želiš?")
          result = @coordinator.call(message: citizen_message("Parking?"), context: @context)
          assert_equal "clarification", result.resolution
          assert_equal draft, @store.state["draft"]
          assert_empty @store.state.dig(Dialogue::ConversationFrame::KEY, "history")
          assert_not_includes JSON.generate(@requests.last), draft.fetch("reference")
        end

        test "ordinary task with suspended protected work preserves it and does not export its context" do
          suspended = @store.state.slice(*Dialogue::StateStore::TASK_KEYS).merge(
            "active_task" => "report_problem", "topic" => "report", "pending_slot" => "area_query",
            "entities" => { "description" => "private unfinished report detail" }, "entity_provenance" => { "description" => "citizen" }
          )
          @store.state.merge!("active_task" => "ask_information", "topic" => "parking", "suspended_task" => suspended)
          @responses << answer("Koju parking zonu želiš?")
          result = @coordinator.call(message: citizen_message("Parking?"), context: @context)
          assert_equal "clarification", result.resolution
          assert_equal suspended, @store.state["suspended_task"]
          assert_empty @store.state.dig(Dialogue::ConversationFrame::KEY, "history")
          assert_not_includes JSON.generate(@requests.last), "private unfinished report detail"
        end

        test "private result and citizen private question never enter subsequent public composition" do
          call = { "name" => "read_own_information", "args" => { "kind" => "balance" } }
          @responses << OpenStruct.new(function_calls: [call], content: { "role" => "model", "parts" => [{ "functionCall" => call }] }, finish_reason: "STOP", usage: {})
          @workflow.define_singleton_method(:call) do |request:, state:, **|
            raise "wrong protected selection" unless request["name"] == "read_own_information"

            reply = Decidim::Bih::Concierge::Responder::Reply.new(text: "Private balance 91735", report: nil, answer_intent: "goodwill")
            Dialogue::ProcedureRunner::Result.new(state:, reply:, resolution: "answered", fact_ids: [], handoff_offered: false, handoff_completed: false)
          end
          result = @coordinator.call(message: citizen_message("Moji privatni bodovi?"), context: @context)
          assert_equal "Private balance 91735", result.reply.text
          assert_equal 1, @requests.size
          assert_empty @store.state.dig(Dialogue::ConversationFrame::KEY, "history")
          @responses << answer
          @coordinator.call(message: citizen_message("Autobus za Janju?"), context: @context)
          assert_not_includes JSON.generate(@requests.last), "91735"
          assert_not_includes JSON.generate(@requests.last), "Moji privatni"
        end

        test "conflicting state update never delivers uncommitted answer" do
          @store.conflict = true
          @responses << answer("Specific reply")
          result = @coordinator.call(message: citizen_message("Autobus?"), context: @context)
          assert_equal "busy", result.resolution
          assert_not_equal "Specific reply", result.reply.text
          assert_equal 0, @store.writes
        end

        test "emergency contact followup retains the service without a provider call" do
          first = @coordinator.call(message: citizen_message("Gori podrum zgrade!"), context: @context)
          assert_equal "safety_guidance", first.resolution
          assert_includes first.reply.text, "123"
          second = @coordinator.call(message: citizen_message("Koga da zovem odmah?"), context: @context)
          assert_equal "safety_guidance", second.resolution
          assert_includes second.reply.text, "123"
          assert_empty @requests
          @responses << answer
          @coordinator.call(message: citizen_message("Kada ide autobus za Janju?"), context: @context)
          assert_nil @store.state[Dialogue::StateStore::SAFETY_CONTEXT_KEY]
        end

        test "consented location keeps the public request but excludes coordinates and derived reply from history" do
          input = Decidim::Bih::Concierge::WebMessage.new("Stajalište odavde?", trusted_context: @context,
                                                                                location: { latitude: 44.7561, longitude: 19.2144, consent: true,
                                                                                            purpose: "current_location", provenance: "browser_geolocation" })
          @responses << answer
          @coordinator.call(message: input, context: @context)
          assert_not_includes @requests.last[:system_instruction], "44.7561"
          history = @store.state.dig(Dialogue::ConversationFrame::KEY, "history")
          assert_equal(["Stajalište odavde?"], history.map { |entry| entry.fetch("message") })
          assert_not_includes JSON.generate(history), "44.7561"
          assert_not_includes JSON.generate(history), "19.2144"
          assert_not_includes JSON.generate(history), "Koje stajalište želiš?"
          @responses << answer
          @coordinator.call(message: citizen_message("A za Janju?"), context: @context)
          assert_not_includes JSON.generate(@requests.last), "44.7561"
          assert_not_includes JSON.generate(@requests.last), "19.2144"
        end

        test "foreign organization cannot call provider" do
          foreign = @context.with(organization_id: 20)
          result = @coordinator.call(message: citizen_message("Autobus?"), context: foreign)
          assert_equal "busy", result.resolution
          assert_empty @requests
        end

        test "trusted local clock and current correction are provided without rewriting dates or retaining old parser slots" do
          @context = @context.with(now: Time.utc(2026, 9, 16, 23, 30))
          @store.state.replace(Dialogue::StateStore.new.empty_state(@context))
          prior = Dialogue::ConversationFrame.empty(context: @context).append(message: "Polazak 17.9, povratak 19.9.2026.", answer: "Koje stajalište?", context: @context,
                                                                              constraints: { "date" => "2026-09-17", "time" => "06:00" })
          @store.state[Dialogue::ConversationFrame::KEY] = prior.value
          @responses << answer("Koje polazište želiš za povratak?")
          result = @coordinator.call(message: citizen_message("Povratak ipak 20.9; polazak ostaje 17.9."), context: @context)
          assert_equal "clarification", result.resolution
          assert_equal "Povratak ipak 20.9; polazak ostaje 17.9.", @requests.last[:contents].last.dig("parts", 0, "text")
          assert_includes JSON.generate(@requests.last[:contents]), "povratak 19.9.2026."
          assert_includes @requests.last[:system_instruction], "2026-09-17T01:30:00+02:00"
          assert_includes @requests.last[:system_instruction], "timezone: Europe/Sarajevo"
          assert_not_includes @requests.last[:system_instruction], '"date":"2026-09-17"'
          assert_empty @store.state.dig(Dialogue::ConversationFrame::KEY, "constraints")
        end

        test "public provider English Cyrillic and mixed wording is preserved without Ruby transliteration" do
          {
            "Please answer in English." => "Which stop would you like?",
            "Напиши ћирилицом." => "Које стајалиште желите?",
            "Напиши ћирилицом, али сачувај назив NAS." => "Крените ка NAS — map label: Dvorovi."
          }.each do |question, text|
            @responses << answer(text)
            result = @coordinator.call(message: citizen_message(question), context: @context)
            assert_equal text, result.reply.text
            assert_includes @requests.last[:system_instruction], "izričit izbor građanina ima prednost nad jezikom interfejsa"
            assert_equal question, @requests.last[:contents].last.dig("parts", 0, "text")
          end
        end

        test "Latin-only ordinary prose is repaired for an explicit Cyrillic request" do
          @responses << answer("Koje stajalište želiš?")
          result = @coordinator.call(message: citizen_message("Напиши ћирилицом."), context: @context)
          assert_equal "Које стајалиште желиш?", result.reply.text
        end

        test "already verified Cyrillic text keeps canonical Latin route codes" do
          @responses << answer
          rendered = VerifiedAnswerRenderer::Rendered.new(text: "Полазак P12 у 11:30.", reason: "validated_claims", claim_count: 1)
          renderer = Object.new
          renderer.define_singleton_method(:call) { |**| rendered }
          VerifiedAnswerRenderer.stub(:new, -> { renderer }) do
            result = @coordinator.call(message: citizen_message("Напиши ћирилицом."), context: @context)
            assert_equal "Полазак P12 у 11:30.", result.reply.text
          end
        end

        test "a selected return-date tool argument is not rewritten to an earlier outward date" do
          received = []
          registry = Dialogue::ReadToolRegistry.new(definitions: [{ "name" => "read_day", "description" => "Reviewed daily source",
                                                                    "parameters" => { "type" => "object", "properties" => { "date" => { "type" => "string", "maxLength" => 10 } },
                                                                                      "required" => ["date"], "additionalProperties" => false },
                                                                    "handler" => lambda { |arguments:, **|
                                                                      received << arguments
                                                                      Dialogue::EvidenceEnvelope.new(organization_id: 19, registry_epoch: "r1", status: "unsupported", evidence: [])
                                                                    } }])
          tools = OpenStruct.new(registry:, eligibility: ->(**) { true })
          tools.define_singleton_method(:initial_evidence) { |**| [] }
          coordinator = ModelLedCoordinator.new(organization: @organization, client: @client, tools_factory: ->(**) { tools }, workflow: @workflow,
                                                state_store: @store, runtime: @runtime, accounting_factory: -> { ->(**, &block) { block.call } })
          call = { "name" => "read_day", "args" => { "date" => "2026-09-21" } }
          @responses << OpenStruct.new(function_calls: [call], content: { "role" => "model", "parts" => [{ "functionCall" => call }] }, finish_reason: "STOP", usage: {})
          @responses << answer("Koju povratnu stanicu želiš provjeriti?")
          result = coordinator.call(message: citizen_message("Polazak 18.9, povratak 21.9.2026. Provjeri povratak."), context: @context)
          assert_equal "clarification", result.resolution
          assert_equal [{ "date" => "2026-09-21" }], received
          assert_equal 2, @requests.size
        end
      end
    end
  end
end
