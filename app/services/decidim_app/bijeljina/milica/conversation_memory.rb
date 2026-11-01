# frozen_string_literal: true

require "digest"
require "json"
require "active_support/message_encryptor"
require_relative "exact_route_question"

module DecidimApp
  module Bijeljina
    module Milica
      # Host policy for the optional bounded slot in the dialogue state. The
      # engine validates shape; this class decides what citizen input may enter.
      class ConversationMemory
        Dialogue = Decidim::Bih::Concierge::Dialogue
        Slots = Dialogue::ConversationSlots
        PURPOSE = "bijeljina:milica:conversation-location:v1"
        ADDRESS_PURPOSE = "bijeljina:milica:typed-address:v1"
        FORGET = /\A(?:zaboravi|obrisi|obriši|forget|заборави|уклони|обриши)\s+(?:moju |moju trenutnu |my |моју )?(?:lokaciju|location|локацију)\b/i
        NAMED = /\A(?:(?:ja sam|sad sam|sada sam|trenutno sam|upravo sam|nalazim se|živim|zivim|preselio sam se|preselila sam se|i am|i live|i am now|i moved|i am located|ја сам|сад сам|сада сам|тренутно сам|налазим се|живим|преселио сам се|преселила сам се)\s+(?:u|na|in|to|у|на)|(?:moja lokacija je|my location is|моја локација је))\s+(.{2,120}?)\s*[.!?]?\z/i
        # A location must be an explicit first-person current-location statement.
        # Capture only its first clause so a following question is not stored as
        # part of the place. Quoted, conditional and route-only origins do not
        # match this anchored grammar.
        LOCATION_CLAUSE = /\A(?:(?:ja sam|sad sam|sada sam|trenutno sam|upravo sam|nalazim se|ja se nalazim|trenutno se nalazim|živim|zivim|preselio sam se|preselila sam se|i am|i live|i am now|i moved|i am located|ја сам|сад сам|сада сам|тренутно сам|налазим се|живим|преселио сам се|преселила сам се)\s+(?:u|na|in|to|у|на)|(?:moja lokacija je|moja adresa je|my location is|my address is|моја локација је|моја адреса је|lokacija|adresa|location|address)\s*:?)\s+((?:ul\.|[^,;.!?\n]){2,120})(?=\s*(?:[,;.!?]|\z))/i
        EXACT_CONTEXT = %w(current_location).freeze
        JOURNEY_INTENT = /\b(?:autobus\w*|bus|stajališt\w*|stanic\w*|polazim|krećem|krecem|putujem|idem|kreni|odavde|presjed\w*|presed\w*|journey|travel)\b|\b(?:od|iz|from)\b.{2,80}\b(?:do|prema|to)\b/i
        JOURNEY_FOLLOWUP = /\A(?:do|za|prema|ipak\s+do|kreni\s+iz|polazim\s+iz|polazim\s+od)\s+/i
        JOURNEY_CORRECTION = /\A(?:ipak|ne\s+nego)\s+(?:sutra|danas|preksutra|u\s+\d|oko\s+\d|\d{1,2}[.]|\d{1,2}:\d{2})/i
        JOURNEY_READS = %w(plan_journey resolve_and_plan_journey plan_journey_from_current_location).freeze
        SUBJECT_KEYS = {
          "read_procedure" => "key", "read_directory" => "key", "read_platform_guidance" => "subject",
          "read_foundation" => "facet", "read_reference" => "source", "read_public_notice" => "source"
        }.freeze
        # Evict old journey details after subjects when a newly supplied place
        # would otherwise exceed the engine's bounded slot. Current-turn fields
        # are kept until all unchanged fields have been considered.
        JOURNEY_EVICTION_ORDER = %w(via_id via_query origin_id destination_id route_code query_kind origin_query destination_query date time).freeze

        def initialize(organization:, encryptor: nil)
          @organization = organization
          @encryptor = encryptor
        end

        def self.enabled?
          ENV["MILICA_CONVERSATION_SLOTS_ENABLED"] == "1"
        end

        def self.exact_enabled?
          enabled? && ENV["MILICA_CONVERSATION_LOCATION_ENABLED"] == "1"
        end

        def self.typed_address_enabled?
          exact_enabled? && ENV["MILICA_TYPED_ADDRESS_ENABLED"] == "1"
        end

        def forget?(message)
          message.text.to_s.strip.match?(FORGET)
        end

        def named_location_statement?(text)
          text.to_s.strip.match?(NAMED)
        end

        def typed_location_statement?(text)
          !location_phrase(text).nil?
        end

        def standalone_typed_location_statement?(text)
          input = text.to_s.strip
          match = LOCATION_CLAUSE.match(input)
          match && input[match.end(0)..].to_s.match?(/\A\s*[.!?]?\z/)
        end

        def typed_location_saved?(state:, message:, context:)
          return true unless self.class.typed_address_enabled? && typed_location_statement?(message.text)

          place = state.dig(Slots::KEY, "location")
          return false unless place.is_a?(Hash) && place["at"] == context.now.to_f

          phrase = location_phrase(message.text)
          case place["kind"]
          when "named" then named_location(message.text.to_s, context:)&.dig("place_id") == place["place_id"]
          when "address" then private_location_for(state:, context:) == phrase
          when "exact" then exact_share_saved?(state:, message:, context:)
          else false
          end
        end

        # An explicit named boarding origin belongs to this request. It must
        # not be silently replaced by the retained GPS point in a tool call.
        def request_only_named_origin?(text)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          origin = latin.match(/\b(?:od|iz|from)\s+([^.!?]{2,80}?)\s+(?:do|prema|to)\b/i)&.[](1)
          origin ||= latin.match(/\A(?:kreni|polazim|krećem|krecem)\s+(?:od|iz)\s+([^.!?]{2,80})/i)&.[](1)
          origin ||= latin.match(/\b(?:stajal\w*|stanic\w*|stop)\s+(?:od|iz|from)\s+([^.!?]{2,80})/i)&.[](1)
          origin.present? && !deictic_origin_phrase?(origin)
        end

        # References to the point already shared are not new named origins.
        # The current-point reader must retain its server-bound coordinates.
        def transport_question?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          folded.match?(/\b(?:autobus\w*|bus|stajal\w*|stanic\w*|stop|polaz\w*|put\w*|rout\w*)\b/)
        end

        def private_origin_journey?(text)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          has_origin = deictic_origin?(text) || folded.match?(/\b(?:moje|moju|my)\s+(?:lokacije|lokaciju|location)\b/) ||
                       folded.match?(/\b(?:najbliz\w*|nearest)\b.*\b(?:stajal\w*|stanic\w*|stop)\b/)
          has_origin && folded.match?(/\b(?:autobus\w*|bus|stajal\w*|stanic\w*|stop|put\w*|kren\w*|polaz\w*)\b/)
        end

        def deictic_origin?(text)
          latin = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(text.to_s))
          latin.match?(/\b(?:odavde|ovdje|ovde|from here)\b/) ||
            latin.match?(/\b(?:od|iz|sa|s|from)\s+(?:iste|istog|te|tog|ove|ovog|same|this|that)\s+(?:tacke|lokacije|mjesta|mesta|point|location|place)\b/)
        end

        def apply_turn(state:, message:, context:)
          slots = (state[Slots::KEY] || Slots.empty).deep_dup
          exact_requested = !forget?(message) && exact_share_requested?(message)
          typed_requested = self.class.typed_address_enabled? && !forget?(message) && typed_location_statement?(message.text)
          previous_journey = slots["journey"]
          # A key change, corrupt token, or disabled exact-location feature
          # makes the optional point unusable. Clear it before renewing TTL.
          if slots.dig("location", "kind") == "exact" && !exact_location_for(state:, context:) ||
             slots.dig("location", "kind") == "address" && !private_location_for(state:, context:)
            slots["location"] = nil
          end
          stale_exact = stale_exact_share?(state:, message:, context:)
          if forget?(message)
            slots["location"] = nil
          else
            named = named_location(message.text.to_s, context:)
            slots["location"] = named if named
            private_place = encrypted_typed_location(message.text.to_s, context:) if typed_requested && !named
            slots["location"] = private_place if private_place
            exact = exact_location(message, context:) unless stale_exact
            slots["location"] = exact if exact
            slots["location"] = nil if exact_requested && !exact && !stale_exact
            slots["location"] = nil if typed_requested && !named && !private_place && !exact
          end
          journey = citizen_journey_delta(message.text.to_s, previous: slots["journey"], context:)
          slots["journey"] = journey if journey
          script = script_preference(message.text.to_s)
          slots["script"] = script if script
          slots["location"]["expires_at"] = context.now.to_f + Dialogue::Contracts::CONTEXT_TTL if %w(exact address).include?(slots.dig("location", "kind"))
          valid = fit_slots(slots, previous_journey:, now: context.now)
          return state.merge(Slots::KEY => valid) if valid

          if exact_requested || typed_requested
            # Do not retain an older location after a failed replacement. The
            # caller acknowledges that the new location was not saved.
            slots["location"] = nil
            slots["subjects"] = []
            slots["journey"] = nil
            return state.merge(Slots::KEY => Slots.normalize(slots, now: context.now,
              state_expires_at: context.now.to_f + Dialogue::Contracts::CONTEXT_TTL) || Slots.empty)
          end

          state
        end

        def exact_share_requested?(message)
          return false unless self.class.exact_enabled? && message.respond_to?(:location_retention_consent?) && message.location_retention_consent?

          value = if message.respond_to?(:public_read_location)
                    message.public_read_location
                  elsif message.respond_to?(:dialogue_location)
                    message.dialogue_location
                  end
          value.is_a?(Hash) && value[:consent] == true && EXACT_CONTEXT.include?(value[:purpose]) &&
            value[:latitude].is_a?(Numeric) && value[:longitude].is_a?(Numeric)
        end

        def exact_share_saved?(state:, message:, context:)
          return true unless exact_share_requested?(message)
          return true if stale_exact_share?(state:, message:, context:) && exact_location_for(state:, context:)

          requested = message.respond_to?(:public_read_location) ? message.public_read_location : message.dialogue_location
          saved = exact_location_for(state:, context:)
          saved && %i[latitude longitude accuracy].all? { |field| saved[field] == requested[field] }
        end

        # Acquisition order, rather than delivery order, decides whether an
        # incoming browser point may replace the active consented point. Older
        # clients with no acquisition timestamp cannot displace a timestamped
        # point; they may still establish a point when none is active.
        def stale_exact_share?(state:, message:, context:)
          return false unless exact_share_requested?(message)
          return false unless message.respond_to?(:location_provenance) && message.location_provenance == "browser_geolocation"

          place = state.dig(Slots::KEY, "location")
          return false unless place.is_a?(Hash) && place["kind"] == "exact" && exact_location_for(state:, context:)

          incoming = message.location_acquired_at if message.respond_to?(:location_acquired_at)
          previous = place["acquired_at"] || place["at"]
          incoming.nil? || incoming <= previous
        end

        # Only validated, successfully executed public reads can refresh a
        # subject. Never save arbitrary tool argument prose or provider text.
        def apply_reads(state:, reads:, message:, context:)
          slots = (state[Slots::KEY] || Slots.empty).deep_dup
          folded_turn = Decidim::Bih::Text.fold(message.text.to_s)
          walking_only = folded_turn.match?(/\bpjes(?:k|ac)\w*\b/) &&
            !folded_turn.match?(/\b(?:autobus\w*|bus)\b/)
          Array(reads).each do |read|
            next unless read.is_a?(Hash) && %w(ok answered).include?(read["result_status"])

            name = read["name"].to_s
            args = read["arguments"]
            next unless args.is_a?(Hash)

            if JOURNEY_READS.include?(name)
              next if walking_only

              journey = args.slice("origin_id", "destination_id", "date", "after_time", "route_code")
              journey["time"] = journey.delete("after_time") if journey.key?("after_time")
              journey["query_kind"] = name
              merged = (slots["journey"] || {}).merge(journey)
              merged.delete("destination_id") if args["destination_ids"].is_a?(Array)
              slots["journey"] = merged if Dialogue::ConversationSlots.valid_journey?(merged)
            elsif SUBJECT_KEYS.key?(name)
              id = args[SUBJECT_KEYS.fetch(name)]
              next unless Dialogue::ConversationSlots.valid_text?(id, 120)

              slots["subjects"] = ([{ "kind" => name, "id" => id }] + slots["subjects"].reject { |old| old["kind"] == name }).first(3)
            end
          end
          valid = Slots.normalize(slots, now: context.now, state_expires_at: state.fetch("expires_at"))
          valid ? state.merge(Slots::KEY => valid) : state
        end

        # A search can return several notices. Only the record selected in the
        # delivered, evidence-checked answer becomes the retained referent.
        # Store stable public identity and kind, never record text or coordinates.
        def apply_selected_subjects(state:, evidence:, selected_ids:, context:)
          chosen = Array(selected_ids).select { |id| id.is_a?(String) && id.bytesize <= 160 }.uniq.first(8)
          return state if chosen.empty?

          matches = Array(evidence).flat_map do |envelope|
            next [] unless envelope.is_a?(Hash) && %w(ok conflicting).include?(envelope["status"])

            Array(envelope["evidence"]).select { |record| record.is_a?(Hash) && chosen.include?(record["id"]) }
          end
          return state if matches.empty?

          # Duplicate citation IDs with different canonical identities are not
          # a safe referent. Answer validation should already reject this, but
          # the storage reducer independently refuses it.
          grouped = matches.group_by { |record| record["id"] }
          subjects = chosen.filter_map do |citation_id|
            records = grouped[citation_id]
            next unless records&.one?

            record = records.first
            kind = record.dig("facts", "source_fact", "kind").to_s
            kind = "public_document" unless kind.match?(/\A[a-z][a-z0-9_]{0,29}\z/)
            id = record["document_id"]
            next unless Slots.valid_text?(id, 120)

            { "kind" => kind, "id" => id }
          end.uniq
          return state if subjects.empty?

          slots = (state[Slots::KEY] || Slots.empty).deep_dup
          slots["subjects"] = (subjects + slots["subjects"]).uniq.first(3)
          valid = Slots.normalize(slots, now: context.now, state_expires_at: state.fetch("expires_at"))
          valid ? state.merge(Slots::KEY => valid) : state
        end

        def public_context(state:, context:)
          slots = state[Slots::KEY] || Slots.empty
          place = slots["location"]
          location = if place && place["kind"] == "named"
                       { kind: "named", name: place["label"], place_id: place["place_id"] }
                     elsif place && place["kind"] == "exact" && exact_location_for(state:, context:)
                       { kind: "shared_exact_point", available_to_server_tools: true }
                     elsif place && place["kind"] == "address" && private_location_for(state:, context:)
                       { kind: "private_typed_location", available_to_server_tools: false,
                         limitation: "Saved for continuity; no reviewed address-to-stop mapping. Ask for a stop only when routing requires it." }
                     end
          { active_location: location, journey: slots["journey"], subjects: slots["subjects"], script: slots["script"] }
        end

        def exact_location_for(state:, context:)
          return unless self.class.exact_enabled?

          place = state.dig(Slots::KEY, "location")
          return unless place.is_a?(Hash) && place["kind"] == "exact" && place["expires_at"] > context.now.to_f

          value = encryptor.decrypt_and_verify(place.fetch("ciphertext"), purpose: scope(context))
          return unless value.is_a?(Hash) && value.keys.sort == %w(accuracy latitude longitude)
          return unless value["latitude"].is_a?(Numeric) && value["latitude"].finite? && value["latitude"].between?(-90, 90)
          return unless value["longitude"].is_a?(Numeric) && value["longitude"].finite? && value["longitude"].between?(-180, 180)
          return unless value["accuracy"].nil? || value["accuracy"].is_a?(Numeric) && value["accuracy"].finite? && value["accuracy"].between?(0, 1_000_000)

          { latitude: value["latitude"], longitude: value["longitude"], accuracy: value["accuracy"], purpose: "current_location", consent: true,
            provenance: "retained_consent" }
        rescue StandardError
          nil # Optional ciphertext/key failure cannot invalidate public state.
        end

        def private_location_for(state:, context:)
          return unless self.class.typed_address_enabled?

          place = state.dig(Slots::KEY, "location")
          return unless place.is_a?(Hash) && place["kind"] == "address" && place["expires_at"] > context.now.to_f

          value = address_encryptor.decrypt_and_verify(place.fetch("ciphertext"), purpose: scope(context, purpose: ADDRESS_PURPOSE))
          return unless value.is_a?(Hash) && value.keys == ["text"] && valid_location_phrase?(value["text"])

          value.fetch("text")
        rescue StandardError
          nil
        end

        private

        def fit_slots(slots, previous_journey:, now:)
          state_expiry = now.to_f + Dialogue::Contracts::CONTEXT_TTL
          valid = Slots.normalize(slots, now:, state_expires_at: state_expiry)
          return valid if valid
          return unless slots["location"]

          while slots["subjects"].any?
            slots["subjects"].pop
            valid = Slots.normalize(slots, now:, state_expires_at: state_expiry)
            return valid if valid
          end

          journey = slots["journey"]
          return unless journey.is_a?(Hash)

          stale = JOURNEY_EVICTION_ORDER.select { |key| journey.key?(key) && previous_journey.is_a?(Hash) && previous_journey[key] == journey[key] }
          fresh = JOURNEY_EVICTION_ORDER.select { |key| journey.key?(key) && !stale.include?(key) }
          (stale + fresh).each do |key|
            journey.delete(key)
            slots["journey"] = nil if journey.empty?
            valid = Slots.normalize(slots, now:, state_expires_at: state_expiry)
            return valid if valid
          end
          nil
        end

        def deictic_origin_phrase?(origin)
          folded = Decidim::Bih::Text.fold(Decidim::Bih::Transliterator.to_latin(origin.to_s))
          return true if folded.match?(/\A(?:odavde|ovdje|ovde|here)\b/)
          return true if folded.match?(/\b(?:stanic\w*|stajal\w*)\b.*\b(?:koju|koje|koji)\s+si\s+(?:spomenul\w*|navel\w*)\b/)

          deictic_origin?("od #{origin}")
        end

        def named_location(text, context:)
          phrase = location_phrase(text)
          return unless phrase
          return if phrase.match?(/\d|\b(?:ulica|ulici|ulicu|ul\.?|street|adresa|address|улица|улици|улицу)\b/i)

          result = CityServiceAreaMatcher.new(organization: @organization).resolve_place(query: phrase)
          entry = if result.status == :ok && result.places.one?
                    result.places.first
                  elsif result.status == :ambiguous
                    equivalent_named_area(result.places)
                  end
          return unless entry

          { "kind" => "named", "label" => entry.label.to_s.first(120), "place_id" => entry.id.to_s.first(120), "at" => context.now.to_f }
        rescue StandardError
          nil
        end

        # A settlement and its identically named MZ are different boundaries,
        # but the citizen's current place can safely retain their shared name.
        # Prefer the non-MZ public area only when every candidate has that name;
        # genuinely different place names still need clarification.
        def equivalent_named_area(places)
          return unless places.is_a?(Array) && places.size.between?(2, 4)

          generic = places.reject { |place| Decidim::Bih::Text.fold(place.label.to_s).match?(/\Amz\s+/i) }
          return unless generic.one?

          name = PlaceAliasRegistry.normalize(PlaceAliasRegistry.display_name(generic.first.label))
          return unless places.all? do |place|
            PlaceAliasRegistry.normalize(PlaceAliasRegistry.display_name(place.label)).sub(/\Amz\s+/i, "") == name
          end

          generic.first
        end

        def citizen_journey_delta(text, previous:, context:)
          exact = ExactRouteQuestion.call(text, previous:)
          return exact.slot if exact

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          folded = Decidim::Bih::Text.fold(latin)
          # A walking detour changes the mode of this turn, not the remembered
          # bus endpoints needed if the citizen resumes that journey later.
          return if folded.match?(/\b(?:pjes\w*|hod\w*)\b/) && !folded.match?(/\b(?:autobus\w*|bus)\b/)
          # The parser may reduce "the station you mentioned" to the bare
          # noun "stanice". Keep the earlier origin for the follow-up reader.
          return if previous && folded.match?(/\b(?:stanic\w*|stajal\w*)\s+(?:koju|koje|koji)\s+si\s+(?:spomenul\w*|navel\w*)\b/)
          if previous && (correction = latin.match(/\A(?:ne[,!]?\s+)?(?:polazim|krećem|krecem)\s+(?:sa|s|od|iz)\s+(.{2,100}?)\s*[.!?]?\z/i))
            origin = correction[1].strip
            if public_place_phrase?(origin) && !deictic_origin_phrase?(origin)
              changed = previous.merge("origin_query" => origin, "query_kind" => "citizen_span").except("origin_id")
              return changed if Slots.valid_journey?(changed)
            end
          end
          if previous && (correction = latin.match(/\A(?:mislila|mislio) sam na (.{2,100}?)\s*[.!?]?\z/i))
            origin = correction[1].strip
            date_word = Decidim::Bih::Text.fold(origin).match?(/\A(?:ponedjeljak|ponedeljak|utorak|srijed\w*|sred\w*|cetvrtak|petak|subot\w*|nedjelj\w*|nedelj\w*|danas|sutra|preksutra)\b/)
            if !date_word && !origin.match?(/[;,]/) && public_place_phrase?(origin) && !deictic_origin_phrase?(origin)
              changed = previous.merge("origin_query" => origin, "query_kind" => "citizen_span").except("origin_id")
              return changed if Slots.valid_journey?(changed)
            end
          end
          return unless latin.match?(JOURNEY_INTENT) || latin.match?(JOURNEY_FOLLOWUP) || previous && latin.match?(JOURNEY_CORRECTION)

          selection = TransportJourneyQuestion.call({ "query" => text }, now: context.now)
          entities = selection.entities
          return unless entities.is_a?(Hash)

          delta = {}
          if (explicit_start = latin.match(/\A(?:kreni|polazim|krećem|krecem)\s+(?:od|iz)\s+(.{2,100}?)\s*[.!?]?\z/i))
            origin = explicit_start[1].strip
            delta["origin_query"] = origin if public_place_phrase?(origin) && !deictic_origin_phrase?(origin)
          end
          { "stop" => "origin_query", "area_query" => "destination_query" }.each do |from, to|
            value = entities[from].to_s.strip
            next unless public_place_phrase?(value)
            next if to == "origin_query" && deictic_origin_phrase?(value)
            # A locative phrase in an origin clarification ("sa suda u
            # Bijeljini") is not a replacement for the explicitly retained
            # destination. The parser can otherwise turn Bijeljina into the
            # endpoint despite "isti datum i odredište".
            next if to == "destination_query" && previous &&
                    folded.match?(/\bist\w*\s+datum\b/) && folded.match?(/\bodredist\w*\b/)

            delta[to] ||= value.first(120)
          end
          via = entities["via_stop"].to_s.strip
          delta["via_query"] = via.first(120) if public_place_phrase?(via)
          { "date" => "date", "time_expression" => "time", "route" => "route_code" }.each do |from, to|
            value = entities[from].to_s.strip
            delta[to] = value.first(120) if Dialogue::ConversationSlots.valid_text?(value, 120)
          end
          return if delta.empty?

          candidate = (previous || {}).merge(delta).merge("query_kind" => "citizen_span")
          candidate.delete("origin_id") if delta.key?("origin_query")
          candidate.delete("destination_id") if delta.key?("destination_query")
          candidate if Slots.valid_journey?(candidate)
        rescue StandardError
          nil
        end

        def public_place_phrase?(value)
          Slots.valid_text?(value, 120) && !value.match?(/\d|\b(?:ulica|ulici|ulicu|street|adresa|address|улица|улици|улицу)\b/i)
        end

        def exact_location(message, context:)
          return unless self.class.exact_enabled?
          return unless message.respond_to?(:location_context?) && message.location_context?
          return unless message.respond_to?(:location_retention_consent?) && message.location_retention_consent?
          return unless message.respond_to?(:public_read_location) || message.respond_to?(:dialogue_location)

          value = message.respond_to?(:public_read_location) ? message.public_read_location : message.dialogue_location
          return unless value.is_a?(Hash) && value[:consent] == true && EXACT_CONTEXT.include?(value[:purpose])
          return unless value[:latitude].is_a?(Numeric) && value[:longitude].is_a?(Numeric)

          ciphertext = encryptor.encrypt_and_sign(
            { "latitude" => value[:latitude], "longitude" => value[:longitude], "accuracy" => value[:accuracy] }, purpose: scope(context)
          )
          saved = { "kind" => "exact", "ciphertext" => ciphertext, "at" => context.now.to_f,
                    "expires_at" => context.now.to_f + Dialogue::Contracts::CONTEXT_TTL }
          acquired_at = message.location_acquired_at if message.respond_to?(:location_acquired_at)
          saved["acquired_at"] = acquired_at if acquired_at
          saved
        rescue StandardError
          nil
        end

        def location_phrase(text)
          phrase = LOCATION_CLAUSE.match(text.to_s.strip)&.[](1)&.strip
          phrase = phrase.sub(/\s+i\s+(?:idem|putujem|polazim|krećem|krecem|pita\w*|treba\w*)\b.*\z/i, "").strip if phrase
          phrase if valid_location_phrase?(phrase)
        end

        def valid_location_phrase?(phrase)
          phrase.is_a?(String) && phrase.length.between?(2, 120) && phrase.match?(/[[:alpha:]]/) &&
            !phrase.match?(%r{https?://|[\x00-\x1f]|\b(?:ako|if|suppose|pretpostavimo|and|pa|kako|treba|možeš|mozes|please|could)\b}i) &&
            !Dialogue::StateStore.sensitive_text?(phrase)
        end

        def encrypted_typed_location(text, context:)
          return unless self.class.typed_address_enabled?

          phrase = location_phrase(text)
          return unless phrase

          ciphertext = address_encryptor.encrypt_and_sign({ "text" => phrase }, purpose: scope(context, purpose: ADDRESS_PURPOSE))
          { "kind" => "address", "ciphertext" => ciphertext, "at" => context.now.to_f,
            "expires_at" => context.now.to_f + Dialogue::Contracts::CONTEXT_TTL }
        rescue StandardError
          nil
        end

        def address_encryptor
          @address_encryptor ||= ActiveSupport::MessageEncryptor.new(
            Rails.application.key_generator.generate_key(ADDRESS_PURPOSE, 32), cipher: "aes-256-gcm", serializer: JSON
          )
        end

        def script_preference(text)
          return "cyrillic" if text.match?(/(?:piši|pisi|write|пиши)\s+(?:ćirilic|cirilic|in cyrillic|ћирилиц)/i)
          return "latin" if text.match?(/(?:piši|pisi|write|пиши)\s+(?:latinic|in latin|латиниц)/i)
        end

        def encryptor
          @encryptor ||= ActiveSupport::MessageEncryptor.new(
            Rails.application.key_generator.generate_key(PURPOSE, 32), cipher: "aes-256-gcm", serializer: JSON
          )
        end

        def scope(context, purpose: PURPOSE)
          Digest::SHA256.hexdigest(JSON.generate([purpose, context.organization_id, context.actor_id, context.conversation_key]))
        end
      end
    end
  end
end
