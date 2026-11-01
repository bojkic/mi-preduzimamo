# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Select only clearly requested parts of the reviewed parking entry.
      # This never infers a user's zone, new tariffs, or a current schedule.
      module DirectoryAnswer
        PAYMENT = /\b(?:sms|placanje|platim|platiti|payment|pay|paying|cijena|cijene|cena|cene|tarifa|tarife|koliko kosta|kako se placa)\b/
        HOURS = /\b(?:
          radno[ ](?:vrijeme|vreme)|(?:od|do)[ ](?:koliko|kada|kad)|(?:vrijeme|vreme|termini|raspored)[ ]naplate|
          (?:kada|kad)[ ](?:se[ ])?(?:placa|naplacuje|radi)|subotom|nedjeljom|nedeljom|vikendom|praznikom|praznicima|
          opening[ ]hours|working[ ]hours|charging[ ]hours
        )\b/x
        MONTHLY = /\b(?:mjesecn\w*|mesecn\w*|pretplat\w*|monthly|subscription)\b/
        SHORT_TERM = /\b(?:po[ ]satu|satn\w*|dnevn\w*|hourly|daily)\b/
        ZONES = /\b(?:zona|zone|zoni|zonu|zonama|zones|mapa|mapi|mapu|map|maps)\b/
        MAP = /\b(?:mapa|mapi|mapu|map|maps)\b/
        ZONE_DETAILS = /\b(?:
          mapa|mapi|mapu|map|maps|(?:i|and)[ ](?:parking[ ])?(?:zone|zona|zones)|(?:zone|zona|zones)[ ](?:i|and)
        )\b/x
        MONTHLY_METHOD = /\b(?:sms|placanje|plati\w*|kako|gdje|gde|kup\w*|payment|pay|paying|how(?![ ]much\b)|where|buy|purchase)\b/
        UNSUPPORTED = /\b(?:
          ne|nemoj|not|kartic\w*|gotovin\w*|aplikacij\w*|automat\w*|kazn\w*|povrat\w*|reklamacij\w*|otkaz\w*|
          ulic\w*|lokacij\w*|mjest\w*|mest\w*|besplat\w*|moj\w*|sam|ovdje|ovde|tu|
          card|cash|app|machine|fine|refund|street|location|free|my|here
        )\b/x
        ZONE_COLORS = {
          white: /\b(?:bijel\w*|bel\w*|white)\b/,
          red: /\b(?:crven\w*|red)\b/,
          blue: /\b(?:plav\w*|blue)\b/
        }.freeze
        BROADER_ZONE_PAYMENT = /\b(?:dnevn\w*|daily|day|i|ii|and|ili|or|sv[aei]\w*|ostal\w*|prv\w*|drug\w*|first|second|all|both|other|versus|vs)\b|\d/
        # Copy clauses, not tariff constants. Any new paragraph shape or added
        # caveat keeps the complete reviewed payment text instead of losing it.
        PAYMENT_PARAGRAPH = %r{\A
          (?<prefix>Plaćanje[ ]SMS-om:[ ])
          (?<white>bijela[ ]/[ ]zona[ ]centar[ ][^()]+\([^()]+\)),[ ]
          (?<red>crvena[ ]/[ ]I[ ]zona[ ][^()]+\([^()]+\)),[ ]
          (?<blue>plava[ ]/[ ]II[ ]zona[ ][^()]+\([^()]+\));[ ]
          dnevna[ ]karta[ ]za[ ]plavu[ ]zonu[ ][^()]+\([^()]+\)\.
        \z}x

        module_function

        # Keep missing-hours and monthly-payment caveats beside the reviewed section selection.
        # rubocop:disable Metrics/CyclomaticComplexity
        def call(entry:, query:, locale:)
          full_answer = entry.fetch(:answer)
          sections = entry[:answer_sections]
          return full_answer unless entry.fetch(:key) == :parking && sections.is_a?(Hash)

          question = Decidim::Bih::Text.fold(query).sub(/\Anije korisno\s+/, "")
          question = question.gsub(/\bprv(?:a|e|u|oj|om) (?:parking )?zon\w*\b/, "crvena zona")
          question = question.gsub(/\bdrug(?:a|e|u|oj|om) (?:parking )?zon\w*\b/, "plava zona")
          return full_answer if UNSUPPORTED.match?(question)

          monthly = MONTHLY.match?(question)
          # Reviewed monthly prices do not establish how to buy/pay for a pass.
          return full_answer if monthly && MONTHLY_METHOD.match?(question)

          requested = requested_sections(question, monthly:)
          return full_answer unless (requested - sections.keys).empty?

          parts = sections.values_at(*requested)
          parts[0] = zone_payment(parts.first, question) if requested == [:payment]
          parts << I18n.t("decidim_app.milica.directory_answers.parking_hours_unavailable", locale:, raise: true) if HOURS.match?(question)
          parts.empty? ? full_answer : parts.join("\n\n")
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        def zone_payment(payment, question)
          return payment if HOURS.match?(question) || BROADER_ZONE_PAYMENT.match?(question)

          zones = ZONE_COLORS.select { |_zone, color| color.match?(question) }.keys
          return payment unless zones.one?

          color = ZONE_COLORS.fetch(zones.first)
          return payment unless /#{color}(?:[ ]parking)?[ ]zon\w*\b|\bzon\w*[ ]#{color}/.match?(question)

          paragraph = PAYMENT_PARAGRAPH.match(payment)
          paragraph ? "#{paragraph[:prefix]}#{paragraph[zones.first]}." : payment
        end

        def requested_sections(question, monthly:)
          payment = monthly ? SHORT_TERM.match?(question) : PAYMENT.match?(question)
          payment ||= ZONES.match?(question) && question.match?(/\b(?:broj|kod)\b/)
          # A zone mentioned inside an SMS/price question is not a request for
          # map details. Explicit lists/maps may ask for both reviewed sections.
          zones = ZONES.match?(question) && ((!payment && !monthly) || ZONE_DETAILS.match?(question))
          requested = []
          requested << :payment if payment
          requested << :monthly if monthly
          return requested unless zones

          # The map paragraph names only two streets. A zone-list answer also
          # needs the reviewed payment paragraph, which includes the white zone.
          requested.unshift(:payment) unless MAP.match?(question)
          requested << :zones
          requested.uniq
        end
      end
    end
  end
end
