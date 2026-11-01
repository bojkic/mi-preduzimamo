# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Named provider sections, independent from an official calendar of dates.
    # A school symbol without a legend is retained for review, never decoded by
    # guessing. Empty printed sections mean no departures published there.
    module PublicTransportCalendar
      HEADINGS = /^(?<space>[ \t]*)(?<label>Radni[ ]dan(?:i)?|Subota|Nedelja[ ]i[ ]praznici|Nedjelja[ ]i[ ]praznici|
                   Nedelja|Nedjelja|Praznik(?:om)?|Praznici|Školski[ ]dan(?:i)?|Skolski[ ]dan(?:i)?|Nastavni[ ]dan(?:i)?|
                   Školski[ ]raspust|Skolski[ ]raspust)\b/ix
      LABELS = { "workday" => "radni dan", "saturday" => "subotu", "sunday" => "nedjelju", "holiday" => "praznik", "school_day" => "školski dan",
                 "school_break" => "školski raspust" }.freeze

      module_function

      def sections(text, source_url:)
        value = text.to_s
        headings = value.to_enum(:scan, HEADINGS).map { Regexp.last_match.dup }
        headings.each_with_index.flat_map do |heading, index|
          finish = headings[index + 1]&.begin(0) || value.length
          body = value[heading.begin(0)...finish]
          label = heading[:label]
          kinds_for(label).map do |kind|
            warnings = section_warnings(body, kind)
            { "kind" => kind, "source_heading" => label, "source_url" => source_url,
              "source_page" => value[0...heading.begin(0)].count("\f") + 1,
              "source_line" => value[0...heading.begin(0)].count("\n") + 1,
              "status" => section_status(body, warnings),
              "warnings" => warnings, "text" => body }
          end
        end
      end

      def section_warnings(body, kind)
        warnings = []
        warnings << "unexplained_school_symbol" if body.match?(/Smjer\s+[AB]\s*\(Š\)/i)
        if kind == "workday" && body.match?(/(?:samo|isklju[čc]ivo).{0,50}(?:u[čc]en|[šs]kol)|(?:vrijeme|vreme|tokom).{0,30}(?:nastave|raspusta)|nastavnim\s+danima/i)
          warnings << "school_restriction_requires_review"
        end
        warnings << "holiday_restriction_requires_review" if body.match?(/(?:ne\s+(?:saobraća|saobraca|vozi)|osim|izuzev).{0,60}(?:praznik|blagdan)/i)
        warnings
      end

      def section_status(body, warnings)
        return "unreviewed" if warnings.any?

        body.match?(/\b\d{1,2}:\d{2}\b/) ? "available" : "no_departures_published"
      end

      def kind_for_date(value)
        case value.to_time.in_time_zone("Europe/Sarajevo").wday
        when 0 then "sunday"
        when 6 then "saturday"
        else "workday"
        end
      end

      def supports_date?(calendar, value)
        kind = (calendar || {}).fetch("kind", "workday")
        return false if calendar && calendar["effective_from"] && value.in_time_zone("Europe/Sarajevo").to_date.iso8601 < calendar["effective_from"]

        if calendar && calendar["requested_service_date"]
          value.in_time_zone("Europe/Sarajevo").to_date.iso8601 == calendar["requested_service_date"]
        elsif calendar && calendar["reviewed_school_calendar"]
          kind == ReviewedTransportTimetables.calendar_kind(value)
        else
          kind == kind_for_date(value)
        end
      end

      def kinds_for(label)
        value = Decidim::Bih::Text.fold(label)
        return %w(sunday holiday) if value.match?(/ned[ej]+lja i praznici/)
        return ["saturday"] if value.start_with?("subota")
        return ["sunday"] if value.start_with?("nedelja", "nedjelja")
        return ["holiday"] if value.start_with?("prazni")
        return ["school_break"] if value.include?("raspust")
        return ["school_day"] if value.start_with?("skolski", "nastavni")

        ["workday"]
      end
    end
  end
end
