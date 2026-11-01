# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # These sources yield review candidates, never live incident facts. A page
    # title or navigation link is not a fallback when relevant content is absent.
    module CityServiceContentFilter
      SOURCES = %w(road_conditions civil_protection bulky_waste weather_warnings waste_schedule).freeze
      # Consent banners, procurement, recruitment and corporate governance are
      # never service facts, however topical the rest of the title reads.
      NOISE = /\b(?:cookie|cookies|kolacic\w*|privatnost|privacy|consent|upravljajte[ ]opcijama|
        procitajte[ ]vise[ ]o[ ]ovim[ ]svrhama|konkurs\w*|pripravnik\w*|radn\w*[ ]mjest\w*|
        javne?[ ]nabavk\w*|ponud[aeu]|tender\w*|oglas(?:[aeiu]|om|ima)?|licitacij\w*|
        akcionar\w*|nadzorn\w*[ ]odbor\w*|sjednic\w*|skupstin\w*)\b/x
      TOPICS = {
        "road_conditions" => /\b(?:obustav\w*|odron\w*|saobracaj\w*|kolovoz\w*|radovi|zabrana|prohod\w*)\b/,
        "civil_protection" => /\b(?:upozoren\w*|evaku\w*|vanredn\w*|apel)\b|(?:bijeljin\w*.*(?:pozar|poplav)|(?:pozar|poplav).*bijeljin\w*)/,
        "bulky_waste" => /\b(?:kabast\w*|akcij\w*.*ciscenj\w*|ciscenj\w*.*akcij\w*)\b/,
        "weather_warnings" => /\b(?:upozoren\w*|warning|alarm|nevrijem\w*|oluj\w*|grmljavin\w*)\b/,
        "waste_schedule" => /(?:program|raspored).*(?:otpad|odvoz)/
      }.freeze
      MONTHS = %w(januar februar mart april maj juni juli avgust septembar oktobar novembar decembar).freeze

      def self.relevant?(source_key, title, now:)
        text = Decidim::Bih::Text.fold(title.to_s)
        return false if text.match?(NOISE) || !text.match?(TOPICS.fetch(source_key))

        !expired_reference?(source_key, text, now:)
      end

      def self.expired_reference?(source_key, text, now:)
        # Explicit older annual programs/campaigns must not reappear as current.
        years = text.scan(/\b20\d{2}\b/).map(&:to_i)
        return true if years.any? && years.max < now.year

        if source_key == "bulky_waste" && years.include?(now.year)
          month = MONTHS.index { |name| text.match?(/\b#{name[0, 3]}[a-z]*\b/) }
          return true if month && month + 1 < now.month
        end
        false
      end
    end
  end
end
