# frozen_string_literal: true

require "date"
require "json"

module DecidimApp
  module Bijeljina
    # Reference adapter over explicitly supplied community text and household
    # registry files. Ships no local programme or source snapshot.
    module WasteSchedule
      # Optional community source URL, explicitly configured with MI_WASTE_SOURCE_URL.
      DEFAULT_SCHEDULE_URL = "".freeze

      # Community-supplied text; no bundled snapshot.
      BUNDLED_TEXT_PATH = ENV.fetch("MI_WASTE_TEXT_PATH", "").freeze
      SOURCE_CAPTURED_ON = ENV["MI_WASTE_CHECKED_ON"] && Date.iso8601(ENV.fetch("MI_WASTE_CHECKED_ON"))
      DATA_YEAR = ENV["MI_WASTE_YEAR"] && Integer(ENV.fetch("MI_WASTE_YEAR"))

      STRUCTURAL_LABELS =
        (Decidim::Bih::City::WasteSchedule::STRUCTURAL_LABELS + ["Бијељина"]).freeze
      ROUTE_REGISTRY_PATH = ENV.fetch("MI_WASTE_ROUTES_PATH", "").freeze
      PARTIAL_COVERAGE_DISTRICTS = [].freeze
      PARTIAL_COVERAGE_QUERY_PATTERNS = [
        /\brejon\s*[234]\b/,
        /\bcentar\b/,
        /\bpazar\b/,
        /\bgalac\b/,
        /\bbijeljina\b/
      ].freeze

      class Lookup
        WEEK_ORDER = Decidim::Bih::City::WasteSchedule::WEEK_ORDER
        attr_reader :legacy, :registry

        def initialize(legacy, registry)
          @legacy = legacy
          @registry = registry
        end

        def areas
          (legacy.areas + registry.fetch("rows").map { |row| row.fetch("place") }).uniq.sort
        end

        def raw_text
          legacy.raw_text
        end

        def schedule
          areas.index_with { |place| collection_days_for(place) }
        end

        def collection_days_for(query, on: nil)
          result = resolution_for(query, on:)
          result[:days] if result[:status] == :ok
        end

        def resolution_for(query, on: nil)
          date = on&.to_date
          if date && !(Date.iso8601(registry.fetch("valid_from"))..Date.iso8601(registry.fetch("valid_until"))).cover?(date)
            return { status: :unavailable, warning: "schedule_year_not_covered", candidates: [] }
          end

          # Keep explicit settlement words until route selection. "Bijeljina"
          # can be a municipality suffix (Dvorovi, Bijeljina) or the required
          # discriminator for a street that also exists in Janja.
          scoped_query = query.to_s
          needle = normalize(scoped_query)
          district = needle[/\brejon\s*(\d+)\b/, 1]&.to_i
          needle = needle.sub(/\brejon\s*\d+\b/, "").squish
          return { status: :unknown, candidates: [] } if needle.blank?
          # Source headings and municipality qualifiers are not household
          # routes. A substring match must not turn "Bijeljina" into one
          # street's collection day for the entire city or a supplied GPS point.
          if STRUCTURAL_LABELS.any? { |label| normalize(label) == needle } || needle.split.all? { |token| FILLER.include?(token) }
            return { status: :ambiguous, candidates: [], warnings: %w(waste_named_street_or_settlement_required municipality_not_collection_route) }
          end

          resolve_routes(needle, district, date, raw_query: scoped_query)
        end

        # One match is not yet an answer: see +unexplained_tokens+ for the
        # threshold that decides between answering and asking.
        def confirmed_schedule(needle, candidates, legacy_matches, days, date)
          places = matched_places(candidates, legacy_matches)
          explained_names = places + candidates.flat_map { |row| Array(row["aliases"]) + [row["settlement"]] }.compact
          leftover = unexplained_tokens(needle, explained_names)
          return unaccounted_resolution(places, leftover) if leftover.any?

          resolved_schedule(candidates, days, date, places)
        end

        # Label the answer with reviewed source spelling, never with an
        # unresolved or misspelled place from the incoming query.
        def matched_places(candidates, legacy_matches)
          places = candidates.map { |row| row.fetch("place") }
          places += legacy_matches.map(&:first) if places.empty?
          places.uniq
        end

        def resolved_schedule(candidates, days, date, places = [])
          exceptions = matching_exceptions(candidates, date)
          days = exceptions.last.fetch("days", days) if exceptions.any?
          settlements = candidates.filter_map { |row| row["settlement"] }.uniq
          { status: :ok, days: WEEK_ORDER & days, rows: candidates, places:, settlements:, source_url:,
            source_checked_at: candidates.any? ? Date.iso8601(registry.fetch("captured_on")) : source_checked_at,
            validity: { starts_on: registry.fetch("valid_from"), ends_on: registry.fetch("valid_until"), recurrence: "weekly", timezone: registry.fetch("timezone") },
            warnings: exceptions.empty? ? ["regular_schedule_exceptions_not_verified"] : [] }
        end

        def source_provider
          registry["provider"].to_s.strip.presence || "Odvoz otpada zajednice"
        end

        def source_kind
          "Program odvoza otpada za #{DATA_YEAR}. godinu, redovni sedmični raspored"
        end

        def source_checked_at
          SOURCE_CAPTURED_ON
        end

        def source_url
          WasteSchedule.schedule_url
        end

        def partial_coverage_gap_for(query)
          WasteSchedule.partial_coverage_gap_for(query)
        end

        private

        def resolve_routes(needle, district, date, raw_query:)
          identity_conflict = unresolved_identity_schedule(needle, district, date)
          return identity_conflict if identity_conflict

          conflict = conflicting_address_rows(needle, district, raw_query:)
          return ambiguous_resolution(conflict) if conflict

          candidates = route_candidates(needle, district, raw_query:)
          groups = candidates.group_by do |row|
            [normalize(row.fetch("settlement", "")), row.fetch("district"), normalize(row.fetch("place"))]
          end
          legacy_matches = legacy_candidates(needle, district, candidates, groups)
          return ambiguous_resolution(candidates) if ambiguous_matches?(groups, legacy_matches)

          days = matched_days(groups, candidates, legacy_matches)
          return { status: :unknown, candidates: [] } if days.empty?

          confirmed_schedule(needle, candidates, legacy_matches, days, date)
        end

        # Source-reviewed identity groups preserve ambiguous source segments.
        # These are registry data, not a conversational spelling/intent router.
        def unresolved_identity_schedule(needle, district, date)
          registry.fetch("unresolved_identity_groups", []).each do |group|
            rows = registry.fetch("rows").select { |row| group.fetch("row_ids").include?(row.fetch("id")) }
            next if rows.empty? || district && rows.none? { |row| row.fetch("district") == district }
            places = rows.map { |row| row.fetch("place") }
            next unless rows.any? { |row| row_name_forms(row).any? { |place| phrase_match?(needle, place) } } && unexplained_tokens(needle, places).empty?

            days = rows.map { |row| WEEK_ORDER.fetch(row.fetch("weekday") - 1) }.uniq
            return resolved_schedule(rows, days, date, places).merge(
              status: :conflicting, identity_note: group.fetch("reason"),
              warnings: %w(source_street_segments_unresolved regular_schedule_exceptions_not_verified))
          end
          nil
        end

        # Citizen-supplied districts cannot move a reviewed house number into
        # another route. Inspect address siblings before district filtering.
        def conflicting_address_rows(needle, district, raw_query:)
          return unless district

          rows = registry.fetch("rows")
          query = address_query(needle)
          scope = matching_numbered_scope(rows, query)
          return unless scope && query != scope.first

          candidates = address_scope_candidates(needle, rows, raw_query:)
          candidates if candidates.any? { |row| row.fetch("district") != district }
        end

        def route_candidates(needle, district, raw_query:)
          rows = registry.fetch("rows").select { |row| district.nil? || row.fetch("district") == district }
          rows, needle = settlement_scoped_rows(rows, needle)
          address_rows = address_scope_candidates(needle, rows, raw_query:)
          return address_rows if address_rows

          exact = rows.select { |row| row_name_forms(row).include?(needle) }
          exact.empty? ? rows.select { |row| row_name_forms(row).any? { |name| phrase_match?(needle, name) } } : exact
        end

        # A settlement named alongside a street narrows duplicate source rows.
        # A bare settlement remains a route query, and a municipality suffix
        # such as "Dvorovi, Bijeljina" does not replace the named settlement.
        def settlement_scoped_rows(rows, needle)
          return [rows, needle] if rows.any? { |row| row_name_forms(row).include?(needle) }

          settlements = rows.filter_map { |row| normalize(row["settlement"]) if row["settlement"].present? }.uniq
          named = settlements.select { |settlement| phrase_match?(needle, settlement) }
          return [rows, needle] unless named.one?

          remainder = " #{needle} ".sub(" #{named.first} ", " ").squish
          return [rows, needle] if remainder.blank?

          [rows.select { |row| normalize(row["settlement"]) == named.first }, remainder]
        end

        def row_name_forms(row)
          ([row.fetch("place")] + Array(row["aliases"])).map { |name| normalize(name) }.uniq
        end

        # Source-listed house numbers narrow a street's coverage. An exact
        # unqualified street row must not hide a sibling address exception.
        # Only explicit number lists are parsed; ranges are never inferred.
        def address_scope_candidates(needle, rows, raw_query:)
          query = address_query(needle)
          scope = matching_numbered_scope(rows, query)
          return unless scope

          family = address_family(rows, scope.first)
          return family if raw_query.match?(/\d\p{L}?\s*[-–—]\s*\d/)

          exact = family.select { |row| listed_address?(query, row.fetch("place")) || normalize(row.fetch("place")) == query }
          # A bare street's exact row does not outrank its numbered siblings.
          query == scope.first || exact.empty? ? family : exact
        end

        def matching_numbered_scope(rows, query)
          rows.filter_map { |row| numbered_scope(row.fetch("place")) }
              .find { |street, _| query == street || query.start_with?("#{street} ") }
        end

        def address_family(rows, street)
          rows.select { |row| normalize(row.fetch("place")) == street || numbered_scope(row.fetch("place"))&.first == street }
        end

        # Strip only explicit local city/locative/street qualifiers. Unknown
        # place words remain and cannot silently confer an address match.
        def address_query(needle)
          needle.sub(/\A(?:(?:bijeljina|bijeljini|u|na|ulica|ulici|ulice|ulicu|ul) ){1,5}/, "")
        end

        def numbered_scope(place)
          match = normalize(place).match(/\A(.+?) br (\d+[a-z]?(?: \d+[a-z]?)*)\z/)
          [match[1], match[2].split] if match
        end

        def listed_address?(needle, place)
          scope = numbered_scope(place)
          return false unless scope

          query = address_query(needle)
          scope.last.any? { |number| ["#{scope.first} #{number}", "#{scope.first} br #{number}", "#{scope.first} broj #{number}"].include?(query) }
        end

        # Plain-text lines the structured registry does not already cover. The
        # registry and the extraction describe the same programme, so a
        # reviewed registry row for a place makes the legacy line for that same
        # place one answer, not a second candidate.
        def legacy_candidates(needle, district, candidates, groups)
          return [] if district

          matches = legacy.schedule.select { |place, _| normalize(place) == needle }.to_a
          matches = legacy.schedule.select { |place, _| phrase_match?(needle, normalize(place)) }.to_a if candidates.empty? && matches.empty?
          matches.reject { |place, _| covered_by_registry?(place, groups) }
        end

        def covered_by_registry?(place, groups)
          groups.keys.any? { |(_, _, name)| name == normalize(place) }
        end

        def ambiguous_matches?(groups, legacy_matches)
          groups.size > 1 || legacy_matches.size > 1 || (groups.any? && legacy_matches.any?)
        end

        def ambiguous_resolution(candidates)
          { status: :ambiguous, warning: "street_or_route_required",
            candidates: candidates.map do |row|
              { place: row.fetch("place"), settlement: row["settlement"], district: row.fetch("district"), scope: row["scope"],
                label: [row.fetch("place"), row["settlement"], "rejon #{row.fetch('district')}"].compact.uniq.join(" — ") }
            end.uniq.first(12) }
        end

        def matched_days(groups, candidates, legacy_matches)
          if groups.one?
            candidates.map { |row| WEEK_ORDER.fetch(row.fetch("weekday") - 1) }.uniq
          elsif legacy_matches.one?
            legacy_matches.first.last
          else
            []
          end
        end

        def matching_exceptions(rows, date)
          return [] unless date

          ids = rows.map { |row| row.fetch("id") }
          Array(registry["exceptions"]).select do |exception|
            exception["reviewed"] == true && exception["source_url"].present? && exception["date"] == date.iso8601 &&
              ids.intersect?(Array(exception["route_ids"]))
          end
        end

        def normalize(value)
          Decidim::Bih::Text.fold(value.to_s).gsub(/[^a-z0-9]+/, " ").squish
        end

        def phrase_match?(query, place)
          return false if place.length < 4 || query.length < 4

          " #{query} ".include?(" #{place} ") || " #{place} ".include?(" #{query} ")
        end

        # Words that qualify a place without naming one, so the place still
        # explains the whole query when they are left over. Matched EXACTLY,
        # never fuzzily: "Bijeljina" is the reviewed municipal suffix this
        # lookup already strips, and "Bijelina" is not it.
        FILLER = %w(
          bijeljina grad gradu mjesto mjestu naselje naselju naselja
          ulica ulici ulice ulicu ul mjesna mjesnoj mesna mesnoj zajednica zajednici mz
          komsiluk komsiluku broj br bb kod rejon reon
        ).freeze

        # A partial phrase match cannot explain unrelated place words or
        # house numbers. Keep unexplained tokens and request clarification;
        # unknown places must never borrow a neighbouring route's days.
        def unexplained_tokens(needle, places)
          return [] if places.any? { |place| listed_address?(needle, place) }

          remaining = " #{needle} "
          places.each { |place| remaining = remaining.sub(" #{normalize(place)} ", " ") }
          remaining.split.reject { |token| FILLER.include?(token) || (token.length < 3 && !token.match?(/\d/)) }
        end

        def unaccounted_resolution(places, leftover)
          { status: :ambiguous, warning: "place_in_query_not_confirmed",
            candidates: places.first(8).map { |place| { place: } }, unexplained: leftover.first(8) }
        end
      end

      class << self
        # The Bijeljina source PDF URL (env-overridable).
        def schedule_url
          ENV.fetch("MI_WASTE_SOURCE_URL", DEFAULT_SCHEDULE_URL)
        end

        # Memoized parsed schedule built from the locally held snapshot, so the
        # lookup works offline without re-downloading/re-parsing the PDF.
        def configured?
          File.file?(BUNDLED_TEXT_PATH) && File.file?(ROUTE_REGISTRY_PATH) && DATA_YEAR && SOURCE_CAPTURED_ON
        end

        def default
          raise Decidim::Bih::City::WasteScheduleError, "community waste data is not configured" unless configured?
          @default ||= Lookup.new(
            Decidim::Bih::City::WasteSchedule.from_text(File.read(BUNDLED_TEXT_PATH), structural_labels: STRUCTURAL_LABELS),
            JSON.parse(File.read(ROUTE_REGISTRY_PATH))
          )
        end

        def partial_coverage_gap_for(query)
          return nil if PARTIAL_COVERAGE_DISTRICTS.empty?

          folded = Decidim::Bih::Text.fold(query)
          return nil if folded.blank?
          return nil unless PARTIAL_COVERAGE_QUERY_PATTERNS.any? { |pattern| folded.match?(pattern) }

          {
            districts: PARTIAL_COVERAGE_DISTRICTS,
            source_url: schedule_url
          }
        end

        def coverage_detail
          rows = default.registry.fetch("rows")
          districts = rows.map { |row| row.fetch("district") }.uniq.sort.join(",")
          "source_year=#{DATA_YEAR} covered_entries=#{default.areas.size} household_districts=#{districts} " \
            "structured_household_rows=#{rows.size} container_routes=not_indexed exceptions=not_verified"
        end
      end
    end
  end
end
