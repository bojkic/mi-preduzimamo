# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module RaceProjectHeroOverride
      def campaign_stat_href
        RaceProjectSelection.published_process(current_organization) ? RaceProjectSelection.process_path : super
      end
    end
  end
end
