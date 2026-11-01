# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Resolve the citizen's own journey words — origin, destination and the
      # time window — without inventing stop identities. Places stay text
      # queries for the reviewed timetable. The window is anchored to the
      # trusted clock in Europe/Sarajevo: a "next" request never looks into
      # the past, and a deliberately historical one is flagged as such.
      module TransportJourneyQuestion
        JOURNEY = /\A(?:(?:kako (?:da |mogu )?(?:stignem|dodjem|dođem|dodem|idem)|how (?:do|can) i (?:get|travel)) )?(?:od|iz|from) (?<origin>.+?) (?:do|to) (?<destination>.+)\z/i
        TIME_SUFFIX = /(?:\A|[ ])(?<time>
          (?:danas|sutra|today|tomorrow)(?:[ ](?:u|oko|at|around)[ ](?:podne|noon|\d{1,2}(?::\d{2})?))?|
          (?:u|oko|at|around)[ ](?:podne|noon|\d{1,2}(?::\d{2})?)
        )\z/ix
        NON_PLACE = /\b(?:
          od|iz|do|from|to|ili|i|and|or|ne|not|preko|via|pa|onda|kako|gdje|gde|how|where|when|
          sutra|danas|today|tomorrow|podne|noon|u|at|oko|around|prijavi|posalji|stignem|krecem|polazim|sa|
          smjer\w*|smer\w*|prelazak|prelaska|presjed\w*|presed\w*|medjugradsk\w*|drugog|drugom|odabran\w*|izabran\w*|cijena|cena|koliko|tokom|tijekom|raspust\w*|praznik\w*|autobusom|busom|autobus|autobusi|autobusa|bus
        )\b/x
        SERVICE_TIME_ZONE = "Europe/Sarajevo"
        MAX_QUERY_LENGTH = 1_000
        NUMERIC_DATE = /(?<!\d)(?:(?<year>20\d{2})-(?<month>\d{1,2})-(?<day>\d{1,2})|(?<local_day>\d{1,2})[.]\s*(?<local_month>\d{1,2})[.]\s*(?<local_year>20\d{2})[.]?)(?!\d)/
        MONTH_NUMBERS = [
          %w(januar januara januaru), %w(februar februara februaru), %w(mart marta martu),
          %w(april aprila aprilu), %w(maj maja maju), %w(jun juni juna junu), %w(jul juli jula julu),
          %w(avgust avgusta avgustu), %w(septembar septembra septembru), %w(oktobar oktobra oktobru),
          %w(novembar novembra novembru), %w(decembar decembra decembru)
        ].each_with_index.flat_map { |names, index| names.map { |name| [name, index + 1] } }.to_h.freeze
        NAMED_DATE = /(?<!\d)(?<day>\d{1,2})[.]?\s+(?<month>#{Regexp.union(MONTH_NUMBERS.keys)})\s+(?<year>20\d{2})(?!\d)/
        NEAREST_STOP = /\b(?:najbliz\w*|nearest|closest)\b.*\b(?:stajal\w*|stanic\w*|stop)\b|\b(?:stajal\w*|stanic\w*|stop)\b.*\b(?:najbliz\w*|nearest|closest)\b/
        LANDMARK = /\b(?:kod|pored|blizu|od|near|by)\s+(?<place>[^.!?;,\n]{1,80})/i
        ORIGIN_MARKERS = %w(od iz sa s from).freeze
        DESTINATION_MARKERS = %w(do za prema ka to).freeze
        # A place phrase ends at the next marker, conjunction, question word,
        # time word, vehicle word or number.
        PHRASE_STOP = (ORIGIN_MARKERS + DESTINATION_MARKERS + %w(
          u i a ili pa onda te bez uz odrediste polaziste cilj direktno samo kad kada when koliko koji koja koje kojih kojeg kojoj koju gdje gde kako sta zasto
          sutra danas preksutra jutros veceras uvece navece navecer ujutru ujutro rano popodne poslijepodne poslepodne
          after at around before noon morning afternoon evening
          poslije posle nakon iza oko prije pre podne autobus autobusi autobusa autobusom bus busa busom prevoz prijevoz prevozom linija linije
          ide idu polazi polaze krece krecu vozi voze moze mogu prvi prvo prvog put posljednji poslednji zadnji stize stizem stignem dodjem dodem idem putujem treba mi molim hvala
          presjedanje presjedanjem presedanje presedanjem transfer connecting connection
          tokom tijekom vrijeme vreme raspust raspusta praznik praznika skolski skolskog school holiday during
        )).freeze
        # "i dalje do X", "X ili Y", "pa prijavi" are compound sentences the
        # reviewed timetable must not receive as one place. "i kad" is not.
        COMPOUND = /\b(?:ili|pa|onda|te)\b|\bi\b(?! (?:kad|kada|when|u koliko|koliko))/
        CORRECTED_DESTINATION = /\A(?:(?:pogrijesio|pogresio|pogrijesila|pogresila)\s+sam\s+)?ne\s+(?:idem|putujem)\s+
                                  (?:na|u|do|za|prema|ka)\s+(?<old>.+?)\s+(?:nego|vec)\s+
                                  (?:na|u|do|za|prema|ka)\s+(?<destination>.+)\z/x
        # The current movement request, not a model-produced stop slot, owns
        # "from here". Keep the prefix bounded so negation, reported speech or
        # a different explicit origin cannot silently become device location.
        CURRENT_ORIGIN = /\A(?:(?:kako|koji|mogu|mozes|li|reci|da|stignem|dodjem|dodem|idem|ide|putujem|treba|mi|autobusom|busom|autobus|molim|te|
                                how|do|can|i|get|travel|by|bus|which|goes|please)\s+)*
                           (?:odavde|from[ ]here)\s+(?:do|za|prema|ka|to)\s/x
        CURRENT_ORIGIN_MENTION = /\b(?:odavde|from here)\b/
        AFFIRMED_ORIGIN = /\A(?:polazim|krecem|idem|putujem) (?:i dalje )?(?:od|iz|sa|s) (?<origin>.+)\z/
        LAST = /\b(?:zadnj\w*|posljednj\w*|poslednj\w*|najkasnij\w*|last)\b/
        NEXT = /\b(?:sljedec\w*|sledec\w*|naredn\w*|prv[aiou]\w*|next|kad|kada|when|u koliko|koliko sati)\b/
        HISTORICAL = /\b(?:jutros|bio|bila|bilo|prosao|prosla|proslo|ranije|earlier|was)\b/
        BEFORE = /\b(?:prije|pre|before)\s+(?:\d|podne|noon)/
        CLOCK = /
          (?<prefix>\b(?:u|oko|at|around|poslije|posle|nakon|iza|od|after|from)\s+)?
          (?<![\p{L}\d:])(?<hour>\d{1,2})(?::(?<minute>\d{2}))?(?![\d:])
          (?<suffix>\s*(?:h|c|č|sati|sat|casova|časova|casa|časa)\b)?
        /xi
        WEEKDAYS = {
          "ponedjeljak" => 1, "ponedeljak" => 1, "monday" => 1, "utorak" => 2, "tuesday" => 2, "srijeda" => 3, "sreda" => 3,
          "srijedu" => 3, "sredu" => 3, "wednesday" => 3, "cetvrtak" => 4, "thursday" => 4, "petak" => 5, "friday" => 5,
          "subota" => 6, "subotu" => 6, "subotom" => 6, "saturday" => 6, "nedjelja" => 0, "nedjelju" => 0, "nedelja" => 0,
          "nedelju" => 0, "nedjeljom" => 0, "nedeljom" => 0, "nedjeljni" => 0, "nedeljni" => 0, "nedjeljnog" => 0,
          "nedeljnog" => 0, "subotnji" => 6, "subotnjeg" => 6, "sunday" => 0
        }.freeze
        DAY_OFFSETS = {
          "preksutra" => 2, "sutra" => 1, "tomorrow" => 1, "danas" => 0, "today" => 0, "jutros" => 0, "veceras" => 0,
          "uvece" => 0, "navece" => 0, "navecer" => 0, "tonight" => 0
        }.freeze
        WORKDAY = /\b(?:radnim?\s+dan(?:om|ima)|radni\s+dan|weekday|workday)\b/
        PARTS_OF_DAY = [
          [5, /\b(?:ujutru|ujutro|jutros|rano|prijepodne|prepodne|morning)\b/],
          [12, /\b(?:popodne|poslijepodne|poslepodne|afternoon)\b/],
          [18, /\b(?:veceras|uvece|navece|navecer|vecer|evening|tonight)\b/],
          [12, /\b(?:podne|noon)\b/]
        ].freeze
        DEFAULT_OPTIONS = 1
        WHEN_OPTIONS = 2

        Selection = Data.define(:entities, :warning)
        # `strict` means "strictly after the clock" (the window starts now);
        # `historical` keeps a past window on purpose and must be said aloud;
        # `rolled_clock` moved a past clock to tomorrow; `past_clock` is the
        # HH:MM the citizen named when it had already passed.
        Window = Data.define(:earliest_after, :mode, :strict, :explicit_time, :historical, :rolled_clock, :past_clock, :requested_day, :options, :warning)

        module_function

        def call(entities, now: nil)
          raw = entities["query"].to_s
          return Selection.new(entities, "transport_query_too_long") if raw.length > MAX_QUERY_LENGTH

          query = Decidim::Bih::Transliterator.to_latin(raw).strip.sub(/[?.!]\z/, "")
          temporal = explicit_temporal_entities(entities, query, now:)
          return temporal if temporal.warning

          entities = temporal.entities
          query = query.gsub(NUMERIC_DATE, " ").gsub(NAMED_DATE, " ").squish
          return Selection.new(entities.except("stop"), "transport_origin_required") if ambiguous_current_origin?(query)

          entities = transfer_constraints(entities, query)
          entities, query = without_cancelled_via(entities, query)
          selected = resolve_journey_entities(entities, query)
          return Selection.new(selected.entities, "transport_via_required") if selected.entities["via_stop"].present? && !selected.warning

          selected
        rescue ArgumentError
          Selection.new(entities, "invalid_date")
        end

        # Narrow public seam for deterministic callers that already own place
        # extraction and only need the validated date/time interpretation. Keep
        # the lower-level parser private so callers cannot bypass the full
        # journey parser accidentally.
        def temporal_entities(entities, query, now:)
          explicit_temporal_entities(entities, query, now:)
        rescue ArgumentError
          Selection.new(entities, "invalid_date")
        end

        def resolve_journey_entities(entities, query)
          compound = compound_journey_spans(query)
          if compound
            resolved = entities.merge("stop" => compound.fetch(:origin), "area_query" => compound.fetch(:destination), "via_stop" => compound.fetch(:via))
            return Selection.new(resolved.except("route"), "transport_via_required")
          end

          match = JOURNEY.match(query)
          if match
            explicit = explicit_journey(entities, match)
            return route_constraint(explicit, query) unless explicit.warning
          end

          spans = journey_spans(query)
          return route_constraint(existing_destination(entities, query), query) unless spans

          resolved = entities.dup
          resolved["stop"] = spans[:origin] if spans[:origin]
          resolved["area_query"] = spans[:destination] if spans[:destination]
          route_constraint(existing_destination(resolved, query), query)
        end

        def ambiguous_current_origin?(query)
          folded = Decidim::Bih::Text.fold(query)
          return false unless CURRENT_ORIGIN_MENTION.match?(folded)
          return false if CURRENT_ORIGIN.match?(folded)

          # A separately named origin still owns the journey. Otherwise an
          # unknown, negated or reported "from here" phrase cannot authorize
          # either a model-origin guess or use of the trusted GPS envelope.
          explicit = marker_spans(query)&.fetch(:origin)
          explicit.nil? || %w(odavde here).include?(explicit)
        end

        def route_constraint(selection, query)
          return selection if selection.warning

          explicit_route = query.match(/\b([GP])\s*(\d{1,2})\b/i)
          return Selection.new(selection.entities.merge("route" => "#{explicit_route[1].upcase}#{explicit_route[2].to_i}"), nil) if explicit_route

          endpoint = journey_spans(query)
          connecting = Decidim::Bih::Text.fold(query).match?(/\b(?:presjed\w*|presed\w*|transfers?|connect\w*)\b/)
          endpoint || connecting ? Selection.new(selection.entities.except("route"), nil) : selection
        end

        def explicit_temporal_entities(entities, query, now:)
          date = numeric_date(query)
          date ||= relative_date(Decidim::Bih::Text.fold(query), now.in_time_zone(SERVICE_TIME_ZONE)) if now
          entities = entities.merge("date" => date.iso8601) if date
          clock = parse_clock(query)
          return Selection.new(entities, "unsupported_time_expression") if clock == :invalid

          clock ||= part_of_day(Decidim::Bih::Text.fold(query))
          if clock
            expression = format("%02d:%02d", clock.fetch(:hour), clock.fetch(:minute))
            expression = "zadnji #{expression}" if LAST.match?(Decidim::Bih::Text.fold(query))
            entities = entities.merge("time_expression" => expression)
          end
          Selection.new(entities, nil)
        end

        def calendar_question?(entities)
          query = Decidim::Bih::Text.fold(entities["query"].to_s)
          return false if query.match?(/\b(?:iz|od|sa|from)\b.+\b(?:do|za|to)\b/)
          return false if query.match?(/\b(?:telefon\w*|kontakt\w*|sajt\w*|web|link|nadlez\w*|radno vrijeme|radno vreme)\b/)

          direction = query.match?(/\b(?:smjer\w*|smer\w*)\b/)
          destination = journey_spans(latin(entities["query"]))&.[](:destination)
          # "Za 1. januar 2027" supplies a calendar date, not a destination.
          # The generic journey span parser also recognizes "za" as a place
          # marker, so keep date-led questions in the calendar reader.
          date_led = query.start_with?("za ") && (NUMERIC_DATE.match?(query) || NAMED_DATE.match?(query))
          return false if destination && !direction && !WEEKDAYS.has_key?(destination) && !date_led
          return true if direction && entities["route"].present?
          if entities["route"].present? && entities["date"].present? && entities["stop"].blank? && entities["area_query"].blank?
            day_words = WEEKDAYS.keys + DAY_OFFSETS.keys
            return true if (query.split - day_words - %w(a u za)).empty? && query.split.intersect?(day_words)
          end

          query.match?(/\b(?:raspored|red voznje|kalendar|polasc\w*|polazak\w*|uslug\w*|linij\w*|autobus\w*|vozi|[gp]\s*\d+)\b/) &&
            query.match?(/\b(?:subot\w*|nedjel\w*|nedelj\w*|praznik\w*|raspust\w*|datum\w*|kalendar\w*|20\d{2})\b/)
        end

        # Calendar/coverage questions carry temporal and route constraints but
        # do not acquire invented journey endpoints from the sentence itself.
        def calendar_entities(entities, now:)
          selected = explicit_temporal_entities(entities, latin(entities["query"]), now:)
          route = Decidim::Bih::Text.fold(entities["query"].to_s).match(/\b([gp])\s*(\d{1,2})\b/)
          route ? Selection.new(selected.entities.merge("route" => "#{route[1].upcase}#{route[2].to_i}"), selected.warning) : selected
        rescue ArgumentError
          Selection.new(entities, "invalid_date")
        end

        def nearest_stop?(entities)
          query = Decidim::Bih::Text.fold(entities["query"].to_s)
          explicit_stop = query.match?(/\A(?:odaberi|izaberi|pokazi)\b.*\b(?:stanic\w*|stajal\w*)\b/)
          return true if explicit_stop && !query.match?(/\b(?:do|to)\b/)
          return false unless NEAREST_STOP.match?(query)

          # A landmark's locality ("od spomenika u centru") is not an
          # onward destination. Only an explicit destination marker selects
          # a journey instead of the physical nearest-stop question.
          tokens = query.split
          destination = tokens.each_index.filter_map do |index|
            phrase_after(tokens, index) if DESTINATION_MARKERS.include?(tokens[index])
          end.first
          destination.nil? || destination.match?(/\b(?:stajal\w*|stanic\w*|stop)\b/)
        end

        def nearest_place(entities)
          # Read the current explicit public landmark before retained/model
          # slots. Clause/locality boundaries keep accessibility prose out.
          query = latin(entities["query"])
          landmark = LANDMARK.match(query)
          if landmark
            text = Decidim::Bih::Text.fold(landmark[:place])
            return if COMPOUND.match?(text)

            return phrase_after(["od", *text.split], 0)
          end

          explicit = marker_spans(latin(entities["query"]))
          [explicit&.fetch(:origin), entities["stop"], entities["area_query"]].find do |place|
            place?(place) && !NEAREST_STOP.match?(Decidim::Bih::Text.fold(place))
          end
        end

        def nearest_locality(entities)
          landmark = LANDMARK.match(latin(entities["query"]))
          return unless landmark

          text = Decidim::Bih::Text.fold(landmark[:place])
          "Bijeljina" if text.match?(/\bu (?:centru|bijeljini|bijeljina)\b/)
        end

        def accessibility_requested?(entities)
          query = Decidim::Bih::Text.fold(entities["query"].to_s)
          query.match?(/\b(?:kolic\w*|invalid\w*|pristupac\w*|stepenic\w*|ivicnjak\w*|wheelchair\w*|accessible|accessibility|step free)\b/)
        end

        # The current citizen sentence overrides retained date/clock slots.
        # A follow-up without a new window keeps the validated journey window.
        def requested_window(entities, now:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          zone = ActiveSupport::TimeZone[SERVICE_TIME_ZONE]
          local_now = now.in_time_zone(zone)
          expression = latin(entities["time_expression"])
          query = latin(entities["query"])
          folded_expression = Decidim::Bih::Text.fold(expression)
          folded_query = Decidim::Bih::Text.fold(query)
          combined = "#{folded_expression} #{folded_query}"
          mode = if LAST.match?(folded_query)
                   :last
                 elsif NEXT.match?(folded_query)
                   :next
                 else
                   LAST.match?(folded_expression) ? :last : :next
                 end
          when_question = mode == :last || NEXT.match?(combined)
          return window(warning: "unsupported_time_expression", mode:) if BEFORE.match?(expression.downcase) || BEFORE.match?(query.downcase)

          date, explicit_day = requested_date(entities, folded_expression, folded_query, local_now)
          clock = parse_clock(query) || parse_clock(expression)
          return window(warning: "unsupported_time_expression", mode:) if clock == :invalid || (expression.gsub(NUMERIC_DATE, "").match?(/\d/) && clock.nil?)

          clock ||= part_of_day(folded_expression) || part_of_day(folded_query)
          earliest = if clock
                       local_clock(zone, date, clock)
                     elsif explicit_day && date != local_now.to_date
                       zone.local(date.year, date.month, date.day)
                     else
                       now
                     end
          explicit_time = !clock.nil?
          historical = false
          rolled_clock = false
          past_clock = nil
          if earliest < now
            past_clock = earliest.in_time_zone(zone).strftime("%H:%M") if clock
            if HISTORICAL.match?(combined) || (explicit_day && clock && !NEXT.match?(combined))
              historical = true
            elsif clock && !explicit_day && !NEXT.match?(combined)
              earliest += 1.day
              rolled_clock = true
            else
              earliest = now
              explicit_time = false
            end
          end
          options = mode == :next && when_question ? WHEN_OPTIONS : DEFAULT_OPTIONS
          window(earliest_after: earliest, mode:, strict: !explicit_time, explicit_time:, historical:, rolled_clock:, past_clock:,
                 requested_day: earliest.in_time_zone(zone).to_date, options:)
        rescue ArgumentError
          window(warning: "invalid_date", mode:)
        end

        def explicit_journey(entities, match)
          destination = match[:destination]
          time = TIME_SUFFIX.match(destination)
          destination = destination[0...time.begin(0)].strip if time
          return Selection.new(entities, "transport_destination_required") unless place?(match[:origin]) && place?(destination)

          resolved = entities.merge("stop" => match[:origin], "area_query" => destination)
          # An explicit clock/day in this citizen sentence wins over retained
          # model slots; requested_window still validates it and DST.
          resolved["time_expression"] = time[:time] if time
          Selection.new(resolved, nil)
        end

        def existing_destination(entities, query)
          destination = entities["area_query"].presence || query
          return Selection.new(entities, "transport_destination_required") unless place?(destination)

          Selection.new(entities.merge("area_query" => destination), nil)
        end

        # A destination correction has two places, but only the positive one
        # may replace the retained destination. "na" stays scoped to this
        # explicit movement clause; globally it also introduces holidays.
        def journey_spans(query)
          declared_endpoint_spans(query) || endpoint_correction_spans(query) || corrected_destination_spans(query) || qualified_place_spans(query) || marker_spans(query)
        end

        # A via constraint is not a destination. Until the planner supports
        # constrained transfers, retain all three places and ask about the via.
        def transfer_constraints(entities, query)
          folded = Decidim::Bih::Text.fold(query)
          return entities.except("transfer_mode") if folded.match?(/\b(?:moze(?: i)?|prihvatam|dozvoljeno je) presjedanje\b/)

          positive = folded.match?(/\b(?:direktno|direktna|bez presjedanja|bez presedanja)\b/)
          negative = folded.match?(/\bne (?:(?:zelim|treba|mora) )?direktn\w*\b/)
          positive && !negative ? entities.merge("transfer_mode" => "direct") : entities
        end

        def without_cancelled_via(entities, query)
          return [entities, query] if entities["via_stop"].blank?

          match = /\A(?:ne treba (?:preko|via)|bez) (?<via>.+?)[,;]\s*(?:direktno|samo) (?<journey>(?:do|za) .+)\z/i.match(query)
          return [entities, query] unless match && same_via_reference?(match[:via], entities["via_stop"])

          [entities.except("via_stop"), match[:journey]]
        end

        def same_via_reference?(left, right)
          normalize = lambda do |value|
            Decidim::Bih::Text.fold(value).split.map do |word|
              word.match?(/\Acent(?:ar|ra|ru|rom)\z/) ? "centar" : word.sub(/(?:ima|om|em|u|a|e|i)\z/, "")
            end
          end
          normalize.call(left) == normalize.call(right)
        end

        def compound_journey_spans(query)
          clause = query.sub(/[,;]\s*(?:mo[zž]e|mogu|koliko|molim|hvala)\b.*\z/i, "")
          clause = clause.sub(/\s+u\s+(?:ponedjeljak|ponedeljak|utorak|srijedu|sredu|cetvrtak|petak|subotu|nedjelju|nedelju)\b.*\z/i, "")
          folded = Decidim::Bih::Text.fold(clause)
          return if folded.match?(/\b(?:ne|nisam|not)\b/)

          match = /\b(?:iz|od|sa|from) (?<origin>.+?) (?:stigao |stigla |stici |stignem )?(?:do|u|to) (?<via>.+?) (?:pa|onda|then) (?:dalje )?(?:do|za|to) (?<destination>.+)\z/.match(folded)
          return unless match

          values = [:origin, :via, :destination].to_h { |key| [key, qualified_place(match[key])] }
          values if values.values.all?(&:present?)
        end

        def qualified_place(value)
          # "skola u Janji" contains a locality, not a second movement marker.
          folded = Decidim::Bih::Text.fold(value)
          folded = folded.sub(/\b(skola|skole|skolu) u (?<locality>[a-z]+)\b/, '\\k<locality> skola')
          folded if place?(folded) && !COMPOUND.match?(folded)
        end

        def qualified_place_spans(query)
          folded = Decidim::Bih::Text.fold(query)
          school = /\b(?:do |za |na )?(?:skola|skole|skolu) u (?<locality>[a-z]+)\b/.match(folded)
          if school && !folded.match?(/\b(?:ne|nego|ili)\b/)
            prior = marker_spans(query)
            return { origin: prior&.fetch(:origin), destination: "#{school[:locality]} skola" }
          end
          # An affirmative self-location, not an arbitrary landmark mention.
          landmark = /\A(?:(?:nalazim se|stojim|ja sam|sam) )?(?:kod|pored|blizu) (?<place>[^.!?]+?)(?: sam)?(?:[.!?]|\z)/.match(latin(query).downcase)
          return unless landmark && !folded.match?(/\b(?:ne|nisam)\b/)

          description = Decidim::Bih::Text.fold(landmark[:place]).sub(/\A(?<landmark>.+?) u (?<locality>[a-z]+)\z/, '\\k<locality> \\k<landmark>')
          place = qualified_place(description)
          { origin: place, destination: marker_spans(query)&.fetch(:destination) } if place
        end

        # Explicit role labels divide citizen clauses before folding removes
        # their punctuation. A destination label must never become a word in
        # the origin. Accept affirmative, bounded declarations in either order;
        # rejected/compound role statements remain unresolved.
        def declared_endpoint_spans(query)
          clauses = query.split(/[,;]/).map { |clause| Decidim::Bih::Text.fold(clause).strip }.reject(&:empty?)
          return unless clauses.length.between?(1, 2)
          return unless clauses.any? { |clause| clause.match?(/\A(?:(?:krajnje )?odrediste|cilj|polaziste|polazna stanica|polazno stajaliste)\b/) }

          spans = { origin: nil, destination: nil }
          clauses.each do |clause|
            origin = /\A(?:polaziste|polazna stanica|polazno stajaliste)(?: je)? (?<place>.+)\z/.match(clause)
            origin ||= AFFIRMED_ORIGIN.match(clause)
            destination = /\A(?:(?:krajnje )?odrediste|cilj)(?: je)? (?<place>.+)\z/.match(clause)
            return unless origin || destination

            role = origin ? :origin : :destination
            return if spans[role]

            value = (origin || destination).captures.first
            value = value.sub(/ (?:uz|sa) pres(?:jed|ed)anje(?:m)?\z/, "")
            return unless bounded_correction_place?(value) && !value.match?(/\b(?:nije|nisu|ostaje|isti|isto|ista)\b/)

            spans[role] = value
          end
          spans
        end

        def endpoint_correction_spans(query)
          folded = Decidim::Bih::Text.fold(query)
          match = /\Ane (?<marker>iz|od|sa|do|za) (?<old>.+?) (?:nego|vec) (?:(?:iz|od|sa|do|za) )?(?<place>.+)\z/.match(folded)
          return unless match && [match[:old], match[:place]].all? { |place| bounded_correction_place?(place) }

          key = ORIGIN_MARKERS.include?(match[:marker]) ? :origin : :destination
          { origin: nil, destination: nil, key => match[:place] }
        end

        def corrected_destination_spans(query)
          clauses = query.split(/[.!?;]/).map { |clause| Decidim::Bih::Text.fold(clause).strip }.reject(&:empty?)
          corrections = clauses.filter_map { |clause| CORRECTED_DESTINATION.match(clause) }
          return unless corrections.one?

          correction = corrections.first
          return unless [correction[:old], correction[:destination]].all? { |place| bounded_correction_place?(place) }

          origin = affirmed_correction_origin(clauses.reject { |clause| clause == correction[0] })
          return if origin == :invalid

          { origin:, destination: correction[:destination] }
        end

        def affirmed_correction_origin(clauses)
          return if clauses.empty?
          return :invalid unless clauses.one?

          origin = AFFIRMED_ORIGIN.match(clauses.first)&.[](:origin)
          bounded_correction_place?(origin) ? origin : :invalid
        end

        def bounded_correction_place?(phrase)
          place?(phrase) && phrase.split.size <= 4 && !COMPOUND.match?(phrase)
        end

        # "iz X za Y", "za Y iz X", "sa X do Y", "za Y" — marker-bounded
        # spans in the citizen's own words. Nothing is guessed for a compound
        # sentence or when no marker is present.
        def marker_spans(query)
          # A later preference sentence ("Može i presjedanje") does not
          # invalidate explicit endpoints in the preceding journey question.
          # "Back to the bus" refers to the conversation, not a destination
          # called "the". Strip only that leading control phrase; calendar,
          # clock and actual endpoint words remain in the original query.
          markers = query.sub(/\A(?:(?:go\s+)?back|return)\s+to\s+(?:the\s+)?(?:bus|transport)(?=$|[,;:.!?]|\s+(?:after|at|around|on|tomorrow|today)\b)/i, "")
          # A trailing promise to keep the destination does not become part
          # of the preceding origin. Only explicit preservation clauses qualify.
          markers = markers.sub(/[,;]\s*(?:krajnj[ei]\s+)?(?:cilj|odredi[sš]te)\s+(?:je|ostaje)\s+(?:ist[io]|nepromijenjen[oa]?)[.!?]?\z/i, "")
          folded = Decidim::Bih::Text.fold(markers.split(/[?!;]/).first.to_s)
          # A route followed by another vehicle is not a second place clause.
          # Keep the route constraint; this only recovers the literal endpoint,
          # and cannot establish a reviewed connecting service.
          folded = folded.gsub(/\b([gp]\s*\d{1,2})\s+(?:pa|onda)\s+((?:prigradsk|gradsk)\w*|drugim\s+autobusom)\b/, '\\1 \\2')
          return if folded.blank? || COMPOUND.match?(folded) || folded.match?(/\b(?:ne|nisam|not)\b/)

          # Punctuation commonly follows a weekday in corrections ("utorak.").
          # Match words, not whitespace-delimited tokens, so the citizen's
          # corrected day cannot silently fall back to a retained date.
          tokens = folded.scan(/[a-z]+/)
          origin_span = origin_span(tokens)
          origin = origin_span && tokens[(origin_span.begin + 1)..origin_span.end].join(" ")
          origin ||= "odavde" if CURRENT_ORIGIN.match?(folded)
          destination_index = destination_marker_index(tokens, origin_span)
          destination = destination_index && phrase_after(tokens, destination_index)
          return if origin.nil? && destination.nil?

          { origin:, destination: }
        end

        # Token range of the first origin marker and its place phrase.
        def origin_span(tokens)
          origin_index = tokens.index { |token| ORIGIN_MARKERS.include?(token) }
          origin = origin_index && phrase_after(tokens, origin_index)
          origin_index..(origin_index + origin.split.size) if origin
        end

        # The first destination marker outside the origin phrase; "u" counts
        # only directly after that phrase ("iz Janje u Bijeljinu").
        def destination_marker_index(tokens, origin_span)
          candidates = tokens.each_index.select { |index| DESTINATION_MARKERS.include?(tokens[index]) && !origin_span&.cover?(index) }
          return candidates.first unless origin_span

          candidates.find { |index| index > origin_span.end } || candidates.first ||
            (origin_span.end + 1 if tokens[origin_span.end + 1] == "u")
        end

        def phrase_after(tokens, index)
          words = tokens[(index + 1)..].to_a.take_while { |token| PHRASE_STOP.exclude?(token) && !token.match?(/\A\d/) }.first(4)
          # "na praznik" describes the service calendar, not a stop named
          # "centar na". Keep the original query for the calendar reader.
          words.pop if words.last == "na" && tokens[index + 1 + words.size].to_s.match?(/\Apraznik\w*\z/)
          phrase = words.join(" ")
          phrase if words.any? && place?(phrase)
        end

        def place?(value)
          value.is_a?(String) && value.length.between?(1, 80) && value.split.length <= 7 &&
            value.match?(/\A[\p{L}\p{M}\d .,'’()\-]+\z/u) && !NON_PLACE.match?(Decidim::Bih::Text.fold(value))
        end

        def latin(value)
          Decidim::Bih::Transliterator.to_latin(value.to_s).strip
        end

        def requested_date(entities, folded_expression, folded_query, local_now)
          explicit = numeric_date(entities["query"].to_s)
          return [explicit, true] if explicit

          relative = relative_date(folded_query, local_now)
          return [relative, true] if relative

          explicit = numeric_date(entities["time_expression"].to_s)
          return [explicit, true] if explicit

          relative = relative_date(folded_expression, local_now)
          return [relative, true] if relative

          if WORKDAY.match?(folded_query) || WORKDAY.match?(folded_expression)
            date = local_now.to_date
            date += 1 until (1..5).cover?(date.wday)
            return [date, true]
          end

          return [Date.iso8601(entities["date"].to_s), true] if entities["date"].present?

          [local_now.to_date, false]
        end

        def relative_date(folded, local_now)
          folded = folded.split(/\b(?:nego|vec)\b/).last.to_s
          tokens = folded.split
          offset_word = tokens.find { |token| DAY_OFFSETS.has_key?(token) }
          return local_now.to_date + DAY_OFFSETS.fetch(offset_word) if offset_word

          weekday = tokens.find { |token| WEEKDAYS.has_key?(token) }
          local_now.to_date + ((WEEKDAYS.fetch(weekday) - local_now.wday) % 7) if weekday
        end

        # A bare number is a route or house number, not a clock: an hour needs
        # a prefix ("u 7"), minutes ("7:30") or a suffix ("17h"). Returns
        # nil, :invalid, or { hour:, minute: }.
        def numeric_date(text)
          match = NUMERIC_DATE.match(text)
          unless match
            named = NAMED_DATE.match(Decidim::Bih::Text.fold(text))
            return unless named

            return Date.new(named[:year].to_i, MONTH_NUMBERS.fetch(named[:month]), named[:day].to_i)
          end

          Date.new((match[:year] || match[:local_year]).to_i, (match[:month] || match[:local_month]).to_i, (match[:day] || match[:local_day]).to_i)
        end

        def parse_clock(text)
          clock_text = text.to_s.downcase.gsub(NUMERIC_DATE, " ").gsub(NAMED_DATE, " ")
          clock_text.scan(CLOCK) do
            match = Regexp.last_match
            next unless match[:prefix] || match[:minute] || match[:suffix]
            before = clock_text[0...match.begin(0)]
            next if before.match?(/\b(?:ne|not)\s*\z/)

            hour = match[:hour].to_i
            minute = match[:minute].to_i
            return :invalid unless hour.between?(0, 23) && minute.between?(0, 59)

            return { hour:, minute: }
          end
          spoken = Decidim::Bih::Text.fold(clock_text).match(/\b(?:poslije|posle|nakon|oko|u)\s+
            (?<hour>jedan|jednog|dva|dvije|tri|cetiri|pet|sest|sedam|osam|devet|deset|jedanaest|dvanaest)
            (?:\s+(?:ujutro|ujutru))?\b(?!\s+(?:navece|navecer|popodne))/ix)
          if spoken
            hour = { "jedan" => 1, "jednog" => 1, "dva" => 2, "dvije" => 2, "tri" => 3,
                     "cetiri" => 4, "pet" => 5, "sest" => 6, "sedam" => 7, "osam" => 8,
                     "devet" => 9, "deset" => 10, "jedanaest" => 11, "dvanaest" => 12 }.fetch(spoken[:hour])
            return { hour:, minute: 0 }
          end
          nil
        end

        def part_of_day(folded)
          return if folded.blank?

          hour = PARTS_OF_DAY.find { |_hour, pattern| pattern.match?(folded) }&.first
          { hour:, minute: 0 } if hour
        end

        # Service timezone is fixed; do not guess through a DST gap or overlap.
        def local_clock(zone, date, clock)
          wall_time = Time.utc(date.year, date.month, date.day, clock.fetch(:hour), clock.fetch(:minute))
          raise ArgumentError, "Ambiguous local clock" unless zone.tzinfo.periods_for_local(wall_time).length == 1

          zone.local(date.year, date.month, date.day, clock.fetch(:hour), clock.fetch(:minute))
        end

        def window(earliest_after: nil, mode: :next, strict: false, explicit_time: false, historical: false, rolled_clock: false, # rubocop:disable Metrics/ParameterLists
                   past_clock: nil, requested_day: nil, options: DEFAULT_OPTIONS, warning: nil)
          Window.new(earliest_after:, mode:, strict:, explicit_time:, historical:, rolled_clock:, past_clock:, requested_day:, options:, warning:)
        end

        private_class_method :route_constraint, :explicit_temporal_entities, :explicit_journey, :existing_destination, :marker_spans, :origin_span,
                             :destination_marker_index, :phrase_after, :journey_spans, :compound_journey_spans, :without_cancelled_via, :same_via_reference?, :transfer_constraints, :qualified_place, :qualified_place_spans, :declared_endpoint_spans, :endpoint_correction_spans, :corrected_destination_spans, :affirmed_correction_origin, :bounded_correction_place?,
                             :place?, :latin, :requested_date, :relative_date, :numeric_date, :parse_clock, :part_of_day, :local_clock, :window
      end
    end
  end
end
