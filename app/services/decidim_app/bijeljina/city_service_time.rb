# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Deterministic civil time extraction. Publication and collection clocks are
    # supplied explicitly; a date is never eligible to be read as a clock range.
    module CityServiceTime
      ZONE = "Europe/Sarajevo"
      DATE_PATTERN = %r{(?<![\d:])(?<day>\d{1,2})[./-](?<month>\d{1,2})[./-](?<year>\d{4})(?!\d)}
      NAMED_DATE_PATTERN = /(?<day>\d{1,2})\.\s*(?<month_name>[[:alpha:]]+)\s+(?<year>\d{4})/i
      CLOCK_PATTERN = /\A(?<hour>\d{1,2}):(?<minute>\d{2})\z/
      RANGE_PATTERN = /(?<![\d:])(?<from>\d{1,2}:\d{2})\s*(?:(?:casova|casa|sati|h)\b\s*)?(?:(?:ujutru|navece)\b\s*[,]?\s*)?(?:pa\s+)?(?:-|–|—|do)\s*(?<to>\d{1,2}:\d{2})(?![\d:])/i
      MAX_SCHEDULE_DAYS = 31
      DATE_TOKEN = '(?:\d{1,2}[./-]\d{1,2}[./-]\d{4}\.?|\d{1,2}\.\s*[[:alpha:]]+\s+\d{4}\.?)'
      FULL_SPAN_PATTERN = /(?<first>#{DATE_TOKEN})\s*(?:do|[-–—])\s*(?<last>#{DATE_TOKEN})/
      SHORT_SPAN_PATTERN = /(?<!\d)(?<first_day>\d{1,2})\.?\s*(?:do|[-–—])\s*(?<last_day>\d{1,2})\.\s*(?<month>\d{1,2}|[[:alpha:]]+)\.?\s*(?<year>\d{4})(?!\d)/
      CONTINUOUS_PATTERN = /(?<first>#{DATE_TOKEN})\s*(?:u|od)?\s*(?<from>\d{1,2}:\d{2})\s*(?:do|[-–—])\s*(?<last>#{DATE_TOKEN})\s*(?:u|do)?\s*(?<to>\d{1,2}:\d{2})/
      MONTHS = %w(januar februar mart april maj jun jul avgust septembar oktobar novembar decembar).each_with_index.to_h { |name, index| [name, index + 1] }.merge(
        "januara" => 1, "februara" => 2, "marta" => 3, "aprila" => 4, "maja" => 5,
        "juna" => 6, "jula" => 7, "avgusta" => 8, "septembra" => 9, "oktobra" => 10,
        "novembra" => 11, "decembra" => 12
      ).freeze

      module_function

      def fold(value)
        # Lookup folding removes punctuation; temporal parsing must retain the
        # separators which distinguish dates from clocks.
        text = Decidim::Bih::Transliterator.to_latin(value.to_s.unicode_normalize(:nfc).downcase)
        Decidim::Bih::Text::DIACRITICS.each { |from, to| text = text.gsub(from, to) }
        text.gsub(/[[:space:]\u00a0]+/, " ").strip
      end

      def date(value, reference:)
        text = fold(value)
        numeric = text.match(DATE_PATTERN)
        named = text.match(NAMED_DATE_PATTERN)
        match = [numeric, named].compact.min_by { |item| item.begin(0) }
        return Date.new(match[:year].to_i, match.names.include?("month") ? match[:month].to_i : MONTHS.fetch(match[:month_name], 0), match[:day].to_i) if match

        # Relative words are anchored to the source publication date, never a
        # later fetch date when an old article is revisited.
        return unless reference

        local_date = reference.in_time_zone(ZONE).to_date
        return local_date + 1 if text.match?(/\bsutra\b/)

        local_date if text.match?(/\bdanas\b/)
      rescue Date::Error
        nil
      end

      def explicit_date?(value)
        text = fold(value)
        text.match?(DATE_PATTERN) || text.match?(NAMED_DATE_PATTERN)
      end

      def ranges(value)
        fold(value).to_enum(:scan, RANGE_PATTERN).map { Regexp.last_match.dup }
      end

      # Expand only an explicit daily schedule. A multi-day announcement does
      # not by itself prove that services are interrupted between daily shifts.
      # Empty arrays mean recognized but unsupported/invalid temporal evidence.
      def schedule(value, date:, reference:, from: nil, to: nil)
        text = fold(value)
        continuous = text.match(CONTINUOUS_PATTERN)
        return continuous_schedule(text, continuous, reference:) if continuous

        span = date_span(text, reference:)
        duration = text.match(/(?:naredna|sljedeca|sledeca|narednih|sljedecih|sledecih|tokom|u trajanju od)\s+(?<count>\d{1,2}|dva|tri|cetiri|pet|sedam)\s+dana/)
        daily = text.match?(/svakog dana|svaki dan|svakodnevno|\bdnevno\b/)
        if span || duration
          first, last, evidence = schedule_span(span, duration, date:)
          return [] unless bounded_span?(first, last)
          return [] if [from, to].any? && !daily

          return daily_windows(first, last, text:, from:, to:, daily:, evidence:)

        end
        single_day_schedule(text, date:, reference:, from:, to:)
      end

      def single_day_schedule(text, date:, reference:, from:, to:)
        return [] if text.match?(/svakog dana|svaki dan|svakodnevno|\bdnevno\b/) # No bounded end date or count was supplied.

        deadline = text.match(/\bdo\s+(?<last>#{DATE_TOKEN})/)
        if deadline
          last = self.date(deadline[:last], reference:)
          return [{ starts_at: nil, ends_at: last && clock(last + 1, "00:00"), precision: "day", complete: false,
                    temporal_status: "unknown_start", temporal_evidence: deadline[0], source_date: nil,
                    raw_from: "", raw_to: deadline[:last] }]
        end

        interval = window(date, from:, to:, overnight: overnight?(text))
        interval ? [interval] : []
      end

      def continuous_schedule(text, continuous, reference:)
        return [] unless text.match?(/neprekidno|kontinuirano|bez prestanka/)

        first = date(continuous[:first], reference:)
        last = date(continuous[:last], reference:)
        return [] unless bounded_span?(first, last)

        starts_at = clock(first, continuous[:from])
        ends_at = clock(last, continuous[:to])
        return [] unless starts_at && ends_at && ends_at > starts_at

        [{ starts_at:, ends_at:, precision: "minute", recurrence: "continuous", temporal_evidence: continuous[0] }]
      end

      def schedule_span(span, duration, date:)
        return span.values_at(:first, :last, :evidence) if span

        count = { "dva" => 2, "tri" => 3, "cetiri" => 4, "pet" => 5, "sedam" => 7 }.fetch(duration[:count], duration[:count].to_i)
        [date, date && (date + count - 1), duration[0]]
      end

      def daily_windows(first, last, **schedule)
        (first..last).map do |day|
          interval = window(day, from: schedule[:from], to: schedule[:to], overnight: overnight?(schedule.fetch(:text)))
          return [] unless interval

          interval.merge(recurrence: schedule[:daily] ? "daily" : "date_span", temporal_evidence: schedule[:evidence])
        end
      end

      def date_span(text, reference:)
        if (match = text.match(FULL_SPAN_PATTERN))
          { first: date(match[:first], reference:), last: date(match[:last], reference:), evidence: match[0] }
        elsif (match = text.match(SHORT_SPAN_PATTERN))
          month = MONTHS.fetch(match[:month], match[:month].to_i)
          { first: Date.new(match[:year].to_i, month, match[:first_day].to_i),
            last: Date.new(match[:year].to_i, month, match[:last_day].to_i), evidence: match[0] }
        end
      rescue Date::Error
        { first: nil, last: nil, evidence: match[0] }
      end

      def bounded_span?(first, last)
        first && last && last >= first && (last - first).to_i < MAX_SCHEDULE_DAYS
      end

      # Preserve source clock evidence for review without choosing a DST fold,
      # shifting a spring gap, or inventing an unknown end clock.
      def unresolved_window(date, text:, from: nil, to: nil)
        from ||= fold(text).match(/\bod\s+(\d{1,2}[:.]\d{2})/)&.[](1)
        starts_at = clock(date, from)
        ends_at = clock(date, to)
        ends_at = nil if starts_at && ends_at && ends_at <= starts_at
        status = unresolved_clock_status(date, from:, to:)
        { starts_at:, ends_at:, precision: "unknown", complete: false,
          temporal_status: status, temporal_evidence: text.to_s[0, 2000],
          source_date: date&.iso8601, raw_from: from.to_s, raw_to: to.to_s }
      end

      def unresolved_clock_status(date, from:, to:)
        issues = [clock_issue(date, from), clock_issue(date, to)].compact
        issues.find { |issue| %w(ambiguous_local_time nonexistent_local_time).include?(issue) } ||
          (date.nil? ? "unknown_date" : issues.first) || "unresolved_schedule"
      end

      def clock_issue(date, value)
        return "unknown_clock" if value.to_s.empty?
        return "unknown_date" unless date

        match = value.to_s.strip.match(CLOCK_PATTERN)
        return "invalid_clock" unless match && (0..23).cover?(match[:hour].to_i) && (0..59).cover?(match[:minute].to_i)

        local = Time.utc(date.year, date.month, date.day, match[:hour].to_i, match[:minute].to_i)
        count = Time.find_zone!(ZONE).tzinfo.periods_for_local(local).size
        return "nonexistent_local_time" if count.zero?
        return "ambiguous_local_time" if count > 1

        nil
      end

      def clock(date, value)
        match = value.to_s.strip.match(CLOCK_PATTERN)
        return unless date && match
        return unless (0..23).cover?(match[:hour].to_i) && (0..59).cover?(match[:minute].to_i)

        zone = Time.find_zone!(ZONE)
        local_clock = Time.utc(date.year, date.month, date.day, match[:hour].to_i, match[:minute].to_i)
        # Autumn folds have two valid instants for one civil clock. Choosing one
        # silently changes the provider's interval; retain it for manual review.
        return unless zone.tzinfo.periods_for_local(local_clock).size == 1

        value = zone.local(date.year, date.month, date.day, match[:hour].to_i, match[:minute].to_i)
        # Spring DST gaps are invalid civil clock readings, not an instruction to
        # shift a provider's notice silently by an hour.
        return unless value.hour == match[:hour].to_i && value.min == match[:minute].to_i

        value
      end

      def window(date, from: nil, to: nil, overnight: false)
        return unless date
        return { starts_at: clock(date, "00:00"), ends_at: clock(date + 1, "00:00"), precision: "day" } unless from || to

        starts_at = clock(date, from)
        ends_at = clock(date, to)
        return unless starts_at && ends_at

        if ends_at < starts_at
          return unless overnight

          ends_at = clock(date + 1, to)
        end
        return unless ends_at > starts_at

        { starts_at:, ends_at:, precision: "minute" }
      end

      def overnight?(value)
        fold(value).match?(/preko ponoci|narednog dana|sljedeceg dana|sledeceg dana|sutradan|\bnocu\b|\bnocni\b/)
      end
    end
  end
end
