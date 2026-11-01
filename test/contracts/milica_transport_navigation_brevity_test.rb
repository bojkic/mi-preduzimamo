# frozen_string_literal: true

require_relative "milica_transport_quality_test"

class MilicaTransportQualityTest
  def test_nearest_navigation_brevity_preserves_actual_stop_maps_and_accessibility_limits
    d = Decidim::Bih::Concierge::Dialogue
    ["sr", "sr-Cyrl", "bs", "hr", "en"].each do |locale|
      query = "Nalazim se kod bolnice u Bijeljini. Kako do najbliže autobuske stanice bez stepenica?"
      context = d::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64, capabilities: ["public_reads"], now: NOW)
      runner = d::ProcedureRunner.new(read_port: ->(**args) { transport_port.call(**args) },
                                      registration_port: ->(**) { flunk "No private effect" }, destinations: { support: "/pages/pomoc" })
      state = d::StateStore.new.empty_state(context)
      replies = [query, "Molim te kratko, čitam na telefonu."].each_with_index.map do |text, index|
        input = d::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                  entities: index.zero? ? { "query" => "najbliže stajalište" } : {}, locale:, needs_clarification: false, secondary: nil)
        result = runner.call(understanding: input, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil))
        state = result.state
        assert_equal "answered", result.resolution
        result.reply.text
      end
      full, short = replies
      assert_operator short.length, :<, full.length, locale
      assert_includes short, "destination=0.500000%2C0.505000"
      assert_includes short, "https://community.example.invalid/synthetic/transport/G2-map.png"
      assert_match(/približan|приближан/, short)
      caveat = I18n.t("decidim_app.milica.directory_answers.transport_accessibility_unverified", locale:)
      assert_includes full, caveat
      assert_includes short, caveat
      assert_match(/izaberi početak u mapi|изабери почетак у мапи/, short)
      assert_equal false, /izbor autobuske linije|избор аутобуске линије/.match?(short)
    end
  end

  def test_nearest_stop_structured_parts_leave_default_source_text_unchanged
    named = @reader.nearest_stop(location: nil, place: "bolnice", locality: "Bijeljina").boarding_stop
    assert_equal "Stajalište Bijeljina (bolnica). Položaj je približan; provjeri oznaku na licu mjesta. " \
                 "Za pješački put izaberi početak u mapi, a za izbor autobuske linije napiši odredište.", named.fetch("text")
    location = { latitude: 0.500056, longitude: 0.504090 }
    gps = @reader.nearest_stop(location:).boarding_stop
    [named, gps].each do |fact|
      parts = fact.fetch("navigation_presentation")
      assert_equal fact.fetch("text"), parts.values_at("body", "route_guidance", "ending").join
      assert_match(/približ|približna/, parts.fetch("body"))
    end
    assert_includes gps.dig("navigation_presentation", "body"), "ne dužina pješačkog puta"
  end
end
