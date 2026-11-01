# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Parking is already the accepted topic. Current location is not a zone;
      # only an explicit color may select the existing reviewed payment facts.
      module ParkingQuestion
        CURRENT_LOCATION = /\b(?:
          ovdje|ovde|tu|here|
          (?:(?:na|za|u|at|for|in)[ ])?(?:moj\w*|ovoj|ovu|ovom|trenutn\w*|my|this|current)[ ](?:lokacij\w*|mjest\w*|mest\w*|location|spot)|
          u[ ]kojoj[ ]sam[ ](?:parking[ ])?zoni|koja[ ]je[ ]moja[ ](?:parking[ ])?zona|
          which[ ](?:parking[ ])?zone[ ]am[ ]i[ ]in
        )\b/x
        NEGATED = /\b(?:ne|nije|nisam|nisu|nemoj|not|no|isnt|isn|dont|don)\b/
        # A street was named or asked about: the zone comes from the reviewed
        # street/segment records, and an unknown street is asked for by name.
        STREET_MENTION = /\b(?:ulic\w*|ul|street)\b/
        COLOR_QUERY = { white: "SMS za bijelu zonu", red: "SMS za crvenu zonu", blue: "SMS za plavu zonu" }.freeze

        module_function

        # nil preserves the original question; :clarify needs a visible zone;
        # a string only refines the directory question, never a saved location.
        def call(query:, location: nil)
          question = Decidim::Bih::Text.fold(query)
          return :clarify if question.empty? && location
          return if NEGATED.match?(question)

          colors = DirectoryAnswer::ZONE_COLORS.select { |_key, pattern| pattern.match?(question) }.keys
          return if colors.size > 1

          color = colors.first
          return COLOR_QUERY.fetch(color) if color && /\A(?:(?:u|in(?:[ ]the)?)[ ])?#{DirectoryAnswer::ZONE_COLORS.fetch(color)}(?:[ ](?:parking[ ])?zon\w*)?\z/.match?(question)
          return unless CURRENT_LOCATION.match?(question)
          return :clarify unless color

          # Keep day/monthly/hours/method qualifiers for DirectoryAnswer's
          # existing conservative selection; remove only the deictic phrase.
          question.gsub(CURRENT_LOCATION, " ").squish
        end

        def street_mention?(query)
          STREET_MENTION.match?(Decidim::Bih::Text.fold(query))
        end
      end
    end
  end
end
