# frozen_string_literal: true

require "date"
require "decidim/bih/transliterator"

module DecidimApp
  module Bijeljina
    module Milica
      # Only a fully specified, published line/direction/stop question enters
      # the deterministic timetable path. Other wording stays with the usual
      # conversation reader instead of having a partial regex guess its facts.
      module ExactRouteQuestion
        INITIAL = /\A(?:na\s+liniji|linija|on\s+line|line)\s+(?<route>[GP]\d{1,2})\s*,?\s*(?:smjer|smer|direction)\s+(?<direction>[AB])\s*,?\s*
                   (?<date>20\d{2}-\d{2}-\d{2})\s*:\s*(?:(?:koji\s+je|which\s+is)\s+)?
                   (?<kind>prvi|najraniji|sljedeći|sledeći|posljednji|poslednji|zadnji|najkasniji|first|next|last)\s+
                   (?:(?:objavljeni|objavljen|published)\s+)?polazak\s+(?:(?:od|sa|from)\s+)?(?<origin>.{2,120}?)\s*
                   (?:→|->|\s+do\s+|\s+to\s+)(?<destination>.{2,120}?)\s+
                   (?:nakon|poslije|posle|after)\s+(?<time>(?:[01]\d|2[0-3]):[0-5]\d)\s*[?.]?\z/ix
        CHANGED_THRESHOLD = /\A(?:pomjeri|pomeri|promijeni|promeni|move|change)\s+
                             (?:granicu|vrijeme|vreme|threshold|time)\s+(?:na|to)\s+
                             (?:poslije|posle|nakon|after)\s+(?<time>(?:[01]\d|2[0-3]):[0-5]\d)(?<tail>.*)\z/ix
        LAST_FOLLOWUP = /\A(?:(?:koji\s+je|which\s+is)\s+)?(?:posljednji|poslednji|zadnji|najkasniji|last)\s+
                         (?:(?:objavljeni|objavljen|published)\s+)?polazak\s+iste\s+linije\s+i\s+(?:smjera|smera)
                         (?:\s+(?:tog\s+dana|za\s+isti\s+datum|na\s+istoj\s+relaciji|do\s+istog\s+odredišta)){0,2}\s*[?.]?\z/ix

        Query = Data.define(:origin_label, :destination_label, :date, :after_time, :route_code, :direction, :mode) do
          def slot
            { "origin_query" => origin_label, "destination_query" => destination_label, "date" => date,
              "time" => after_time, "route_code" => route_code, "direction" => direction, "query_kind" => "exact_route" }
          end

          def tool_arguments
            { "origin_label" => origin_label, "destination_label" => destination_label, "date" => date,
              "after_time" => after_time, "route_code" => route_code, "direction" => direction,
              "mode" => mode.to_s }
          end
        end

        module_function

        def call(text, previous: nil)
          latin = Decidim::Bih::Transliterator.to_latin(text.to_s).strip
          return if latin.length > 500

          if (match = INITIAL.match(latin))
            date = Date.iso8601(match[:date]).iso8601
            return unless date == match[:date]

            origin = match[:origin].strip
            destination = match[:destination].strip
            return unless origin.length.between?(2, 120) && destination.length.between?(2, 120)

            mode = %w(posljednji poslednji zadnji najkasniji last).include?(match[:kind].downcase) ? :last : :next
            return Query.new(origin_label: origin, destination_label: destination, date:, after_time: match[:time],
                             route_code: match[:route].upcase, direction: match[:direction].upcase, mode:)
          end

          return unless valid_previous?(previous)

          if (match = CHANGED_THRESHOLD.match(latin))
            return unless same_scope_tail?(match[:tail])

            return from_slot(previous, after_time: match[:time], mode: :next)
          end
          return from_slot(previous, after_time: previous.fetch("time"), mode: :last) if LAST_FOLLOWUP.match?(latin)
        rescue Date::Error
          nil
        end

        def valid_previous?(slot)
          slot.is_a?(Hash) && slot["query_kind"] == "exact_route" && %w(A B).include?(slot["direction"]) &&
            slot["route_code"].to_s.match?(/\A[GP][1-9]\d?\z/) &&
            slot["date"].to_s.match?(/\A20\d{2}-\d{2}-\d{2}\z/) &&
            slot["time"].to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/) &&
            %w(origin_query destination_query).all? { |key| slot[key].is_a?(String) && slot[key].length.between?(2, 120) }
        end

        def from_slot(slot, after_time:, mode:)
          Query.new(origin_label: slot.fetch("origin_query"), destination_label: slot.fetch("destination_query"),
                    date: slot.fetch("date"), after_time:, route_code: slot.fetch("route_code"),
                    direction: slot.fetch("direction"), mode:)
        end

        def same_scope_tail?(tail)
          clause = tail.to_s.strip.sub(/\A[;,.]\s*/, "").sub(/[?.]\z/, "").strip
          return true if clause.empty?
          return false unless tail.to_s.lstrip.match?(/\A[;,]/) && clause.length <= 160
          return false if clause.match?(/\d|\b(?:nisu|nije|different|mijenja|menja)\b/i)

          clause.match?(/\b(?:relacija|relaciju|relaciji|ruta|route)\b/i) &&
            clause.match?(/\b(?:datum|date)\b/i) &&
            clause.match?(/\b(?:ostaju|ostaje|isti|ista|same|remain)\b/i)
        end
      end
    end
  end
end
