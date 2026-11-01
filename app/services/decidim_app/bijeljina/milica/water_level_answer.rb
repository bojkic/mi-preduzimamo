# frozen_string_literal: true

require_relative "read/base"

module DecidimApp
  module Bijeljina
    module Milica
      # Answer shaping over already validated prepared observations only. Raw
      # notice bodies/change labels are not a verified series or a flood forecast.
      module WaterLevelAnswer
        extend Read::Base

        RIVERS = { "Drina" => /\bdrin(?:a|e|i|u|om)\b/, "Sava" => /\bsav(?:a|e|i|u|om)\b/ }.freeze
        TREND = /\b(?:rast\w*|porast\w*|opad\w*|pada|pad|promjen\w*|promen\w*|trend\w*|ris(?:e|es|ing)|fall(?:s|ing)?|chang(?:e|ed|ing))\b/
        UNRESTRICTED_AREAS = %w(bijeljina grad gradsko gradski).freeze

        class << self
          def select(facts, area:, text:)
            selected = filter_explicit_area(facts, area)
            rivers = requested_rivers(text)
            selected = selected.select { |fact| river_matches?(fact, rivers) } if rivers.any?
            stations = requested_stations(facts, text)
            selected = selected.select { |fact| stations.include?(fact["station"]) } if stations.any?
            selected
          end

          def requested_rivers(text)
            query = fold(text)
            RIVERS.filter_map { |name, pattern| name if query.match?(pattern) }
          end

          def shape(facts, text:, locale:)
            return false if facts.empty? || facts.any? { |fact| !supported_fact?(fact) }

            facts.each_with_index do |fact, index|
              parts = [translate("value", locale:, station: fact.fetch("station"), value: fact.fetch("value"), unit: fact.fetch("unit"))]
              parts << translate("trend_unavailable", locale:) if index.zero? && fold(text).match?(TREND)
              parts << translate("observation_time_unknown", locale:) unless fact["observed_at"]
              parts << translate("aggregator_limit", locale:) if index.zero?
              fact["text"] = parts.join(" ")
            end
            true
          end

          private

          def filter_explicit_area(facts, area)
            needle = fold(area)
            return facts if needle.empty? || UNRESTRICTED_AREAS.include?(needle)

            rivers = requested_rivers(area)
            # River inflections are equivalent only when the entire area slot is
            # a river name (optionally prefixed by river/reka/rijeka). An arbitrary
            # neighborhood qualifier must not silently disappear.
            if rivers.one? && needle.match?(/\A(?:(?:na|u|kod) )?(?:(?:rijek[aeiu]|rijeci|rek[aeiu]|reci|river) )?(?:drin|sav)(?:a|e|i|u|om)\z/)
              return facts.select { |fact| river_matches?(fact, rivers) }
            end

            facts.select { |fact| " #{fold(fact["station"])} ".include?(" #{needle} ") }
          end

          def river_matches?(fact, rivers)
            label = fold(fact["station"])
            rivers.any? { |river| label.match?(RIVERS.fetch(river)) }
          end

          def requested_stations(facts, text)
            query = " #{fold(text)} "
            facts.filter_map do |fact|
              # Only a station explicitly named in the prepared source label;
              # no invented river-to-station or neighborhood-to-station mapping.
              names = fact["station"].to_s.scan(/\(([^()]+)\)/).flatten
              fact["station"] if names.any? { |name| fold(name).length >= 3 && query.include?(" #{fold(name)} ") }
            end.uniq
          end

          def supported_fact?(fact)
            fact["kind"] == "water_level_observation" && fact["authority"] == "secondary_aggregator" &&
              fact["station"].is_a?(String) && !fact["station"].strip.empty? && fact["unit"] == "cm" &&
              fact["value"].is_a?(Numeric) && fact["value"].finite?
          end

          def translate(key, locale:, **values)
            I18n.t("decidim.bih.dialogue.water_level_#{key}", locale:, **values)
          end
        end
      end
    end
  end
end
