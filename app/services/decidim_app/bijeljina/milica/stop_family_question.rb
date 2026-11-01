# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Only the small, explicit area-journey and stop-correction language is
      # handled here. All place identities still come from reviewed transport
      # reads; a sentence outside this grammar stays with the normal dialogue.
      module StopFamilyQuestion
        Action = Data.define(:kind, :origin, :destination, :date, :time, :date_assumption)
        AREA = /\A(?:(?:kako(?:\s+bih)?|mogu\s+li|tražim\s+vezu|trazim\s+vezu|treba\s+mi\s+(?:autobus|prevoz|prijevoz)|polazim|krećem|krecem)\s+)?\b(?:iz|od)\b\s+
                (?:(?:područja|podrucja|naselja|sela|mjesta)\s+)?(?<origin>.{2,100}?)\s*
                (?:;\s*(?:kako\s+)?)?(?:(?:idem|putujem|stici\s+autobusom|stići\s+autobusom)\s+)?\b(?:do|ka|prema|za)\b\s+(?<destination>.{2,180})\z/ix
        INFORMAL_MOVEMENT = /\A(?:iz|od)\s+(?<origin>[^.!?,;]{2,100}?)\s+bih\s+u\s+(?<destination>[^.!?]{2,180})/i
        CORRECTION = /\A(?:(?:meni\s+)?(?:ipak\s+)?(?:više|vise|bolje)\s+odgovara|
                       (?:radije|ipak)\s+bih\s+(?:krenuo|krenula|pošao|posao|pošla|posla)\s+(?:sa|s|od|iz)|
                       (?:ipak|radije)\s+(?:kreni|polazim|krećem|krecem)\s+(?:sa|s|od|iz)|
                       (?:mislila|mislio)\s+sam\s+na)\s+
                       (?<stop>[^.!?]{2,100}?)\s*(?:[.!?]\s*(?:možeš|mozes|možete|mozete)\s+li\s+[^.!?]{0,80})?[.!?]?\z/ix
        DATE = TransportJourneyQuestion::NUMERIC_DATE
        CLOCK = /\b(?:poslije|posle|nakon|oko|u)\s+(?:[01]?\d|2[0-3]):[0-5]\d\b/i
        module_function

        def call(text, state:, context:)
          return unless ENV["MILICA_AREA_DEFAULT_STOPS_ENABLED"] == "true" && ENV["MILICA_JOURNEY_PLANNER_V2_ENABLED"] == "true"

          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          return if latin.length > 350

          saved = state.dig(Decidim::Bih::Concierge::Dialogue::ConversationSlots::KEY, "journey")
          if recall?(latin) && complete?(saved) && saved["origin_id"].to_s.start_with?("transport-place:")
            return Action.new(:recall, saved.fetch("origin_query"), nil, nil, nil, nil)
          end
          if (match = CORRECTION.match(latin)) && complete?(saved)
            stop = match[:stop].strip
            date_word = Decidim::Bih::Text.fold(stop).match?(/\A(?:ponedjeljak|ponedeljak|utorak|srijed\w*|sred\w*|cetvrtak|petak|subot\w*|nedjelj\w*|nedelj\w*|danas|sutra|preksutra)\b/)
            return if date_word || stop.match?(/[;,]/)

            return Action.new(:correction, stop, saved.fetch("destination_query"), saved.fetch("date"), saved.fetch("time"), nil)
          end

          match = AREA.match(latin) || INFORMAL_MOVEMENT.match(latin)
          return unless match

          window = TransportJourneyQuestion.requested_window({ "query" => latin }, now: context.now)
          return if window.warning
          date_assumption = nil
          # An explicitly dated past journey is a valid historical timetable
          # query. Only an undated clock needs the next-weekday interpretation.
          if window.historical && !DATE.match?(latin)
            folded = Decidim::Bih::Text.fold(latin)
            weekday = folded.split.find { |word| TransportJourneyQuestion::WEEKDAYS.key?(word) }
            today = context.now.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE).to_date
            return unless weekday && TransportJourneyQuestion::WEEKDAYS.fetch(weekday) == today.wday
            return if folded.match?(/\b(?:danas|ovog|ove|this|today)\b/)

            date_assumption = "next_weekday_after_past_clock"
          end

          origin = match[:origin].strip
          destination = match[:destination].split(/[?,;]/, 2).first.to_s
                             .gsub(DATE, " ").gsub(CLOCK, " ")
                             .gsub(/\b(?:radnim?\s+dan(?:om|ima)|radni\s+dan|weekday|workday)\b/i, " ")
                             .sub(/\s+(?:u\s+)?(?:ponedjeljak|ponedeljak|utorak|srijedu|sredu|cetvrtak|petak|subotu|nedjelju|nedelju|sutra|danas|preksutra)\b.*\z/i, "")
                             .sub(/\s+(?:oko|u|at|around)\s+\d{1,2}(?::\d{2})?(?:\s+(?:ujutru|ujutro|rano|morning))?\b.*\z/i, "")
                             .sub(/\s+mi\s+treba\s+(?:prevoz|prijevoz|autobus)\b.*\z/i, "")
                             .sub(/\s+javnim\s+(?:prevozom|prijevozom)\b.*\z/i, "")
                             .sub(/\s+autobusom\b.*\z/i, "")
                             .gsub(/[.!]\z/, "").strip.squish
          local = window.earliest_after.in_time_zone(TransportJourneyQuestion::SERVICE_TIME_ZONE)
          local += 7.days if date_assumption
          date = local.to_date.iso8601
          time = local.strftime("%H:%M")
          return unless place?(origin) && place?(destination)
          return unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          Action.new(:journey, origin, destination, date, time, date_assumption)
        end

        def complete?(journey)
          journey.is_a?(Hash) && %w(origin_query destination_query).all? { |key| place?(journey[key]) } &&
            journey["date"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) &&
            journey["time"].to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
        end

        def place?(value)
          value.is_a?(String) && value.length.between?(2, 120) && !value.match?(/[\x00-\x1f]/)
        end

        def recall?(text)
          folded = Decidim::Bih::Text.fold(text)
          return false unless folded.match?(/\A(?:podsjeti\s+me\s+)?(?:koje|koji|koju)\b/i)
          return false unless folded.match?(/\b(?:si|ste)\b/) && folded.match?(/\b(?:stajal\w*|stanic\w*)\b/)

          folded.match?(/\b(?:pretpostav\w*|uze\w*|odabra\w*|izabra\w*|racuna\w*)\b/)
        end
      end
    end
  end
end
