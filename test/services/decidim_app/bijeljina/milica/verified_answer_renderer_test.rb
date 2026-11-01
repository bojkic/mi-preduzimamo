# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class VerifiedAnswerRendererTest < ActiveSupport::TestCase
        def setup
          @renderer = VerifiedAnswerRenderer.new
        end

        def answer(kind: "answer", claims: [], prose: "Izmišljeni siguran odgovor")
          { "kind" => kind, "answer" => prose, "claim_selections" => claims }
        end

        def event(status: "unconfirmed", relation: "unknown", date: "2026-09-26")
          { "status" => "ok", "query_scope" => { "operation" => "read_service_events", "date" => date },
            "evidence" => [{ "id" => "event-1", "document_id" => "event-140", "text" => "Prekid u cijelom gradu",
                             "facts" => { "source_fact" => { "kind" => "city_service_event", "starts_at" => "2026-09-26T08:00:00+02:00", "ends_at" => "2026-09-26T14:00:00+02:00" },
                                          "applicability_to_requested_area" => { "status" => status, "relation" => relation,
                                                                                  "requested_areas" => [{ "name" => "Centar" }] } } }] }
        end

        def journey(search_complete: true)
          fact = { "evidence_purpose" => "computed_journey_for_requested_endpoints_date_and_window", "journey_index" => 0, "leg_index" => 0,
                   "objective" => "fastest_arrival", "route_code" => "P12", "origin_label" => "Janja (centar)", "destination_label" => "Bijeljina",
                   "departure_at" => "2026-09-17T11:30:00+02:00", "arrival_at" => "2026-09-17T12:00:00+02:00", "service_date" => "2026-09-17",
                   "requested_service_date" => "2026-09-17", "leave_at" => "2026-09-17T11:22:00+02:00", "search_complete" => search_complete,
                   "assumed_stop" => [{ "role" => "origin_id", "selected_stop" => "Janja (centar)", "alternative_stops" => ["Janja (škola)"] }] }
          { "status" => "ok", "coverage_complete" => false,
            "query_scope" => { "operation" => "plan_journey", "search_complete" => search_complete, "objective" => "fastest_arrival",
                               "date" => "2026-09-17", "resolved_query" => { "mode" => "fastest", "origin_id" => "origin-1",
                                 "destination_id" => "destination-1", "date" => "2026-09-17", "after_time" => "09:00" } },
            "evidence" => [{ "id" => "leg-1", "facts" => fact }] }
        end

        test "owner disabled heating is explained instead of repeating model prose" do
          evidence = [{ "status" => "unavailable", "query_scope" => { "operation" => "read_service_events", "topic" => "heating" },
                        "warnings" => ["source_disabled_by_owner"], "evidence" => [] }]
          result = @renderer.call(payload: answer(prose: "Grijanje radi normalno"), evidence:, locale: "sr")
          assert_equal "source_disabled_by_owner", result.reason
          assert_includes result.text, "ne prate"
          assert_not_includes result.text, "radi normalno"
        end

        test "unconfirmed area never inherits a confident model claim" do
          result = @renderer.call(payload: answer(claims: [{ "kind" => "affected_area", "evidence_id" => "event-1" }]), evidence: [event])
          assert_equal "high_risk_unverified", result.reason
          assert_not_includes result.text, "obuhvaćeno"
          uncertain = @renderer.call(payload: answer(claims: [{ "kind" => "uncertain_area", "evidence_id" => "event-1" }]), evidence: [event])
          assert_includes uncertain.text, "ne potvrđuje obuhvat"
        end

        test "confirmed area requires the requested event window" do
          yes = @renderer.call(payload: answer(claims: [{ "kind" => "affected_area", "evidence_id" => "event-1" }]),
                               evidence: [event(status: "confirmed", relation: "part")])
          assert_includes yes.text, "dio područja Centar"
          no = @renderer.call(payload: answer(claims: [{ "kind" => "affected_area", "evidence_id" => "event-1" }]),
                              evidence: [event(status: "confirmed", relation: "part", date: "2026-09-27")])
          assert_equal "high_risk_unverified", no.reason
        end

        test "event ending at local midnight does not affect the next day" do
          row = event(status: "confirmed", relation: "whole", date: "2026-09-27")
          row["evidence"].first["facts"]["source_fact"]["ends_at"] = "2026-09-27T00:00:00+02:00"
          result = @renderer.call(payload: answer(claims: [{ "kind" => "affected_area", "evidence_id" => "event-1" }]), evidence: [row])
          assert_equal "high_risk_unverified", result.reason
        end

        test "earlier notice reference cannot silently switch to a newer event" do
          data = event(status: "confirmed", relation: "whole")
          payload = answer(claims: [{ "kind" => "affected_area", "evidence_id" => "event-1" }]).merge("evidence_ids" => ["event-1"])
          question = "A ono staro obavještenje?"
          missing = @renderer.call(payload:, evidence: [data], question:, active_subjects: [])
          assert_equal "referent_unresolved", missing.reason
          assert_includes missing.text, "Na koje ranije"
          wrong = @renderer.call(payload:, evidence: [data], question:,
                                 active_subjects: [{ "kind" => "city_service_event", "id" => "event-148" }])
          assert_equal "referent_unresolved", wrong.reason
          correct = @renderer.call(payload:, evidence: [data], question:,
                                   active_subjects: [{ "kind" => "city_service_event", "id" => "event-140" }])
          assert_equal "validated_claims", correct.reason
        end

        test "complete journey renders source labels clocks and assumed stop" do
          result = @renderer.call(payload: answer(claims: [{ "kind" => "selected_journey", "evidence_id" => "leg-1" }]), evidence: [journey])
          assert_equal "validated_claims", result.reason
          assert_includes result.text, "Janja (centar) 11:30"
          assert_includes result.text, "Bijeljina 12:00"
          assert_includes result.text, "Kreni oko 11:22"
          assert_includes result.text, "Janja (škola)"
          assert_not_includes result.text, "Izmišljeni"
        end

        test "one cited winning journey is useful even if model omits optional claim selection" do
          payload = answer.merge("evidence_ids" => ["leg-1"])
          result = @renderer.call(payload:, evidence: [journey])
          assert_equal "validated_claims", result.reason
          assert_includes result.text, "Janja (centar) 11:30"
          assert_not_includes result.text, "Izmišljeni"
        end

        test "last departure uses its own completed objective" do
          data = journey
          data["evidence"].first["facts"]["objective"] = "last_departure"
          result = @renderer.call(payload: answer(claims: [{ "kind" => "last_departure", "evidence_id" => "leg-1" }]), evidence: [data])
          assert_includes result.text, "Posljednji potvrđeni polazak"
          assert_includes result.text, "Kreni oko 11:22"
          wrong = @renderer.call(payload: answer(claims: [{ "kind" => "first_departure", "evidence_id" => "leg-1" }]), evidence: [data])
          assert_equal "high_risk_unverified", wrong.reason
        end

        test "incomplete route never claims a fastest arrival" do
          result = @renderer.call(payload: answer(claims: [{ "kind" => "selected_journey", "evidence_id" => "leg-1" }]),
                                  evidence: [journey(search_complete: false)])
          assert_equal "high_risk_unverified", result.reason
          assert_not_includes result.text, "11:30"
        end

        test "reviewed legacy connection renders without claiming planner completeness" do
          data = journey
          fact = data.fetch("evidence").first.fetch("facts")
          fact.delete("objective")
          fact.delete("search_complete")
          fact.delete("leave_at")
          fact["requested_constraints"] = { "origin_id" => "origin-1", "destination_id" => "destination-1",
                                            "date" => "2026-09-17", "after_time" => "09:00", "mode" => "next" }
          data["query_scope"] = { "operation" => "plan_journey", "subject_ids" => %w(origin-1 destination-1),
                                  "date" => "2026-09-17", "window_start" => "2026-09-17T09:00:00+02:00" }
          rendered = @renderer.call(payload: answer(claims: [{ "kind" => "selected_journey", "evidence_id" => "leg-1" }]), evidence: [data])
          assert_equal "validated_claims", rendered.reason
          assert_includes rendered.text, "Janja (centar) 11:30"
          assert_includes rendered.text, "Bijeljina 12:00"
          assert_not_includes rendered.text, "Najbrži"

          data["query_scope"]["subject_ids"] = %w(other-origin destination-1)
          assert_equal "high_risk_unverified", @renderer.call(payload: answer(claims: [{ "kind" => "selected_journey", "evidence_id" => "leg-1" }]), evidence: [data]).reason
          data["query_scope"]["subject_ids"] = %w(origin-1 destination-1)
          data["query_scope"]["window_start"] = "2026-09-17T12:00:00+02:00"
          assert_equal "high_risk_unverified", @renderer.call(payload: answer(claims: [{ "kind" => "selected_journey", "evidence_id" => "leg-1" }]), evidence: [data]).reason
        end

        test "transfer answer exposes the actual change and rejects inverted clocks" do
          data = journey
          first = data["evidence"].first["facts"]
          first["destination_label"] = "NAS"
          first["arrival_at"] = "2026-09-17T11:40:00+02:00"
          second = first.merge("leg_index" => 1, "route_code" => "G2", "origin_label" => "NAS",
                               "destination_label" => "Bijeljina", "departure_at" => "2026-09-17T11:45:00+02:00",
                               "arrival_at" => "2026-09-17T12:05:00+02:00")
          data["evidence"] << { "id" => "leg-2", "facts" => second }
          payload = answer(claims: [{ "kind" => "selected_journey", "evidence_id" => "leg-1" }])
          good = @renderer.call(payload:, evidence: [data])
          assert_includes good.text, "Presjedanje"
          assert_includes good.text, "NAS 11:40 → NAS 11:45 (G2)"

          second["departure_at"] = "2026-09-17T11:35:00+02:00"
          bad = @renderer.call(payload:, evidence: [data])
          assert_equal "high_risk_unverified", bad.reason
        end

        test "Cyrillic reply preserves canonical route code and source clocks" do
          result = @renderer.call(payload: answer(claims: [{ "kind" => "selected_journey", "evidence_id" => "leg-1" }]),
                                  evidence: [journey], locale: "sr-Cyrl")
          assert_match(/[А-Ша-ш]/, result.text)
          assert_includes result.text, "P12"
          assert_includes result.text, "11:30"
          assert_not_includes result.text, "Измишљени"
        end

        test "zero result claim requires complete reviewed coverage" do
          incomplete = { "status" => "unsupported", "coverage_complete" => false, "query_scope" => { "operation" => "plan_journey" }, "evidence" => [] }
          complete = incomplete.merge("status" => "empty", "coverage_complete" => true)
          claim = [{ "kind" => "scoped_no_match" }]
          assert_equal "high_risk_unverified", @renderer.call(payload: answer(claims: claim), evidence: [incomplete]).reason
          assert_includes @renderer.call(payload: answer(claims: claim), evidence: [complete]).text, "nema polaska"
        end
      end
    end
  end
end
