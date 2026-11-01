# frozen_string_literal: true

require "digest"
require "nokogiri"

module DecidimApp
  module Bijeljina
    class ElectricityOutageParser
      SOURCE_KEY = "electricity_outages"
      PARSER_VERSION = "electricity_outage_parser_v3"
      Event = Struct.new(
        :source_key, :source_label, :provider, :source_url, :source_fingerprint,
        :source_occurrence_id, :content_version, :source_published_at, :source_updated_at, :lifecycle, :extraction_metadata,
        :fetched_at, :parser_version, :event_type, :severity, :targeting_level,
        :affected_area_slugs, :title, :summary, :affected_text, :recommended_action,
        :viber_text, :starts_at, :ends_at, :confidence, :classifier_reasons,
        keyword_init: true
      )

      # ONE definition of what a resident reads about an outage. Milica
      # reconstructs this text to prove a stored notice is still the parser's
      # own before it shortens it, so the format cannot live in two places —
      # a copy that drifts silently turns every answer into a fallback.
      #
      # It answers when, where and why, in that order. The source's own place
      # label ("Naseljena mjesta:", "Ulice:") and its stated reason are kept
      # verbatim so this stays quotable against the provider's page. The
      # utility's district and feeder are deliberately absent: they identify a
      # circuit, not a place, and they remain in extraction_metadata for the
      # operator.
      def self.citizen_summary(affected:, starts_at:, ends_at:, reason:)
        [
          "Planirano isključenje struje #{starts_at.strftime("%d.%m.%Y.")} od #{starts_at.strftime("%H:%M")} " \
          "do #{ends_at.strftime("%H:%M")}.",
          sentence(affected),
          ("Razlog: #{sentence(reason)}" if reason.present?)
        ].compact.join(" ")
      end

      # The headline a resident scans on the board. Milica rebuilds it through
      # this method too (see Milica::EventAnswer), for the same reason as
      # citizen_summary: two copies of the wording drift.
      def self.citizen_title(affected)
        "Planirano isključenje struje: #{short_places(affected, 80)}"
      end

      def self.viber_text(affected:, date:, from:, to:)
        "#{short_places(affected, 70)}: planirano isključenje struje #{date&.strftime("%d.%m.")} od #{from} do #{to}."
      end

      # "Naseljena mjesta:" says nothing a list of village names does not; it
      # stays in the summary, which quotes the source. A long list is cut
      # between places and says so, never mid-name ("Miljev").
      SETTLEMENT_LABEL = /\Anaseljen[ao] mjest[ao]\s*:\s*/i

      def self.short_places(affected, limit)
        text = affected.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip.sub(SETTLEMENT_LABEL, "")
        return text if text.length <= limit

        head = text[0, limit]
        # Cut between list items first: "Donje Crnjelovo" is one place.
        boundary = head.rindex(/[,;]/) || head.rindex(" ")
        head = head[0, boundary] if boundary&.positive?
        "#{head.sub(/[ ,;:–-]+\z/, "")}…"
      end

      # The source writes fragments, not sentences.
      def self.sentence(value)
        text = value.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip
        text.end_with?(".", "!", "?") ? text : "#{text}."
      end

      def initialize(organization:, source: CityServiceSources.fetch(SOURCE_KEY), area_matcher: nil)
        @source = source
        @area_matcher = area_matcher || CityServiceAreaMatcher.new(organization:)
      end

      def call(html:, source_url: source.fetch(:source_url), fetched_at: Time.current)
        document = Nokogiri::HTML(html.to_s)
        rows = source_rows(document)
        # Older explicitly dated sentence/three-column formats remain supported;
        # a source-shaped six-column table never falls back to heading scanning.
        rows = legacy_rows(document, fetched_at:) unless document.css("table").any? { |table| six_column_table?(table) }
        occurrences = Hash.new(0)
        occurrence_counts = rows.group_by { |row| [row[:date], row[:tj], row[:feeder]] }.transform_values(&:size)
        rows.filter_map do |row|
          key = [row[:date], row[:tj], row[:feeder]]
          ordinal = occurrences[key]
          occurrences[key] += 1
          event_from_row(row.merge(linkable: occurrence_counts[key] == 1), source_url:, fetched_at:, ordinal:)
        end.uniq(&:source_fingerprint)
      end

      def complete_snapshot?(html:)
        return false unless structurally_complete_snapshot?(html:)

        document = Nokogiri::HTML(html.to_s)
        valid_snapshot_headings?(document) && valid_snapshot_rows?(document, expected_count: snapshot_data_rows(document).size)
      end

      def structurally_complete_snapshot?(html:)
        raw = html.to_s
        return false if raw.scan(/<table\b/i).size != raw.scan(%r{</table\s*>}i).size

        document = Nokogiri::HTML(raw)
        return false if document.css("table").empty?

        snapshot_data_rows(document).all? { |row| row.css("th,td").size == 6 }
      end

      def snapshot_data_rows(document)
        document.css("table tr").reject { |row| CityServiceTime.fold(clean(row.css("th,td").first&.text)) == "tj" }
      end

      def valid_snapshot_headings?(document)
        headings = document.css("p, h1, h2, h3").select { |node| CityServiceTime.explicit_date?(node.text) }
        headings.any? && headings.all? { |node| CityServiceTime.date(node.text, reference: nil).present? }
      end

      def valid_snapshot_rows?(document, expected_count:)
        extracted = source_rows(document)
        extracted.size == expected_count && extracted.all? do |row|
          CityServiceTime.window(row[:date], from: row[:from], to: row[:to], overnight: CityServiceTime.overnight?(row[:reason]))
        end
      end

      private

      attr_reader :source, :area_matcher

      def six_column_table?(table)
        table.css("tr").any? { |row| row.css("th,td").size == 6 }
      end

      def source_rows(document)
        date = nil
        date_evidence = nil
        document.css("p, h1, h2, h3, table").flat_map do |node|
          next [] if node.ancestors("table").any?

          unless node.name == "table"
            # Invalid date headings clear context so their table cannot borrow
            # yesterday's valid heading.
            if CityServiceTime.explicit_date?(node.text)
              date = CityServiceTime.date(node.text, reference: nil)
              date_evidence = clean(node.text)
            end
            next []
          end
          node.css("tr").filter_map { |row| six_column_row(row, date:)&.merge(date_evidence:) }
        end
      end

      def six_column_row(row, date:)
        values = row.css("th,td").map { |cell| clean(cell.text) }
        return unless values.size == 6

        tj, feeder, affected_text, reason, from, to = values
        return if CityServiceTime.fold(tj) == "tj"
        return if affected_text.empty? || feeder.empty?

        { date:, tj:, feeder:, affected_text:, reason:, from:, to: }
      end

      def legacy_rows(document, fetched_at:)
        document.css("tr, li, p").filter_map do |node|
          line = clean(node.text)
          date = CityServiceTime.date(line, reference: fetched_at)
          range = CityServiceTime.ranges(line).first
          next unless date && range

          affected = clean(CityServiceTime.fold(line).sub(CityServiceTime::DATE_PATTERN, " ").sub(CityServiceTime::RANGE_PATTERN, " "))
          { date:, tj: "", feeder: "", affected_text: affected, reason: "", from: range[:from], to: range[:to], legacy: true }
        end
      end

      def event_from_row(row, source_url:, fetched_at:, ordinal:)
        window = CityServiceTime.window(row.fetch(:date), from: row[:from], to: row[:to], overnight: CityServiceTime.overnight?(row[:reason]))
        window ||= CityServiceTime.unresolved_window(row[:date], text: [row[:date_evidence], row[:from], row[:to], row[:reason]].join(" "),
                                                                 from: row[:from], to: row[:to])
        affected = row.fetch(:affected_text)
        area = area_matcher.match(affected)
        identity = [SOURCE_KEY, source_url, row[:date]&.iso8601 || row[:date_evidence], row[:tj], row[:feeder], row[:legacy] ? affected : ordinal].join("|")
        fingerprint = Digest::SHA256.hexdigest(identity)[0, 24]
        version = Digest::SHA256.hexdigest([PARSER_VERSION, row[:tj], row[:feeder], affected, row[:reason], row[:from], row[:to]].join("|"))
        summary = row_summary(row, window, affected:)
        Event.new(
          source_key: source.fetch(:key), source_label: source.fetch(:label), provider: source.fetch(:provider), source_url:,
          source_fingerprint: fingerprint, source_occurrence_id: fingerprint, content_version: version, source_published_at: nil, lifecycle: "scheduled",
          extraction_metadata: row_metadata(row, window, area),
          fetched_at:, parser_version: PARSER_VERSION, event_type: "planned_outage", severity: "service_outage",
          targeting_level: area.targeting_level, affected_area_slugs: area.slugs,
          title: self.class.citizen_title(affected), summary:, affected_text: affected,
          recommended_action: "Provjerite uređaje i planirajte poslove prije najavljenog isključenja.",
          viber_text: self.class.viber_text(affected:, date: row[:date], from: row[:from], to: row[:to]),
          starts_at: window[:starts_at], ends_at: window[:ends_at], confidence: area.unknown? ? 0.65 : 0.9,
          classifier_reasons: ["deterministic_electricity_parser", ("location_not_matched" if area.unknown?)].compact
        )
      end

      def row_metadata(row, window, area)
        { "tj" => row[:tj], "feeder" => row[:feeder], "reason" => row[:reason], "source_occurrence_linkable" => row[:linkable],
          "coverage" => (area.respond_to?(:coverage) ? (area.coverage || {}) : {}),
          "confidence_by_field" => { "type" => "source_table", "time" => window[:temporal_status] || "explicit_validated_clock",
                                     "place" => area.unknown? ? "unknown" : "reviewed_alias" },
          "temporal_precision" => window[:precision], "timezone" => CityServiceTime::ZONE,
          "complete" => window[:complete] != false, "temporal_status" => window[:temporal_status] || "resolved",
          "temporal_evidence" => window[:temporal_evidence], "source_date" => window[:source_date],
          "raw_from" => row[:from], "raw_to" => row[:to] }
      end

      # What a resident reads on the board. It answers, in this order, the three
      # questions an outage notice exists to answer: when, where, why.
      #
      # The date is NOT optional. Without it the notice said only "od 08:00 do
      # 10:00", which is unreadable on a board carrying several days at once.
      #
      # TJ and Objekat (the utility's district and feeder, e.g. "DV 10KV
      # DVOROVI ŠKOLA") are deliberately absent: they identify a circuit, not a
      # place anyone lives, and they are retained as operator evidence in
      # extraction_metadata. Razlog stays — a resident acts differently on
      # "zamjena stubova" than on "kvar".
      def row_summary(row, window, affected:)
        return "Planirano isključenje za #{affected}; izvorni termin #{row[:from]}–#{row[:to]} zahtijeva pregled." if window[:complete] == false

        self.class.citizen_summary(affected:, starts_at: window[:starts_at], ends_at: window[:ends_at], reason: row[:reason])
      end

      def clean(value)
        value.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip
      end
    end
  end
end
