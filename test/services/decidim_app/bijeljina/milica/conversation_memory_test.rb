# frozen_string_literal: true

require "test_helper"
require "json"
require "base64"

module DecidimApp
  module Bijeljina
    module Milica
      class ConversationMemoryTest < ActiveSupport::TestCase
        Dialogue = Decidim::Bih::Concierge::Dialogue

        class FakeEncryptor
          def encrypt_and_sign(value, purpose:)
            Base64.strict_encode64(JSON.generate({ "purpose" => purpose, "value" => value }))
          end

          def decrypt_and_verify(ciphertext, purpose:)
            decoded = JSON.parse(Base64.strict_decode64(ciphertext))
            raise "wrong scope" unless decoded.fetch("purpose") == purpose

            decoded.fetch("value")
          end
        end

        def context(at:, actor: nil)
          Dialogue::Contracts::TrustedContext.new(organization_id: 19, actor_id: actor, conversation_key: "a" * 64, now: at)
        end

        def with_flags
          previous = %w(MILICA_CONVERSATION_SLOTS_ENABLED MILICA_CONVERSATION_LOCATION_ENABLED).to_h { |key| [key, ENV[key]] }
          ENV["MILICA_CONVERSATION_SLOTS_ENABLED"] = "1"
          ENV["MILICA_CONVERSATION_LOCATION_ENABLED"] = "1"
          yield
        ensure
          previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        end

        test "exact location is consented, scoped and never projected as coordinates" do
          with_flags do
            at = Time.utc(2026, 9, 25, 12)
            scope = context(at:)
            memory = ConversationMemory.new(organization: Struct.new(:id).new(19), encryptor: FakeEncryptor.new)
            state = Dialogue::StateStore.new.empty_state(scope)
            location = { latitude: 44.758, longitude: 19.216, accuracy: 15, purpose: "current_location", consent: true,
                         provenance: "browser_geolocation", retain_for_conversation: true }
            message = Decidim::Bih::Concierge::WebMessage.new("odavde do Janje", location:)

            changed = memory.apply_turn(state:, message:, context: scope)
            slot = changed.fetch(Dialogue::ConversationSlots::KEY)
            assert_equal "exact", slot.dig("location", "kind")
            refute_includes JSON.generate(slot), '"latitude"'
            assert_equal 44.758, memory.exact_location_for(state: changed, context: scope).fetch(:latitude)
            refute_includes JSON.generate(memory.public_context(state: changed, context: scope)), '"latitude"'
            assert_nil memory.exact_location_for(state: changed, context: context(at:, actor: 8))
          end
        end

        test "first-person current place replaces active place while a route origin remains request-scoped" do
          at = Time.utc(2026, 9, 25, 12)
          scope = context(at:)
          memory = ConversationMemory.new(organization: Struct.new(:id).new(19), encryptor: FakeEncryptor.new)
          state = Dialogue::StateStore.new.empty_state(scope)
          place = Struct.new(:id, :label).new("komsiluk-janja", "Janja")
          resolved = Struct.new(:status, :places).new(:ok, [place])
          matcher = Object.new
          matcher.define_singleton_method(:resolve_place) { |**| resolved }

          CityServiceAreaMatcher.stub(:new, matcher) do
            named = memory.apply_turn(state:, message: Decidim::Bih::Concierge::WebMessage.new("Sad sam u Janji."), context: scope)
            assert_equal "Janja", named.dig(Dialogue::ConversationSlots::KEY, "location", "label")
            route = memory.apply_turn(state: named, message: Decidim::Bih::Concierge::WebMessage.new("Kreni iz Janje"), context: scope)
            assert_equal "Janja", route.dig(Dialogue::ConversationSlots::KEY, "location", "label")
            assert_equal "Janje", route.dig(Dialogue::ConversationSlots::KEY, "journey", "origin_query")
            corrected = memory.apply_turn(state: route, message: Decidim::Bih::Concierge::WebMessage.new("Mislila sam na Dvorovi (škola)."), context: scope)
            assert_equal "Dvorovi (škola)", corrected.dig(Dialogue::ConversationSlots::KEY, "journey", "origin_query")
            assert_equal "Janja", corrected.dig(Dialogue::ConversationSlots::KEY, "location", "label")
            assert memory.request_only_named_origin?("Kreni iz Janje do Dvorova")
            refute memory.request_only_named_origin?("Odavde do Dvorova")
            hypothetical = memory.apply_turn(state: route, message: Decidim::Bih::Concierge::WebMessage.new("Ako sam u Dvorovima..."), context: scope)
            assert_equal "Janja", hypothetical.dig(Dialogue::ConversationSlots::KEY, "location", "label")
            third_person = memory.apply_turn(state: route, message: Decidim::Bih::Concierge::WebMessage.new("Sestra živi u Dvorovima."), context: scope)
            assert_equal "Janja", third_person.dig(Dialogue::ConversationSlots::KEY, "location", "label")
            unrelated = memory.apply_turn(state: route, message: Decidim::Bih::Concierge::WebMessage.new("Račun iz 2027. je ispravan."), context: scope)
            assert_equal route.dig(Dialogue::ConversationSlots::KEY, "journey"), unrelated.dig(Dialogue::ConversationSlots::KEY, "journey")
          end
        end

        test "a named settlement and identically named MZ retain the shared place without merging different names" do
          at = Time.utc(2026, 9, 25, 12)
          scope = context(at:)
          memory = ConversationMemory.new(organization: Struct.new(:id).new(19), encryptor: FakeEncryptor.new)
          base = Dialogue::StateStore.new.empty_state(scope)
          place = Struct.new(:id, :label)
          shared = [place.new("komsiluk-45", "Dvorovi"), place.new("mz-dvorovi", "MZ Dvorovi")]
          matcher = Object.new
          matcher.define_singleton_method(:resolve_place) { |**| Struct.new(:status, :places).new(:ambiguous, shared) }

          CityServiceAreaMatcher.stub(:new, matcher) do
            retained = memory.apply_turn(state: base, message: Decidim::Bih::Concierge::WebMessage.new("Trenutno sam u Dvorovima."), context: scope)
            assert_equal "Dvorovi", retained.dig(Dialogue::ConversationSlots::KEY, "location", "label")
            assert_equal "komsiluk-45", retained.dig(Dialogue::ConversationSlots::KEY, "location", "place_id")

            shared << place.new("komsiluk-46", "Drugi Dvorovi")
            rejected = memory.apply_turn(state: base, message: Decidim::Bih::Concierge::WebMessage.new("Trenutno sam u Dvorovima."), context: scope)
            assert_nil rejected.dig(Dialogue::ConversationSlots::KEY, "location")
          end
        end

        test "only a selected eligible notice becomes the retained subject" do
          at = Time.utc(2026, 9, 25, 12)
          scope = context(at:)
          state = Dialogue::StateStore.new.empty_state(scope)
          memory = ConversationMemory.new(organization: Struct.new(:id).new(19), encryptor: FakeEncryptor.new)
          records = [140, 148].map do |id|
            { "id" => "record-#{id}", "document_id" => "city_event:#{id}",
              "facts" => { "source_fact" => { "kind" => "city_service_event", "id" => id } } }
          end
          evidence = [{ "status" => "ok", "evidence" => records }]
          changed = memory.apply_selected_subjects(state:, evidence:, selected_ids: ["record-140"], context: scope)

          assert_equal [{ "kind" => "city_service_event", "id" => "city_event:140" }],
                       changed.dig(Dialogue::ConversationSlots::KEY, "subjects")
          refute_includes JSON.generate(changed[Dialogue::ConversationSlots::KEY]), "148"
          assert_equal state, memory.apply_selected_subjects(state:, evidence:, selected_ids: ["record-999"], context: scope)
        end

        test "corrupt, wrong-key, and disabled exact points are dropped before inactivity renewal" do
          with_flags do
            at = Time.utc(2026, 9, 25, 12)
            scope = context(at:)
            memory = ConversationMemory.new(organization: Struct.new(:id).new(19), encryptor: FakeEncryptor.new)
            base = Dialogue::StateStore.new.empty_state(scope)
            message = Decidim::Bih::Concierge::WebMessage.new("Hvala")
            wrong_key = Base64.strict_encode64(JSON.generate({ "purpose" => "old-key",
              "value" => { "latitude" => 44.7, "longitude" => 19.2, "accuracy" => 12 } }))

            ["corrupt-token", wrong_key].each do |ciphertext|
              state = base.merge(Dialogue::ConversationSlots::KEY => Dialogue::ConversationSlots.empty.merge(
                "location" => { "kind" => "exact", "ciphertext" => ciphertext, "at" => at.to_f - 60,
                                "expires_at" => at.to_f + 60 }
              ))
              changed = memory.apply_turn(state:, message:, context: scope)
              assert_nil changed.dig(Dialogue::ConversationSlots::KEY, "location")
              reply = Decidim::Bih::Concierge::Responder::Reply.new(text: "OK", report: nil)
              result = Dialogue::ProcedureRunner::Result.new(state: changed, reply:, resolution: "answered", fact_ids: [],
                                                              handoff_offered: false, handoff_completed: false)
              reply.define_singleton_method(:dialogue_outcome) { result }
              assert_equal "inactive", Decidim::Bih::Concierge::WebChatController.new.send(:location_memory_state, reply)
            end

            valid = FakeEncryptor.new.encrypt_and_sign({ "latitude" => 44.7, "longitude" => 19.2, "accuracy" => 12 },
                                                       purpose: memory.send(:scope, scope))
            state = base.merge(Dialogue::ConversationSlots::KEY => Dialogue::ConversationSlots.empty.merge(
              "location" => { "kind" => "exact", "ciphertext" => valid, "at" => at.to_f - 60,
                              "expires_at" => at.to_f + 60 }
            ))
            ENV["MILICA_CONVERSATION_LOCATION_ENABLED"] = "0"
            assert_nil memory.apply_turn(state:, message:, context: scope).dig(Dialogue::ConversationSlots::KEY, "location")
          end
        end

        test "unconsented point cannot be saved and forget clears only location" do
          with_flags do
            at = Time.utc(2026, 9, 25, 12)
            scope = context(at:)
            memory = ConversationMemory.new(organization: Struct.new(:id).new(19), encryptor: FakeEncryptor.new)
            state = Dialogue::StateStore.new.empty_state(scope)
            location = { latitude: 44.7, longitude: 19.2, purpose: "current_location", consent: true,
                         provenance: "browser_geolocation" }
            unconsented = Decidim::Bih::Concierge::WebMessage.new("odavde", location:)
            assert_nil memory.apply_turn(state:, message: unconsented, context: scope).dig(Dialogue::ConversationSlots::KEY, "location")

            original = state.merge(Dialogue::ConversationSlots::KEY => Dialogue::ConversationSlots.empty.merge(
              "location" => { "kind" => "named", "label" => "Janja", "place_id" => "komsiluk-janja", "at" => at.to_f },
              "subjects" => [{ "kind" => "read_procedure", "id" => "registration" }]
            ))
            forgotten = memory.apply_turn(state: original, message: Decidim::Bih::Concierge::WebMessage.new("zaboravi moju lokaciju"), context: scope)
            assert_nil forgotten.dig(Dialogue::ConversationSlots::KEY, "location")
            forgotten_cyrillic = memory.apply_turn(state: original, message: Decidim::Bih::Concierge::WebMessage.new("заборави моју локацију"), context: scope)
            assert_nil forgotten_cyrillic.dig(Dialogue::ConversationSlots::KEY, "location")
            assert_equal original.dig(Dialogue::ConversationSlots::KEY, "subjects"), forgotten.dig(Dialogue::ConversationSlots::KEY, "subjects")
          end
        end
      end
    end
  end
end
