# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Which civic question is actually being asked, decided before any source
      # is read. The dialogue topic tells us the subject ("waste", "water"); it
      # does not tell us whether the citizen wants a collection day, a bill or a
      # recycling container, and answering the wrong one of those is the defect
      # this module exists to remove.
      #
      # Four misroutings are locked down here:
      #
      #   recycling vs regular waste - "Gdje su kontejneri za staklo i
      #     plastiku?" used to return "Odvoz otpada za Bijeljina: srijeda".
      #   billing vs outage - "zašto mi je račun za vodu ogroman" is not a
      #     question about a water interruption, and "nema vode" is not a
      #     question about a tariff.
      #   transport fare vs route - a fare question stays with the reviewed fare
      #     paragraph; this module never claims a transport question.
      #   bulky waste vs recycling - kabasti otpad is its own service with its
      #     own announced campaigns, and is left alone.
      #
      # Everything is deterministic folded-token matching. Returning nil means
      # "not one of mine", and the existing read flow is untouched.
      module CivicDomainQuestion
        Question = Struct.new(:domain, :biller, :focus, keyword_init: true)

        # Topics on which a billing or recycling question can legitimately
        # arrive. Transport and parking are excluded on purpose: both have their
        # own reviewed fare/tariff answers and "koliko košta" must keep
        # reaching them.
        BILLING_TOPICS = %w(waste water electricity heating city_service unknown).freeze
        RECYCLING_TOPICS = %w(waste city_service unknown).freeze
        EXCLUDED_TOPICS = %w(transport parking budget donation goodwill rewards account report).freeze

        # A bill is being discussed, not a service interruption.
        BILLING_STRONG = /\b(?:racun\w*|faktur\w*|uplat\w*|uplac\w*|dug|duga|dugu|dugujem|dugovanj\w*|kamat\w*|opomen\w*|reklamacij\w*|obracun\w*|pretplat\w*|rate|ratama)\b/
        BILLING_WEAK = /\b(?:cjenovnik\w*|cenovnik\w*|tarif\w*|cijen\w*|cen[aeu]|kost\w*|naknad\w*|placanj\w*|platiti|platim|placam)\b/
        # "Koliko je kubik vode?" prices a service without using a billing noun.
        # A measured unit plus a quantity question is a tariff question; either
        # one alone is not.
        PRICE_UNIT = /\b(?:kubik\w*|m3|kwh|kilovat\w*|po kvadrat\w*|po m2|po satu|mjesecno|mesecno)\b/
        QUANTITY_QUESTION = /\b(?:kolik\w*|cijen\w*|cen[aeu])\b/
        # "Koliko puta mjesečno se odvozi smeće" counts collections, not money.
        # Without this, a unit of time turns a frequency question into a tariff.
        FREQUENCY_QUESTION = /\b(?:koliko puta|puta (?:dnevno|sedmicno|nedjeljno|mjesecno|mesecno)|koji dan|kada|kad)\b/
        # The citizen's own amount, which only the provider can see.
        BILLING_PERSONAL = /\b(?:moj\w*|mi|nam|nama|nas\w*|meni)\b/
        # Words that mean the question is about a fare or a parking ticket, both
        # of which already have reviewed answers elsewhere.
        FARE_OR_PARKING = /\b(?:kart\w*|autobus\w*|bus|busa|prevoz\w*|prijevoz\w*|parking\w*|parkiranj\w*|zon[aeiu]|ticket\w*|fare\w*)\b/
        # An interruption question, which must never be answered with a tariff.
        OUTAGE = /\b(?:nema|nestal\w*|nestank\w*|prekid\w*|iskljucen\w*|kvar\w*|havarij\w*|curi|puk(?:la|ao)|ne radi|hladn\w*)\b/

        RECYCLING_STRONG = /\b(?:recikl\w*|ambalaz\w*|sekundarn\w* sirovin\w*|separacij\w*|reciklaz\w*)\b/
        # "pet" is also the number five and the usual short form of "petak", so
        # PET counts only as part of a packaging phrase. Missing a bare "PET"
        # costs one fallback; reading "pet ili subota" as recycling costs a
        # confidently wrong answer.
        RECYCLING_MATERIAL = /\b(?:
          stakl\w*|plastik\w*|plastic\w*|papir\w*|karton\w*|najlon\w*|limenk\w*|flas\w*|boc\w*|metal\w*|
          pet\ (?:ambalaz\w*|boc\w*|flas\w*)
        )\b/x
        DISPOSAL_CUE = /\b(?:
          kontejner\w*|kant[aeiu]\w*|posud\w*|baci\w*|bacam|bacim|odloz\w*|odlag\w*|
          odvoz\w*|odvoze|prikuplj\w*|sakuplj\w*|razdvaj\w*|sortir\w*|gdje\w*|gde\w*
        )\b/x
        BULKY = /\b(?:kabast\w*|glomazn\w*|namjestaj|namestaj|bijela tehnik\w*|bela tehnik\w*)\b/

        # "Did the truck actually come?" is not a question the weekly schedule
        # snapshot can answer. It is a different claim from "which day is
        # collection", and answering it with the plan reads as a confirmation
        # that the collection happened.
        OBSERVED_COLLECTION = /\b(?:
          nije\ (?:pokupljen\w*|odvezen\w*|odnesen\w*|dosao|dosla|proslo|prosao)|
          nisu\ (?:pokupili|odvezli|dosli|prosli)|
          (?:ni)?su\ li\ (?:pokupili|odvezli|dosli)|
          da\ li\ (?:su|je)\ (?:pokupili|pokupljeno|odvezli|odvezeno|dosli|dosao)|
          preskocil\w*|nije\ prazn\w*|jos\ (?:uvijek\ )?stoji|kamion\ nije
        )\b/x

        HEATING_SUBJECT = /\b(?:grijanj\w*|grejanj\w*|toplan\w*|toplovod\w*|toplotn\w*|radijator\w*)\b/
        # "Is my house on the district-heating network?" - the one heating
        # question whose answer is a named blocker, never a guess.
        NETWORK_MEMBERSHIP = /\b(?:
          prikljuc\w*|mrez\w*|pokriv\w*|obuhvac\w*|u\ sistemu|ima\ li|imam\ li|imamo\ li|da\ li\ imam\w*|
          na\ (?:toplan\w*|toplovod\w*|sistem\w*|gradsk\w*\ grijanj\w*|daljinsk\w*\ grijanj\w*)
        )\b/x
        OWN_PLACE = /\b(?:kuc\w*|zgrad\w*|stan|stana|stanu|ulic\w*|adres\w*|naselj\w*|komsiluk\w*)\b/

        module_function

        # nil means "leave the existing routing alone".
        def call(topic:, entities:)
          topic = topic.to_s
          return if EXCLUDED_TOPICS.include?(topic)

          query = fold(entities["query"])
          return if query.empty?

          heating_network(topic, query) || billing(topic, query) || recycling(topic, query)
        end

        def heating_network(topic, query)
          return unless topic == "heating" || HEATING_SUBJECT.match?(query)
          return unless NETWORK_MEMBERSHIP.match?(query) && OWN_PLACE.match?(query)
          # "nema grijanja u mojoj zgradi" is an outage report, not a coverage
          # question, and keeps its notice answer.
          return if OUTAGE.match?(query)

          Question.new(domain: :heating_network, biller: nil, focus: :coverage)
        end

        def billing(topic, query)
          return unless BILLING_TOPICS.include?(topic) && !FARE_OR_PARKING.match?(query)

          strong = BILLING_STRONG.match?(query)
          return unless billing_question?(query, strong:)

          biller = biller_for(topic, query)
          # "Kako da platim na mojoj lokaciji" names no bill and no provider.
          # Only an explicit billing noun ("račun", "dug") earns the right to
          # ask which of the five bills is meant; a bare payment verb does not,
          # and keeps whatever answer it had.
          return if biller.nil? && !strong

          Question.new(domain: :billing, biller:,
                       focus: BILLING_PERSONAL.match?(query) && strong ? :personal : :published)
        end

        # A weak cue ("koliko košta") loses to an interruption question and to a
        # recycling one; a strong cue ("račun") wins, because a bill is never an
        # outage.
        def billing_question?(query, strong:)
          return true if strong

          priced_unit = PRICE_UNIT.match?(query) && QUANTITY_QUESTION.match?(query) && !FREQUENCY_QUESTION.match?(query)
          return false unless BILLING_WEAK.match?(query) || priced_unit

          !OUTAGE.match?(query) && !RECYCLING_STRONG.match?(query)
        end

        def recycling(topic, query)
          return unless RECYCLING_TOPICS.include?(topic)
          return if BULKY.match?(query)
          return unless recycling_subject?(topic, query)

          Question.new(domain: :recycling, biller: nil, focus: recycling_focus(query))
        end

        def recycling_subject?(topic, query)
          return true if RECYCLING_STRONG.match?(query)
          return false unless RECYCLING_MATERIAL.match?(query)

          # A bare material word only means recycling together with a disposal
          # cue or an already-waste topic; "papiri za registraciju" does not.
          topic == "waste" || DISPOSAL_CUE.match?(query)
        end

        # The landfill hours are withheld unless the citizen is actually taking
        # the waste there; otherwise they read as an instruction to do so.
        SELF_HAUL = /\b(?:deponij\w*|brijesnic\w*|odvez\w*|odnes\w*|odnijet\w*|sam(?:a|i)? (?:da )?(?:odvez\w*|odnes\w*))\b/

        def recycling_focus(query)
          return :self_haul if SELF_HAUL.match?(query)
          return :location if query.match?(/\b(?:gdje|gde|lokacij\w*|najblizi\w*|blizu|u blizini|kontejner\w*|where)\b/)
          return :glass if query.match?(/\bstakl\w*\b/)

          :general
        end

        # Not a domain of its own: the schedule answer is still the right one,
        # but it must be marked as a plan rather than as a confirmation that a
        # truck passed. ReadPort asks this alongside the schedule read.
        def observed_collection?(query)
          OBSERVED_COLLECTION.match?(fold(query))
        end

        def biller_for(topic, query)
          matched = CivicDomainFacts.billers.select do |biller|
            Array(biller["tokens"]).any? { |token| query.include?(token.to_s) }
          end
          # "komunalna naknada" also contains the waste provider's vocabulary;
          # the more specific city levy wins when it is named outright.
          return "city_levies" if matched.any? { |biller| biller.fetch("id") == "city_levies" } && query.match?(/\bkomunaln\w* naknad\w*\b/)
          return matched.first.fetch("id") if matched.one?
          return topic if matched.empty? && CivicDomainFacts.biller(topic)

          nil
        end

        def fold(value)
          Decidim::Bih::Text.fold(value.to_s)
        end
      end
    end
  end
end
