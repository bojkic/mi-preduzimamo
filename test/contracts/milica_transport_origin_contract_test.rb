# frozen_string_literal: true

require_relative "milica_transport_quality_test"

class MilicaTransportQualityTest
  def test_current_origin_words_override_model_stop_in_actual_runner_without_location
    ["Kako autobusom odavde do bolnice?", "Како аутобусом одавде до болнице?",
     "Koji autobus ide odavde do bolnice?", "Možeš li mi reći kako da dođem odavde do bolnice?", "How do I get from here to the hospital?"].each do |text|
      result, reads = current_origin_runner(location: nil, text:)
      assert_equal "ambiguous", reads.last.status
      assert_includes reads.last.warnings, "transport_origin_required"
      assert_empty reads.last.facts
      assert_equal(text.start_with?("How") ? "the hospital" : "bolnice", reads.last.coverage.dig("transport_query_entities", "area_query"))
      assert_equal(text.start_with?("How") ? "here" : "odavde", result.state.dig("entities", "stop"))
      assert_equal false, /12:15|Primjermarket/.match?(result.reply.text)
    end
  end

  def test_current_origin_words_use_trusted_location_in_actual_runner_despite_model_stop
    location = { latitude: 0.500056, longitude: 0.504090, accuracy: 20, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    _result, reads = current_origin_runner(location:)
    answer = reads.last
    assert_equal "ok", answer.status
    assert_match(/spomenik/i, answer.facts.first.fetch("text"))
    assert_match(/12:10.*12:16/, answer.facts.first.fetch("text"))
    assert_equal false, /Primjermarket/.match?(answer.facts.map { |fact| fact.fetch("text") }.join(" "))
  end

  def test_same_reviewed_printed_stop_aliases_cannot_create_a_circular_transfer
    [["bolnica", "bolnice"], ["болнице", "болница"], ["Bijeljina (bolnica)", "bolnice"]].each do |origin, destination|
      answer = @reader.query(origin:, destination:, notices: @notices, requested_at: Time.zone.local(2026, 9, 15, 12), roll_over: true)
      assert_equal :ambiguous, answer.status, "#{origin} -> #{destination}"
      assert_includes answer.warnings, "transport_same_stop"
      assert_nil answer.itinerary
    end
  end

  def test_current_origin_without_validated_location_does_not_consume_arbitrary_coordinates
    error = assert_raises(Decidim::Bih::Concierge::Dialogue::Contracts::Invalid) do
      read({ "query" => "Kako autobusom odavde do bolnice?", "stop" => "bolnica" },
           location: { latitude: 0.500056, longitude: 0.504090, accuracy: 20, purpose: "current_location",
                       consent: false, provenance: "browser_geolocation" })
    end
    assert_equal "Location consent required", error.message
  end

  def test_explicit_and_retained_origins_survive_non_deictic_journey_followups
    question = DecidimApp::Bijeljina::Milica::TransportJourneyQuestion
    retained = { "stop" => "NAS-a", "area_query" => "Primjerpark", "date" => "2026-09-16", "time_expression" => "06:00", "route" => "G1" }
    ["Od NAS-a do bolnice", "A do bolnice?", "A poslije 07:00?"].each do |text|
      selected = question.call(retained.merge("query" => text), now: NOW)
      assert_nil selected.warning
      assert_match(/nas/i, selected.entities.fetch("stop"))
      assert_equal "2026-09-16", selected.entities.fetch("date")
    end
    ["Ne odavde do bolnice", "Prijavi kvar odavde do bolnice", "Od NAS-a do bolnice; odavde do parka"].each do |text|
      selected = question.call(retained.merge("query" => text), now: NOW)
      assert_equal false, selected.entities["stop"] == "odavde", text
    end
    selected = question.call(retained.merge("query" => "Kako autobusom odavde do bolnice?"), now: NOW)
    assert_equal "odavde", selected.entities.fetch("stop")
    assert_equal "2026-09-16", selected.entities.fetch("date")
    assert_equal false, selected.entities.has_key?("route")
  end

  def test_distinct_reviewed_stops_remain_distinct_under_alias_matching
    answer = journey("NAS-a", "bolnice")
    assert_equal :ok, answer.status
    assert_match(/NAS/, answer.itinerary.legs.first.origin_label)
    assert_match(/bolnica/, answer.itinerary.legs.last.destination_label)
    broad = journey("Primjerpolje", "bolnice")
    assert_equal :ambiguous, broad.status
    assert_includes broad.warnings, "transport_origin_ambiguous"
    assert_equal false, broad.warnings.include?("transport_same_stop")
  end

  def test_actual_reader_preserves_explicit_then_validated_retained_origin_despite_other_gps
    location = { latitude: 0.500056, longitude: 0.504090, accuracy: 20, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    first = read({ "query" => "Od NAS-a do bolnice 16.9.2026. poslije 06:00?", "stop" => "bolnica" }, location:)
    assert_equal "ok", first.status
    assert_match(/NAS/, first.facts.first.fetch("text"))
    retained = first.coverage.fetch("transport_query_entities")
    assert_match(/nas/i, retained.fetch("stop"))
    second = read(retained.merge("query" => "A poslije 07:00?"))
    assert_equal "ok", second.status
    assert_match(/NAS/, second.facts.first.fetch("text"))
    assert_equal "2026-09-16", second.coverage.dig("transport_query_entities", "date")
  end

  def test_unknown_negated_and_reported_current_origin_ask_before_using_model_or_gps
    location = { latitude: 0.500056, longitude: 0.504090, accuracy: 20, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    ["Ne odavde do bolnice", "Rekao je odavde do bolnice", "Prijavi kvar odavde do bolnice",
     "Something odd from here to the hospital", "He said from here to the hospital"].each do |text|
      [nil, location].each do |current_location|
        answer = read({ "query" => text, "stop" => "bolnica", "area_query" => "bolnice" }, location: current_location, source_status: :unavailable)
        assert_equal "ambiguous", answer.status, text
        assert_includes answer.warnings, "transport_origin_required"
        assert_empty answer.facts
        assert_nil answer.coverage.dig("transport_query_entities", "stop")
        assert_includes answer.coverage.fetch("transport_query_invalidated_entities"), "stop"
      end
    end
  end

  def test_uncertain_current_origin_cannot_survive_in_actual_runner_followup_state
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: Time.utc(2026, 9, 15, 10))
    reads = []
    runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
      answer = transport_port.call(**args)
      reads << answer
      answer
    }, registration_port: ->(**) { flunk "No registration" }, destinations: { support: "/pages/pomoc" })
    state = dialogue::StateStore.new.empty_state(context)
    ["Rekao je odavde do bolnice", "A do bolnice poslije 13:00?"].each_with_index do |text, index|
      entities = index.zero? ? { "stop" => "bolnica", "area_query" => "bolnica" } : {}
      understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: index.zero? ? "start" : "continue",
                                                               entities:, locale: "sr", needs_clarification: false, secondary: nil)
      result = runner.call(understanding:, state:, context:, message: Struct.new(:text, :dialogue_location).new(text, nil))
      state = result.state
      assert_nil state.dig("entities", "stop")
      assert_equal "ambiguous", reads.last.status
      assert_includes reads.last.warnings, "transport_origin_required"
      assert_empty reads.last.facts
    end
    assert_equal "bolnice", reads.last.coverage.dig("transport_query_entities", "area_query")
  end

  private

  def current_origin_runner(location:, text: "Kako autobusom odavde do bolnice?")
    dialogue = Decidim::Bih::Concierge::Dialogue
    context = dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                      capabilities: ["public_reads"], now: Time.utc(2026, 9, 15, 10))
    reads = []
    runner = dialogue::ProcedureRunner.new(read_port: lambda { |**args|
      answer = transport_port.call(**args)
      reads << answer
      answer
    }, registration_port: ->(**) { flunk "No registration" }, destinations: { support: "/pages/pomoc" })
    understanding = dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "start",
                                                             entities: { "stop" => "bolnica", "area_query" => "bolnica" }, locale: "sr", needs_clarification: false, secondary: nil)
    message = Struct.new(:text, :dialogue_location).new(text, location)
    answer = runner.call(understanding:, state: dialogue::StateStore.new.empty_state(context), context:, message:)
    [answer, reads]
  end
end
