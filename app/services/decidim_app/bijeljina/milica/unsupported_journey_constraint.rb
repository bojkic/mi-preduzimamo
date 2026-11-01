# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # The timetable search currently proves departure or fastest-arrival
      # journeys only. Detect explicit constraints before a read can drop them.
      module UnsupportedJourneyConstraint
        CLOCK = /(?:[01]?\d|2[0-3])(?::[0-5]\d)?/
        ARRIVE_BY = /\b(?:stign\w*|stic\w*|dolaz\w*|dodj\w*|doci|arriv\w*|budem|biti|get|getting)\b.{0,100}\b(?:do|by|najkasnije|prije|pre|before)\s+(?:u\s+)?#{CLOCK}\b/
        ORDERED_VIA = /\b(?:od|iz|from)\b.{2,100}?\b(?:do|to)\b.{2,100}?\b(?:pa|onda|then)\s+(?:do|to)\b/
        VIA = /\b(?:preko|via)\s+(?!(?:viber\w*|whatsapp\w*|messenger\w*|instagram\w*|chata?\b|aplikacij\w*)\b)[a-z0-9]/
        JOURNEY = /\b(?:autobus\w*|bus|busom|busa|linij\w*|polaz\w*|voznj\w*|stajal\w*|stanic\w*|putuj\w*)\b|
                   \b(?:od|iz|from)\b.{1,100}\b(?:do|to)\b|
                   \b(?:kako|how)\b.{0,30}\b(?:stign\w*|stic\w*|dodj\w*|doci|arriv\w*|get)\b/x

        module_function

        def call(text)
          folded = Decidim::Bih::Text.fold(text.to_s)
          return [] if folded.length > 500 || !JOURNEY.match?(folded)

          constraints = []
          constraints << :arrive_by if ARRIVE_BY.match?(folded)
          unless folded.match?(/\b(?:bez|ne treba)\s+(?:preko|via)\b/)
            constraints << :ordered_via if ORDERED_VIA.match?(folded) || VIA.match?(folded)
          end
          constraints
        end
      end
    end
  end
end
