# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Extract the reviewed opening-announcement fare paragraph, not the
      # timetable source. This does not establish today's prices or a journey's
      # zone. Unknown/mixed wording deliberately stays with the full read flow.
      module TransportFareAnswer
        FARE = /\b(?:cijena|cijene|cijenu|cena|cene|cenu|cjenovnik|cenovnik|tarifa|tarife|fares?|prices?|costs?|koliko kost[a-z]*|how much)\b/
        SUBJECT = /\b(?:autobus[a-z]*|bus|busa|buses|prevoz[a-z]*|prijevoz[a-z]*|kart[a-z]*|tickets?)\b/
        GENERIC_WORDS = %w(
          koliko kolika kolike koliki kosta kostaju koja koje je su cijena cijene cijenu cena cene cenu
          cjenovnik cenovnik tarifa tarife karta karte kartu karata
          autobus autobusa autobusi autobuska autobuske autobusku autobusom bus busa buses
          javni javnog javnom gradski gradskog gradskom prevoz prevoza prijevoz prijevoza
          za u na bijeljina bijeljini molim te vas mi reci zanima me
          how much is are a the of for in ticket tickets fare fares price prices cost costs
          public city transport
        ).freeze

        module_function

        def call(entry:, query:)
          return unless entry[:key] == :javni_prevoz && fare_question?(query)

          text = entry.dig(:answer_sections, :fares)
          source_url = entry.dig(:answer_sources, :fares)
          return unless text.is_a?(String) && source_url.is_a?(String)

          # ReadPort emits the source separately, outside prose transliteration.
          # Keep the reviewed facts but avoid a duplicate, Cyrillic-damaged URL.
          text = text.sub(/: #{Regexp.escape(source_url)}\.\z/, ".")

          if scoped_fare_question?(Decidim::Bih::Text.fold(query))
            text += " Samo odredište nije dovoljno da potvrdim broj tarifnih zona i tačnu cijenu tog putovanja. Cijene su iz navedene gradske objave."
          end
          { text:, source_url: }.freeze
        end

        def fare_question?(query)
          return false unless query.is_a?(String) && query.valid_encoding? && query.length <= 160

          question = Decidim::Bih::Text.fold(query)
          return true if scoped_fare_question?(question) || fare_correction?(question)

          words = question.split
          return false if words.empty? || (words - GENERIC_WORDS).any?
          return false unless SUBJECT.match?(question)

          FARE.match?(question) || question.match?(/\bkoliko je (?:karta|kartu)\b/)
        end

        def scoped_fare_question?(question)
          return false unless FARE.match?(question) && SUBJECT.match?(question)
          return false if (question.split - GENERIC_WORDS).empty?
          return false if question.match?(/\b(?:ne|nemoj|danas|sutra|nedjel\w*|nedelj\w*|subot\w*|raspored|polazak|polasc\w*|red voznje|map\w*|zon\w*|status)\b/)

          question.match?(/\b(?:do|za) [a-z]+(?: [a-z]+){0,3}\z/)
        end

        def fare_correction?(question)
          question.match?(/\Anemoj mi umjesto cijen[ae] (?:poslati|slati|dati) (?:cijeli )?raspored\z/)
        end

        private_class_method :fare_question?
      end
    end
  end
end
