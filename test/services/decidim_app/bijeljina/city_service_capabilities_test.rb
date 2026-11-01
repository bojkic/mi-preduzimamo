# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    # The topic inventory Milica consults BEFORE collecting any detail: a
    # topic is supported when a typed reader, a service-event feed, a
    # reviewed source family, a catalogue family or a directory card exists
    # for it. Anything else is refused with a next step, never a slot question.
    class CityServiceCapabilitiesTest < ActiveSupport::TestCase
      test "topics with a reader, a feed or a reviewed source family are supported" do
        %w(waste parking water electricity heating transport roads neighborhood city_service
           air_quality water_levels weather civil_protection bulky_waste police sistem48
           budget gazette donation public_calls volunteer community participation rewards facilities).each do |topic|
          assert CityServiceCapabilities.supported?(topic), "#{topic} has a reader or a source family"
        end
      end

      test "a topic nobody can answer is not supported" do
        assert_not CityServiceCapabilities.supported?("pharmacy_rota")
        assert_not CityServiceCapabilities.supported?("dezurna_apoteka")
        assert_not CityServiceCapabilities.supported?(nil)
        assert_not CityServiceCapabilities.supported?("")
        assert_not CityServiceCapabilities.supported?(:waste_) # a near miss is not a match
      end

      test "every supported topic is a typed dialogue topic" do
        assert_empty CityServiceCapabilities.supported_topics - Decidim::Bih::Concierge::Dialogue::Contracts::TOPICS
        assert_equal CityServiceCapabilities.supported_topics, CityServiceCapabilities.supported_topics.uniq.sort
        assert CityServiceCapabilities.supported_topics.frozen?
      end

      test "the next step for an unsupported topic is the support page" do
        assert_equal Decidim::Bih.public_path("vodic"), CityServiceCapabilities.next_step_for("pharmacy_rota")
        assert_equal Decidim::Bih.public_path("vodic"), CityServiceCapabilities.next_step_for(nil)
      end

      test "a directory card marked with a topic makes that topic supported" do
        card = { key: :apoteke, title: "Dežurne apoteke", keywords: %w(apoteka), answer: "…", source_url: "https://example.org" }

        assert_includes CityServiceCapabilities.directory_topics(entries: [card.merge(topic: "health")]), "health"
        assert_includes CityServiceCapabilities.directory_topics(entries: [card.merge(topics: %w(health animals))]), "animals"
        assert_not_includes CityServiceCapabilities.directory_topics(entries: [card]), "launch"
        # The shipped directory's topic-keyed entries count without any marker.
        assert_includes CityServiceCapabilities.directory_topics(entries: []), "waste"
      end
    end
  end
end
