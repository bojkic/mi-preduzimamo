# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Extracts a citizen-supplied locative span, not an area identity. The
      # existing tenant matcher still resolves names, inflections and conflicts;
      # in particular a shared MZ/komsiluk name must remain ambiguous.
      module ActivityQuestionContext
        ACTIVITY = /\b(?:
          sta[ ](?:ima|se[ ]desava|se[ ]dogadja)|dogadjaj\w*|aktivnost\w*|okupljan\w*|sastan\w*|volont\w*|projek\w*|
          events?|activity|meetings?|gatherings?|volunteer\w*|projects?
        )\b/x
        RELATIVE_PLACE = /\A(?:mom|mojem|mojoj|mome|moje|moj|nasem|ovom|ovoj|blizini|okolini|my|our|this|nearby)\z/
        COMPLEX_PLACE = /\b(?:i|ili|ali|pa|onda|osim|nego|ne|nije|nemoj|prijavi|posalji|objavi|u|na|kod|iz|od|do|za|and|or|except)\b/
        TIME_SPAN = /\A(?:ponedjeljak|ponedeljak|utorak|srijedu|sredu|cetvrtak|petak|subotu|nedjelju|nedelju|naredn\w*|sljedec\w*|sledec\w*|jutr\w*|podne|vece\w*|[0-9]+)\b/
        TIME_SUFFIX = /[ ](?:
          danas|sutra|uskoro|today|tomorrow|soon|this[ ]weekend|next[ ]weekend|
          (?:za[ ])?(?:vikend|ovog[ ]vikenda|ovaj[ ]vikend|sljedeceg[ ]vikenda|sledeceg[ ]vikenda|
          sljedeci[ ]vikend|sledeci[ ]vikend|narednog[ ]vikenda|naredni[ ]vikend)
        )\z/x
        Candidate = Data.define(:query, :warning) do
          def coverage = { "supplied_area_query" => query, "area_query_source" => "citizen_activity_locative" }
        end

        module_function

        def call(action:, topic:, entities:)
          return unless applicable?(action, topic, entities)

          raw = entities["query"].to_s
          return if raw.length > 160

          text = Decidim::Bih::Text.fold(raw)
          return unless ACTIVITY.match?(text)

          span = text[/\b(?:u|na podrucju|in|within) (.+)\z/, 1]
          return unless span

          span = span.sub(TIME_SUFFIX, "")
          return if relative_or_time_span?(span)

          span = span.sub(/\Akomsiluku /, "komsiluk ").sub(/\A(?:mjesnoj|mesnoj) zajednici /, "mz ")
          return if entities["area_query"].to_s.strip.present? && !restores_explicit_qualifier?(span, entities["area_query"])

          Candidate.new(span[0, 100], place_warning(span, text))
        end

        def applicable?(action, topic, entities)
          %w(ask_information choose_area).include?(action) && %w(neighborhood participation community volunteer).include?(topic) &&
            %w(area_slug street address).none? { |key| entities[key].to_s.strip.present? }
        end

        # Recover a literal citizen-supplied kind dropped from the same name by
        # understanding. Never replace a different/typed area or infer a kind.
        def restores_explicit_qualifier?(span, supplied)
          span.match?(/\A(?:mz|komsiluk) /) && span.sub(/\A(?:mz|komsiluk) /, "") == Decidim::Bih::Text.fold(supplied)
        end

        def relative_or_time_span?(span)
          span.split.first&.match?(RELATIVE_PLACE) || %w(komsiluku naselju gradu).include?(span) || TIME_SPAN.match?(span)
        end

        def place_warning(span, text)
          "area_name_ambiguous" if span.length > 100 || span.split.length > 8 || COMPLEX_PLACE.match?(span) || text.match?(/\b(?:ne u|nije u|osim u|not in)\b/)
        end

        # A closed vague-future expression means a bounded activity search,
        # not evidence that an event exists or a change to transport calendars.
        def soon?(entities)
          entities["date"].to_s.empty? && %w(uskoro soon).include?(Decidim::Bih::Text.fold(entities["time_expression"]))
        end
      end
    end
  end
end
