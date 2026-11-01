# frozen_string_literal: true

# These expected-accept tests document open semantic gaps. Green is NOT evidence
# that the accepted adversarial statements are safe or useful.
ENV["MT_NO_PLUGINS"] = "1"
require "bundler/setup"
gem "minitest", ">= 5.1", "< 6"
require "minitest/autorun"
require "json"
require "active_support"
require "active_support/core_ext/hash/except"
engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine, "app/services/decidim/bih/concierge/dialogue/answer_contract")
require File.join(engine, "app/services/decidim/bih/concierge/dialogue/turn_budget")

class MilicaAnswerContractLimitsTest < Minitest::Test
  Dialogue = Decidim::Bih::Concierge::Dialogue

  def setup
    @contract = Dialogue::AnswerContract.new
    # An authored journey tuple; never load a real municipality timetable.
    source = { "source_url" => "https://transport.example.invalid/authored-timetable.pdf" }
    @departure = "10:41"
    @arrival = "10:42"
    @evidence = [{ "status" => "ok", "coverage_complete" => false, "warnings" => ["partial_reviewed_transport_network"],
                   "evidence" => [{ "id" => "leg1", "source_url" => source.fetch("source_url"),
                                    "facts" => { "route_code" => "G1", "direction" => "A", "origin_label" => "Testni trg", "destination_label" => "Testni vrt",
                                                 "service_date" => "2026-09-17", "departure_at" => "2026-09-17T#{@departure}:00+02:00",
                                                 "arrival_at" => "2026-09-17T#{@arrival}:00+02:00", "physical_platform_assignment_verified" => false } }],
                   "candidates" => [] }]
    @context = Dialogue::Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, capabilities: ["public_reads"],
                                                       now: Time.utc(2026, 9, 16, 6), deadline: Dialogue::TurnBudget.new)
  end

  def test_valid_current_tuple_control
    assert_equal "10:41", @departure
    assert_equal "10:42", @arrival
    assert accepted?("G1 17.9.2026: Testni trg #{@departure} → Testni vrt #{@arrival}.")
  end

  def test_unknown_url_and_citation_are_rejected
    assert_raises(Dialogue::Contracts::Invalid) { accepted?("Mapa: https://invented.example/stop") }
    assert_raises(Dialogue::Contracts::Invalid) { accepted?("Podatak.", citations: ["invented"]) }
  end

  def test_unknown_clock_is_diagnostic_only_and_still_requires_semantic_review
    payload = accepted?("G1 polazi u 03:33.")
    assert_equal 1, @contract.unmatched_clock_literal_count(payload:, evidence: @evidence, message: "Kada polazi G1?"),
                 "Diagnostic acceptance does not establish that this departure is supported"
  end

  def test_documented_gap_swapped_stop_clock_relationship_is_accepted
    assert accepted?("G1 17.9.2026: Testni vrt #{@arrival} → Testni trg #{@departure}."),
           "Expected acceptance documents a gap, not a valid reverse-direction journey"
  end

  def test_documented_gap_wrong_service_year_is_accepted
    assert accepted?("G1 17.9.2027: Testni trg #{@departure} → Testni vrt #{@arrival}."),
           "Clock membership cannot prove service date"
  end

  def test_documented_gap_invented_platform_and_global_negative_are_accepted
    assert accepted?("G1 polazi sa tačno izmjerenog perona 7."), "No platform/surveyed-position support exists"
    assert accepted?("Nijedan autobus ne saobraća nedjeljom."), "Partial reviewed coverage cannot prove global absence"
  end

  def test_documented_gap_citizen_false_clock_can_be_asserted
    assert accepted?("Da, autobus polazi u 04:48.", message: "Je li polazak u 04:48?"),
           "Citizen-supplied clock is a question, not timetable authority"
  end

  private

  def accepted?(text, message: "Testni trg do Testnog vrta 17.9.2026. poslije 10:00.", citations: ["leg1"])
    @contract.call(payload: { "kind" => "answer", "answer" => text, "evidence_ids" => citations }, evidence: @evidence, message:, context: @context)
  end
end
