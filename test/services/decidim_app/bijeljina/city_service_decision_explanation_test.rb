# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class CityServiceDecisionExplanationTest < ActiveSupport::TestCase
      test "every automation and publication blocker has a full sentence in every supported locale" do
        reasons = CityServiceDecisionExplanation::REASONS
        assert_empty((CityServiceDecisionExplanation::AUTOMATION_BLOCKERS + CityServiceDecisionExplanation::PUBLICATION_BLOCKERS).uniq - reasons)
        %w(sr bs hr sr-Cyrl en).each do |locale|
          reasons.each do |reason|
            key = "decidim_app.admin.city_service_events.decision_explanations.#{reason}"
            assert I18n.exists?(key, locale), "Missing #{locale} sentence for #{reason}"
            sentence = I18n.t(key, locale:, station: "G. Brodac 2", area: "Brodac", count: 3)
            assert_match(/[.!?]\z/, sentence, "#{locale}/#{reason} is not a complete sentence")
            assert_no_match(/Translation missing|%\{/, sentence)
          end
        end
      end
    end
  end
end
