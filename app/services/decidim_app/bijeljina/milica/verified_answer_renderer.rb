# frozen_string_literal: true

require "date"
require "time"
require "active_support/time"
require "decidim/bih/transliterator"
require_relative "transport_journey_question"

module DecidimApp
  module Bijeljina
    module Milica
      # Citizen-facing factual clauses come only from current, eligible reader
      # records. Model prose is discarded for high-risk outage/journey reads.
      class VerifiedAnswerRenderer
        Rendered = Data.define(:text, :reason, :claim_count)
        HIGH_RISK_OPERATIONS = %w(read_service_events read_waste_schedule read_parking read_parking_tariffs resolve_stops resolve_and_plan_journey plan_journey plan_journey_from_current_location service_calendar inspect_timetable_trip nearest_stop).freeze
        SCOPED_CIVIC_OPERATIONS = %w(read_waste_schedule read_parking read_parking_tariffs).freeze
        MAX_REPLY_CHARS = 2_000
        MAX_CLAIMS = 12

        def call(payload:, evidence:, locale: "sr", question: nil, active_subjects: [])
          return Rendered.new(text: payload.fetch("answer"), reason: "ordinary", claim_count: 0) unless high_risk?(evidence)

          if evidence.any? { |item| item.dig("query_scope", "operation") == "read_service_events" &&
                                     Array(item["warnings"]).include?("source_disabled_by_owner") }
            return Rendered.new(text: I18n.t("decidim_app.city_service_events.bot.source_disabled_by_owner", locale:),
                                reason: "source_disabled_by_owner", claim_count: 0)
          end

          scoped = scoped_civic_answer(evidence, locale, question)
          return scoped if scoped

          if payload["nearby_stop_alternatives"] == true && evidence.any? { |item| item.dig("query_scope", "operation") == "nearest_stop" }
            return nearby_stop_alternatives_answer(payload, evidence, locale)
          end

          if nearest_stop_question?(question) && evidence.any? { |item| item.dig("query_scope", "operation") == "nearest_stop" }
            return nearest_stop_answer(payload, evidence, locale)
          end

          if prior_notice_reference?(question) && evidence.any? { |item| item.dig("query_scope", "operation") == "read_service_events" }
            prior = Array(active_subjects).select { |item| item.is_a?(Hash) && item["kind"] == "city_service_event" }.map { |item| item["id"] }.uniq
            cited = Array(payload["evidence_ids"])
            selected = evidence.flat_map { |item| item.fetch("evidence", []) }
                               .select { |item| cited.include?(item["id"]) && source_fact(item)["kind"] == "city_service_event" }
            unless prior.one? && selected.one? && selected.first["document_id"] == prior.first
              return Rendered.new(text: script("Na koje ranije obavještenje misliš? Napiši datum ili naziv izvora.", locale),
                                  reason: "referent_unresolved", claim_count: 0)
            end
          end

          selections = Array(payload["claim_selections"]).first(MAX_CLAIMS)
          selections = inferred_unique_selection(payload, evidence) if selections.empty? && payload["kind"] == "answer"
          return fallback(payload.fetch("kind"), locale, evidence) if selections.empty?

          fragments = selections.filter_map { |claim| render_claim(claim, evidence, locale) }
          fragments.uniq!
          return fallback(payload.fetch("kind"), locale, evidence) if fragments.empty?

          # Adding unrestricted prose here would undo claim validation. Mixed
          # questions can select a safe other_fact record as another fragment.
          complete = []
          fragments.each do |fragment|
            next if fragment.bytesize > MAX_REPLY_CHARS

            candidate = (complete + [fragment]).join(" ")
            break if candidate.length > MAX_REPLY_CHARS

            complete << fragment
          end
          return fallback(payload.fetch("kind"), locale, evidence) if complete.empty?

          note = boundary_service_note(evidence, locale)
          complete << note if note && (complete.join(" ").length + note.length + 1) <= MAX_REPLY_CHARS
          Rendered.new(text: complete.join(" "), reason: "validated_claims", claim_count: fragments.size)
        end

        private

        def nearest_stop_question?(question)
          return true if TransportJourneyQuestion.nearest_stop?({ "query" => question.to_s })

          folded = Decidim::Bih::Text.fold(question.to_s)
          folded.match?(/\b(?:koje|koji|koju|which)\b.*(?:\b(?:stajal\w*|stanic\w*|stop)\b.*\b(?:polazn\w*|start\w*)\b|\b(?:polazn\w*|start\w*)\b.*\b(?:stajal\w*|stanic\w*|stop)\b)/)
        end

        def scoped_civic_answer(evidence, locale, question)
          envelopes = evidence.select { |item| SCOPED_CIVIC_OPERATIONS.include?(item.dig("query_scope", "operation")) }
          return if envelopes.empty?

          waste = envelopes.select { |item| item.dig("query_scope", "operation") == "read_waste_schedule" }
          return scoped_waste_answer(waste, locale) if waste.any?

          scoped_parking_answer(envelopes, locale, question)
        end

        def scoped_waste_answer(envelopes, locale)
          records = envelopes.flat_map { |item| item.fetch("evidence", []) }
          if records.any?
            fragments = records.filter_map { |record| safe_source_text(record, locale) }.uniq.first(3)
            dated = waste_date_clause(envelopes, records, locale)
            fragments.unshift(dated) if dated
            return Rendered.new(text: fragments.join(" "), reason: "validated_claims", claim_count: records.size) if fragments.any?
          end

          ambiguous = envelopes.reverse.find { |item| item["status"] == "ambiguous" }
          if ambiguous
            labels = ambiguous.fetch("candidates", []).filter_map { |item| display_name(item["label"], locale) }.uniq.first(8)
            detail = labels.any? ? " #{script('Pregledane mogućnosti', locale)}: #{labels.join('; ')}." : ""
            text = "#{script('Raspored zavisi od tačnog naselja, rejona ili bloka. Napiši najmanji podatak koji to razlikuje.', locale)}#{detail}"
            return Rendered.new(text:, reason: "high_risk_unverified", claim_count: 0)
          end

          unavailable = envelopes.any? { |item| %w(unavailable expired).include?(item["status"]) }
          text = if unavailable
                   "Izvor rasporeda odvoza trenutno nije dostupan za provjeru."
                 else
                   "Za ovaj naziv nemam potvrđen red u pregledanom rasporedu. Napiši tačnu ulicu i naselje ili rejon."
                 end
          Rendered.new(text: script(text, locale), reason: "high_risk_unverified", claim_count: 0)
        end

        def waste_date_clause(envelopes, records, locale)
          requested = envelopes.filter_map { |item| item.dig("query_scope", "date") }.last
          return unless requested

          date = Date.iso8601(requested)
          weekday = %w(nedjelja ponedjeljak utorak srijeda četvrtak petak subota).fetch(date.wday)
          days = records.flat_map { |record| Array(source_fact(record).dig("coverage", "collection_days")) }.uniq
          return if days.empty?

          conclusion = if days.include?(weekday)
                         "redovni sedmični raspored navodi odvoz"
                       else
                         "redovni sedmični raspored ne navodi odvoz"
                       end
          script("Za #{date.strftime('%d.%m.%Y.')} (#{weekday}) #{conclusion}; vanredna izmjena za taj datum nije potvrđena.", locale)
        rescue Date::Error
          nil
        end

        def scoped_parking_answer(envelopes, locale, question)
          street_records = envelopes.select { |item| item.dig("query_scope", "operation") == "read_parking" }
                                    .flat_map { |item| item.fetch("evidence", []) }
          if street_records.any?
            fragments = street_records.filter_map { |record| safe_source_text(record, locale) }.uniq.first(2)
            if landmark_qualified?(question)
              fragments << script("Službena mapa ne potvrđuje da dio kod navedenog orijentira pripada tom označenom segmentu.", locale)
            end
            return Rendered.new(text: fragments.join(" "), reason: "validated_claims", claim_count: street_records.size)
          end

          tariffs = envelopes.select { |item| item.dig("query_scope", "operation") == "read_parking_tariffs" }
                             .flat_map { |item| item.fetch("evidence", []) }
          tariff_text = parking_tariff_text(tariffs, locale)
          parking = envelopes.reverse.find { |item| item.dig("query_scope", "operation") == "read_parking" }
          if parking && parking["status"] == "ambiguous"
            warning = Array(parking["warnings"])
            text = if warning.include?("parking_street_not_in_reviewed_catalog")
                     "Ta ulica nije u pregledanom katalogu označenih parking segmenata. Kućni broj sam po sebi to ne rješava; provjeri znak na parking-mjestu ili službenu mapu."
                   else
                     "Orijentir ne određuje tačan parking segment niti potvrđuje da li je mjesto javni ulični ili zaseban parking. Napiši ulicu parking-mjesta ili provjeri znak na licu mjesta."
                   end
            text = "#{script(text, locale)} #{tariff_text}" if tariff_text
            return Rendered.new(text:, reason: "high_risk_unverified", claim_count: tariffs.size)
          end

          return Rendered.new(text: tariff_text, reason: "validated_claims", claim_count: tariffs.size) if tariff_text

          Rendered.new(text: script("Za to parking-mjesto nemam potvrđenu zonu u pregledanoj službenoj mapi.", locale),
                       reason: "high_risk_unverified", claim_count: 0)
        end

        def parking_tariff_text(records, locale)
          rows = records.filter_map do |record|
            fact = source_fact(record)
            tariff = fact["tariff"]
            next unless tariff.is_a?(Hash) && tariff["label"].is_a?(String) && tariff["sms"].is_a?(String) && tariff["hourly_fening"].is_a?(Numeric)

            amount = format("%.2f", tariff.fetch("hourly_fening") / 100.0).tr(".", ",")
            line = "#{tariff.fetch('label')}: SMS #{tariff.fetch('sms')}, #{amount} KM/h"
            if tariff["daily_sms"].is_a?(String) && tariff["daily_fening"].is_a?(Numeric)
              daily = format("%.2f", tariff.fetch("daily_fening") / 100.0).tr(".", ",")
              line += "; dnevna karta SMS #{tariff.fetch('daily_sms')}, #{daily} KM"
            end
            line
          end
          return if rows.empty?

          script("Objavljene tarife i načini plaćanja, koji sami ne potvrđuju zonu konkretnog mjesta: #{rows.join('; ')}. Plaćanje ostaje na građaninu.", locale)
        end

        def safe_source_text(record, locale)
          text = source_fact(record)["text"] || record["text"]
          script(text, locale) if text.is_a?(String) && text.length.between?(1, 1_200)
        end

        def landmark_qualified?(question)
          Decidim::Bih::Text.fold(question.to_s).match?(/\b(?:kod|blizu|pored|oko|near)\b/)
        end

        def nearest_stop_answer(payload, evidence, locale)
          cited = Array(payload["evidence_ids"])
          candidates = evidence.select { |item| item.dig("query_scope", "operation") == "nearest_stop" && item["status"] == "ok" }
                               .flat_map { |item| item.fetch("evidence", []) }
                               .select { |record| cited.include?(record["id"]) }
          return nearest_stop_limitation(evidence, locale) unless candidates.one?

          facts = source_fact(candidates.first)
          label = facts["stop_label"]
          distance = facts["distance_meters"]
          return nearest_stop_limitation(evidence, locale) unless label.is_a?(String) && label.length.between?(1, 160) && distance.is_a?(Numeric) && distance.finite? && distance >= 0
          return nearest_stop_limitation(evidence, locale) unless facts["distance_kind"] == "straight_line"

          rounded = distance.round
          text = if rounded <= 5
                   "#{script('Najbliže pregledano autobusko stajalište je', locale)} #{label}; #{script('na objavljenoj karti je približno kod podijeljene lokacije.', locale)}"
                 else
                   "#{script('Najbliže pregledano autobusko stajalište je', locale)} #{label}, #{script('oko', locale)} #{rounded} m #{script('vazdušnom linijom prema približnoj tački sa objavljene karte.', locale)}"
                 end
          Rendered.new(text: "#{text} #{script('Položaj nije terenski izmjeren; pješački put nije provjeren.', locale)}", reason: "validated_claims", claim_count: 1)
        end

        def nearby_stop_alternatives_answer(payload, evidence, locale)
          cited = Array(payload["evidence_ids"])
          records = evidence.select { |item| item.dig("query_scope", "operation") == "nearest_stop" && item["status"] == "ok" }
                            .flat_map { |item| item.fetch("evidence", []) }
                            .select { |record| cited.include?(record["id"]) }
          return nearest_stop_limitation(evidence, locale) unless records.one?

          facts = source_fact(records.first)
          label = facts["stop_label"]
          distance = facts["distance_meters"]
          nearby = facts["nearby_alternatives"]
          return nearest_stop_limitation(evidence, locale) unless label.is_a?(String) && label.length.between?(1, 160) &&
                                                            distance.is_a?(Numeric) && distance.finite? && distance >= 0 &&
                                                            facts["distance_kind"] == "straight_line" && facts["nearby_radius_meters"] == 200 &&
                                                            nearby.is_a?(Array) && nearby.size <= 4
          return nearest_stop_limitation(evidence, locale) unless nearby.all? do |stop|
            stop.is_a?(Hash) && stop["stop_label"].is_a?(String) && stop["stop_label"].length.between?(1, 160) &&
              stop["stop_label"] != label && stop["distance_meters"].is_a?(Numeric) &&
              stop["distance_meters"].finite? && stop["distance_meters"].between?(0, 200)
          end

          if locale.to_s == "en"
            answer = if nearby.any?
                       items = nearby.map { |stop| "#{stop.fetch('stop_label')} (about #{stop.fetch('distance_meters').round} m straight line)" }
                       "Other reviewed stops within about 200 m of your shared point, besides #{label}: #{items.join(', ')}."
                     elsif distance <= 200
                       "I found no other reviewed stop within about 200 m of your shared point besides #{label}."
                     else
                       "I found no reviewed stop within about 200 m of your shared point. The closest reviewed stop is #{label}, about #{distance.round} m straight line."
                     end
            caveat = "Map positions are approximate and unsurveyed; walking routes and boarding suitability for a specific trip are unverified."
          else
            answer = if nearby.any?
                       items = nearby.map { |stop| "#{stop.fetch('stop_label')} (oko #{stop.fetch('distance_meters').round} m vazdušnom linijom)" }
                       "Druga pregledana stajališta do približno 200 m od podijeljene tačke, pored #{label}: #{items.join(', ')}."
                     elsif distance <= 200
                       "U krugu od približno 200 m od podijeljene tačke nemam drugo pregledano stajalište osim #{label}."
                     else
                       "U pregledanoj mapi nemam stajalište do približno 200 m od podijeljene tačke. Najbliže pregledano je #{label}, oko #{distance.round} m vazdušnom linijom."
                     end
            caveat = "Tačke na karti su približne i nisu terenski izmjerene; pješački put i izbor za konkretnu vožnju nisu provjereni."
            answer = script(answer, locale)
            caveat = script(caveat, locale)
          end
          Rendered.new(text: "#{answer} #{caveat}", reason: "validated_claims", claim_count: 1)
        end

        def nearest_stop_limitation(evidence, locale)
          unavailable = evidence.any? { |item| item.dig("query_scope", "operation") == "nearest_stop" && %w(unavailable expired unreviewed).include?(item["status"]) }
          text = if unavailable
                   "Izvor pregledanih autobuskih stajališta trenutno nije dostupan za provjeru."
                 else
                   "Za ovu lokaciju nemam potvrđeno obližnje autobusko stajalište u pregledanim podacima."
                 end
          Rendered.new(text: script(text, locale), reason: "high_risk_unverified", claim_count: 0)
        end

        def prior_notice_reference?(question)
          return false unless question.is_a?(String)

          text = Decidim::Bih::Transliterator.to_latin(question).downcase
          return false if text.match?(/\b(?:\d{1,2}\.\d{1,2}|\d{4}-\d{2}-\d{2}|broj\s+\d+)\b/)

          text.match?(/\b(?:ono|to|staro|starije|prethodno|ranije)\s+(?:(?:staro|starije|prethodno|ranije)\s+)?(?:obavještenje|obavijest|obavijesti)\b/)
        end

        # Older and nonconforming model replies may cite a current journey but
        # omit the optional selection. Only one eligible winning tuple is safe
        # to infer; an ambiguous set still receives a truthful limitation.
        def inferred_unique_selection(payload, evidence)
          cited = Array(payload["evidence_ids"])
          candidates = evidence.flat_map do |envelope|
            envelope.fetch("evidence", []).filter_map do |record|
              next unless cited.include?(record["id"])

              fact = source_fact(record)
              if journey_leg?(fact) && fact["journey_index"] == 0 && fact["leg_index"] == 0
                kind = { "first_departure" => "first_departure", "last_departure" => "last_departure" }.fetch(fact["objective"], "selected_journey")
                { "kind" => kind,
                  "evidence_id" => record["id"] }
              elsif fact["kind"] == "city_service_event" && record.dig("facts", "applicability_to_requested_area")
                { "kind" => record.dig("facts", "applicability_to_requested_area", "status") == "confirmed" ? "affected_area" : "uncertain_area",
                  "evidence_id" => record["id"] }
              end
            end
          end
          candidates.size == 1 ? candidates : []
        end

        def high_risk?(evidence)
          evidence.any? do |envelope|
            HIGH_RISK_OPERATIONS.include?(envelope.dig("query_scope", "operation")) ||
              envelope.fetch("evidence", []).any? { |record| high_risk_record?(record) }
          end
        end

        def high_risk_record?(record)
          fact = source_fact(record)
          fact["kind"] == "city_service_event" || journey_leg?(fact)
        end

        def source_fact(record)
          facts = record.fetch("facts", {})
          facts.is_a?(Hash) ? facts.fetch("source_fact", facts) : {}
        end

        def journey_leg?(fact)
          fact["evidence_purpose"] == "computed_journey_for_requested_endpoints_date_and_window" ||
            (fact.key?("journey_index") && fact.key?("departure_at") && fact.key?("arrival_at"))
        end

        def render_claim(claim, evidence, locale)
          return scoped_no_match(evidence, locale) if claim["kind"] == "scoped_no_match"

          pair = evidence.filter_map do |envelope|
            record = envelope.fetch("evidence", []).find { |row| row["id"] == claim["evidence_id"] }
            [envelope, record] if record
          end.first
          return unless pair

          envelope, record = pair
          case claim["kind"]
          when "affected_area" then affected_area(envelope, record, locale)
          when "uncertain_area" then uncertain_area(record, locale)
          when "selected_journey" then selected_journey(envelope, record, locale)
          when "first_departure" then first_departure(envelope, record, locale)
          when "last_departure" then last_departure(envelope, record, locale)
          when "other_fact" then other_fact(record, locale)
          end
        end

        def affected_area(envelope, record, locale)
          return unless in_requested_window?(envelope, record)

          applicability = record.dig("facts", "applicability_to_requested_area")
          return unless source_fact(record)["kind"] == "city_service_event" && applicability.is_a?(Hash)
          return unless applicability["status"] == "confirmed" && %w(whole part).include?(applicability["relation"])

          names = Array(applicability["requested_areas"]).filter_map { |area| area["name"] }.first(3)
          return if names.empty?

          text = if applicability["relation"] == "whole"
                   "Prema provjerenom obavještenju, područje #{names.join(', ')} je obuhvaćeno."
                 else
                   "Prema provjerenom obavještenju, dio područja #{names.join(', ')} je obuhvaćen; ne podrazumijeva se cijelo područje."
                 end
          title = source_fact(record).dig("source_text", "title")
          text += " Naslov obavještenja: #{title.strip}." if title.is_a?(String) && title.length.between?(1, 160)
          script(text, locale)
        end

        def uncertain_area(record, locale)
          applicability = record.dig("facts", "applicability_to_requested_area")
          return unless source_fact(record)["kind"] == "city_service_event" && applicability.is_a?(Hash)
          return unless applicability["status"] == "unconfirmed"

          names = Array(applicability["requested_areas"]).filter_map { |area| area["name"] }.first(3)
          return if names.empty?

          script("Za područje #{names.join(', ')} ovo obavještenje ne potvrđuje obuhvat. Potreban je izvor koji ga izričito navodi.", locale)
        end

        def selected_journey(envelope, record, locale)
          fact = source_fact(record)
          return unless journey_leg?(fact)

          scope = envelope.fetch("query_scope", {})
          return legacy_journey(envelope, fact, locale) if legacy_journey_evidence?(scope, fact)

          objective = fact["objective"] || scope["objective"]
          expected_mode = { "fastest_arrival" => "fastest", "first_departure" => "next", "last_departure" => "last" }[objective]
          return unless expected_mode && scope.dig("resolved_query", "mode") == expected_mode
          return unless fact["journey_index"] == 0
          constraints = fact["requested_constraints"] || scope["resolved_query"] || {}
          return unless constraints.is_a?(Hash)
          return unless fact["service_date"].is_a?(String) && fact["departure_at"].is_a?(String)
          return unless fact["requested_service_date"] == scope["date"] && fact["service_date"] == scope["date"]
          return unless fact["resolved_query"].nil? || fact["resolved_query"] == scope["resolved_query"]
          return unless scope["search_complete"] == true && fact["search_complete"] == true

          legs = envelope.fetch("evidence", []).map { |item| source_fact(item) }
                         .select { |item| journey_leg?(item) && item["journey_index"] == fact["journey_index"] }
                         .sort_by { |item| item.fetch("leg_index", 0) }
          return if legs.empty? || legs.map { |leg| leg.fetch("leg_index", 0) } != (0...legs.size).to_a
          return unless legs.all? { |leg| leg["service_date"] == fact["service_date"] }

          first, last = legs.first, legs.last
          origin = display_name(first["origin_label"], locale)
          destination = display_name(last["destination_label"], locale)
          departure = clock(first["departure_at"])
          arrival = clock(last["arrival_at"])
          return unless origin && destination && departure && arrival

          routes = legs.map { |leg| leg["route_code"] }.uniq
          return unless routes.all? { |code| code.is_a?(String) && code.match?(/\A[GP][1-9]\d?\z/) }
          return unless legs.each_cons(2).all? do |prior, following|
            Time.iso8601(prior.fetch("arrival_at")) <= Time.iso8601(following.fetch("departure_at"))
          end

          date = fact["service_date"]
          egress = fact["egress_walk_seconds"]
          egress_walk = egress.is_a?(Numeric) && egress.finite? && egress.positive?
          heading = if objective == "first_departure"
                      "Prva veza nakon traženog vremena u pregledanom redu vožnje"
                    elsif objective == "last_departure"
                      "Posljednja veza nakon traženog vremena u pregledanom redu vožnje"
                    elsif egress_walk
                      "Najbrži procijenjeni dolazak do odredišta u pregledanom redu vožnje"
                    else
                      "Najbrži procijenjeni dolazak do odredišnog stajališta u pregledanom redu vožnje"
                    end
          header = script(heading, locale)
          body = "#{origin} #{departure} → #{destination} #{arrival} (#{routes.join(' + ')}, #{date})."
          if legs.size > 1
            connection = legs.each_cons(2).filter_map do |prior, following|
              from = display_name(prior["destination_label"], locale)
              to = display_name(following["origin_label"], locale)
              incoming = clock(prior["arrival_at"])
              outgoing = clock(following["departure_at"])
              "#{from} #{incoming} → #{to} #{outgoing} (#{following['route_code']})" if from && to && incoming && outgoing
            end
            return unless connection.size == legs.size - 1

            body += " #{script('Presjedanje', locale)}: #{connection.join('; ')}."
          end
          leave = fact["leave_at"] || scope["leave_at"]
          leave_clock = clock(leave)
          body += " #{script('Kreni oko', locale)} #{leave_clock}." if leave_clock
          access = fact["access_walk_seconds"]
          if access.is_a?(Numeric) && access.finite? && access.positive?
            minutes = (access / 60.0).ceil
            body += " #{script('Do polaznog stajališta računam oko', locale)} #{minutes} min " \
                    "#{script('pješke od navedenog polazišta; pješački put nije provjeren.', locale)}"
          end
          if egress_walk
            final_clock = clock(fact["estimated_arrival_at"])
            return unless final_clock

            minutes = (egress / 60.0).ceil
            body += " #{script('Od silaznog stajališta računam oko', locale)} #{minutes} min " \
                    "#{script('pješke do odredišta; procijenjeni dolazak oko', locale)} #{final_clock}. " \
                    "#{script('Pješački put nije provjeren.', locale)}"
          end
          if (range = fact["walking_estimate_range_seconds"])
            return unless range.is_a?(Hash) && range["version"] == "walking_policy_v1" &&
                          range.values_at("low", "high").all? { |value| value.is_a?(Integer) && value.between?(0, 21_600) } &&
                          range.fetch("low") <= fact.fetch("walking_seconds", -1) && fact.fetch("walking_seconds", -1) <= range.fetch("high")

            if range.fetch("high").positive?
              low_minutes = (range.fetch("low") / 60.0).floor
              high_minutes = (range.fetch("high") / 60.0).ceil
              body += " #{journey_uncertainty_copy('walking_range', locale, low: low_minutes, high: high_minutes)}"
            end
          end
          return unless [true, false, nil].include?(fact["close_transfer_warning"])
          if fact["close_transfer_warning"] == true && legs.size > 1
            body += " #{journey_uncertainty_copy('close_transfer', locale)}"
          end
          body += assumption_clause(fact, locale)
          "#{header}: #{body}"
        rescue ArgumentError, KeyError
          nil
        end

        def first_departure(envelope, record, locale)
          departure_claim(envelope, record, locale, "first_departure")
        end

        def last_departure(envelope, record, locale)
          departure_claim(envelope, record, locale, "last_departure")
        end

        def departure_claim(envelope, record, locale, objective)
          fact = source_fact(record)
          return unless journey_leg?(fact) && fact["journey_index"] == 0 && fact["leg_index"] == 0
          scope = envelope.fetch("query_scope", {})
          if legacy_journey_evidence?(scope, fact)
            expected_mode = objective == "last_departure" ? "last" : "next"
            return legacy_journey(envelope, fact, locale) if fact.dig("requested_constraints", "mode").to_s == expected_mode
          end

          return unless fact["search_complete"] == true && scope["search_complete"] == true && fact["objective"] == objective
          return unless fact["journey_index"] == 0 && fact["requested_service_date"] == scope["date"] && fact["service_date"] == scope["date"]
          return unless fact["resolved_query"].nil? || fact["resolved_query"] == scope["resolved_query"]

          route = fact["route_code"]
          departure = clock(fact["departure_at"])
          origin = display_name(fact["origin_label"], locale)
          return unless route.is_a?(String) && route.match?(/\A[GP][1-9]\d?\z/) && departure && origin

          label = objective == "last_departure" ? "Posljednji potvrđeni polazak u pregledanom opsegu" : "Prvi potvrđeni polazak u pregledanom opsegu"
          resolved = scope["resolved_query"] || {}
          if resolved["direction"]
            direction = resolved.fetch("direction")
            destination = display_name(fact["destination_label"], locale)
            arrival = clock(fact["arrival_at"])
            calendar = display_name(fact["source_calendar_heading"], locale)
            return unless %w(A B).include?(direction) && fact["published_direction"] == direction
            return unless fact["transfer_count"] == 0 && fact["route_code"] == resolved["route_code"]
            return unless Array(resolved["origin_ids"]).include?(fact["origin_id"]) && Array(resolved["destination_ids"]).include?(fact["destination_id"])
            return unless destination && arrival && calendar

            published = objective == "last_departure" ? "Posljednji objavljeni polazak" : "Prvi objavljeni polazak"
            text = "#{script(published, locale)} u pregledanom redu vožnje: #{route}, #{script('smjer', locale)} #{direction}, " \
                   "#{fact.fetch('service_date')} (#{calendar}): #{origin} #{departure} → #{destination} #{arrival}. " \
                   "#{script('Red vožnje nije praćenje autobusa uživo.', locale)}"
          else
            destination = display_name(fact["destination_label"], locale)
            arrival = clock(fact["arrival_at"])
            direct_to_requested_stop = fact["transfer_count"] == 0 &&
              Array(resolved["origin_ids"]).include?(fact["origin_id"]) &&
              Array(resolved["destination_ids"]).include?(fact["destination_id"])
            text = if direct_to_requested_stop && destination && arrival
                     "#{script(label, locale)}: #{route}, #{origin} #{departure} → #{destination} #{arrival} " \
                       "(#{fact.fetch('service_date')})."
                   else
                     "#{script(label, locale)}: #{route}, #{origin} #{departure}."
                   end
          end
          leave = clock(fact["leave_at"])
          if leave
            advice = resolved["direction"] && fact["access_walk_seconds"].to_i.zero? ? "Budi na stajalištu oko" : "Kreni oko"
            text += " #{script(advice, locale)} #{leave}."
          end
          text += assumption_clause(fact, locale)
          text
        end

        # The old prepared timetable calculator supplies reviewed legs but not
        # the v2 planner's completeness/objective proof. Render its selected
        # tuple as a scoped connection, never as the fastest overall journey.
        def legacy_journey_evidence?(scope, fact)
          scope["operation"] == "plan_journey" && !scope.key?("resolved_query") &&
            !fact.key?("objective") && !fact.key?("search_complete") &&
            fact["requested_constraints"].is_a?(Hash)
        end

        def legacy_journey(envelope, fact, locale)
          scope = envelope.fetch("query_scope")
          constraints = fact.fetch("requested_constraints")
          return unless envelope["status"] == "ok" && fact["journey_index"] == 0
          return unless constraints.values_at("origin_id", "destination_id", "date", "after_time").all?(&:present?)
          return unless constraints.values_at("origin_id", "destination_id") == Array(scope["subject_ids"]).first(2)
          return unless constraints["date"] == scope["date"] && fact["requested_service_date"] == scope["date"]
          return unless fact["service_date"] == scope["date"] && constraints["after_time"].match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

          legs = envelope.fetch("evidence", []).map { |item| source_fact(item) }
                         .select { |item| journey_leg?(item) && item["journey_index"] == 0 }
                         .sort_by { |item| item.fetch("leg_index", 0) }
          return if legs.empty? || legs.map { |leg| leg.fetch("leg_index", 0) } != (0...legs.size).to_a
          return unless legs.all? { |leg| leg["requested_constraints"] == constraints && leg["service_date"] == scope["date"] }
          return unless legs.all? { |leg| leg["route_code"].to_s.match?(/\A[GP][1-9]\d?\z/) }

          departure_limit = Time.iso8601(scope.fetch("window_start"))
          return unless legs.all? { |leg| Time.iso8601(leg.fetch("departure_at")) < Time.iso8601(leg.fetch("arrival_at")) }
          return unless Time.iso8601(legs.first.fetch("departure_at")) >= departure_limit
          return unless legs.each_cons(2).all? { |prior, following| Time.iso8601(prior.fetch("arrival_at")) <= Time.iso8601(following.fetch("departure_at")) }

          origin = display_name(legs.first["origin_label"], locale)
          destination = display_name(legs.last["destination_label"], locale)
          departure = clock(legs.first["departure_at"])
          arrival = clock(legs.last["arrival_at"])
          return unless origin && destination && departure && arrival

          route_codes = legs.map { |leg| leg.fetch("route_code") }.uniq.join(" + ")
          heading = script("Veza u pregledanom redu vožnje", locale)
          text = "#{heading}: #{origin} #{departure} → #{destination} #{arrival} (#{route_codes}, #{scope.fetch('date')})."
          if legs.size > 1
            transfers = legs.each_cons(2).map do |prior, following|
              "#{display_name(prior['destination_label'], locale)} #{clock(prior['arrival_at'])} → " \
                "#{display_name(following['origin_label'], locale)} #{clock(following['departure_at'])}"
            end
            text += " #{script('Presjedanje', locale)}: #{transfers.join('; ')}."
          end
          text
        rescue ArgumentError, KeyError
          nil
        end

        def assumption_clause(fact, locale)
          Array(fact["assumed_stop"]).filter_map do |assumption|
            next unless assumption.is_a?(Hash) && assumption["selected_stop"].is_a?(String)

            role = assumption["role"]
            next unless %w(origin_id destination_id).include?(role)

            assumed_name = display_name(assumption["selected_stop"], locale)
            next unless assumed_name

            alternatives = Array(assumption["alternative_stops"]).filter_map { |item| display_name(item, locale) }.first(3)
            anchor = display_name(assumption["anchor_stop"], locale)
            text = if anchor && anchor != assumed_name
                     reference = role == "origin_id" ? "Za polazno područje uzimam stajalište" : "Za odredišno područje uzimam stajalište"
                     action = role == "origin_id" ? "ukrcavanje je na" : "izlazak je na"
                     " #{script(reference, locale)} #{anchor}; #{script(action, locale)} #{assumed_name}."
                   else
                     prefix = role == "origin_id" ? "Računam od stajališta" : "Za odredište računam do stajališta"
                     " #{script(prefix, locale)} #{assumed_name}."
                   end
            if alternatives.any?
              text += " #{script('Ako ti više odgovara drugo stajalište, napiši koje', locale)}; " \
                      "#{script('druga stajališta su', locale)} #{alternatives.join(', ')}."
            end
            text
          end.join
        end

        def scoped_no_match(evidence, locale)
          complete = evidence.find do |envelope|
            envelope["status"] == "empty" && envelope["coverage_complete"] == true &&
              HIGH_RISK_OPERATIONS.include?(envelope.dig("query_scope", "operation"))
          end
          return unless complete

          script("U pregledanom redu vožnje nema polaska za navedeni datum, prag i stajališta. To nije tvrdnja o nepregledanim linijama.", locale)
        end

        def other_fact(record, locale)
          return if high_risk_record?(record)

          fact = source_fact(record)
          return area_stop_assumption(fact, locale) if fact["kind"] == "assumed_area_stop"

          text = record["text"]
          text if text.is_a?(String) && text.length.between?(1, 600)
        end

        def area_stop_assumption(fact, locale)
          selected = display_name(fact["selected_stop"], locale)
          return unless selected

          text = "#{script('Za polazak pretpostavljam stajalište', locale)} #{selected}. " \
                 "#{script('Ako želiš drugo stajalište, napiši koje.', locale)}"
          alternatives = Array(fact["alternative_stops"]).filter_map { |name| display_name(name, locale) }.first(3)
          text += " #{script('Druga pregledana stajališta', locale)}: #{alternatives.join(', ')}." if alternatives.any?
          text
        end

        def clock(value)
          return unless value.is_a?(String)

          Time.iso8601(value).in_time_zone("Europe/Sarajevo").strftime("%H:%M")
        rescue ArgumentError
          nil
        end

        def display_name(value, locale)
          return unless value.is_a?(String) && value.length.between?(1, 160)

          script(value, locale)
        end

        def script(value, locale)
          locale.to_s == "sr-Cyrl" ? Decidim::Bih::Transliterator.call(value) : value
        end

        def journey_uncertainty_copy(key, locale, **values)
          source_locale = %w(bs hr sr en).include?(locale.to_s) ? locale : :sr
          script(I18n.t("decidim_app.milica.journey_uncertainty.#{key}", locale: source_locale, **values), locale)
        end

        def in_requested_window?(envelope, record)
          requested = envelope.dig("query_scope", "date")
          return true unless requested

          day = Date.iso8601(requested)
          fact = source_fact(record)
          start_at = fact["starts_at"]
          end_at = fact["ends_at"]
          if start_at && end_at
            zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
            beginning = zone.local(day.year, day.month, day.day)
            tomorrow = day + 1
            ending = zone.local(tomorrow.year, tomorrow.month, tomorrow.day)
            return Time.iso8601(start_at) < ending && Time.iso8601(end_at) > beginning
          end
          fact.dig("validity", "date") == requested
        rescue ArgumentError, Date::Error
          false
        end

        def boundary_service_note(evidence, locale)
          envelope = evidence.reverse.find { |item| item.dig("query_scope", "operation") == "read_service_events" &&
                                             Array(item["warnings"]).include?("location_near_area_boundary") }
          return unless envelope

          labels = Array(envelope["candidates"]).filter_map { |item| display_name(item["label"], locale) }.first(3)
          return if labels.empty?

          script("Kao približnu lokaciju uzela sam #{labels.join(' i ')}; GPS tačka je blizu granice područja. Napiši ulicu i kućni broj ili pošalji precizniju lokaciju za ponovnu provjeru.", locale)
        end

        def fallback(kind, locale, evidence)
          boundary = boundary_service_note(evidence, locale)
          if boundary
            envelope = evidence.reverse.find { |item| item.dig("query_scope", "operation") == "read_service_events" &&
                                                 Array(item["warnings"]).include?("location_near_area_boundary") }
            lead = if envelope["status"] == "unsupported"
                     "U pregledanim javnim najavama nisam našla potvrdu planiranog isključenja za pretpostavljena područja. To ne potvrđuje da struje neće nestati."
                   elsif %w(unavailable expired unreviewed).include?(envelope["status"])
                     "Javne najave trenutno ne mogu pouzdano provjeriti za pretpostavljena područja."
                   else
                     "Za pretpostavljena područja ne mogu potvrditi obuhvat planiranog isključenja iz dostupnih najava."
                   end
            return Rendered.new(text: "#{script(lead, locale)} #{boundary}", reason: "high_risk_unverified", claim_count: 0)
          end

          reason = evidence.filter_map { |envelope| envelope.dig("query_scope", "reason_code") }.last
          text = case reason
                 when "unresolved_place"
                   if evidence.any? { |item| item.dig("query_scope", "operation") == "read_service_events" }
                     "Ne mogu pouzdano odrediti područje za ovu najavu. Napiši ulicu ili naselje za ponovnu provjeru; to ne znači da isključenja nema."
                   else
                     "Koje tačno mjesto ili stajalište misliš?"
                   end
                 when "unsupported_calendar" then "Za traženi datum nemam provjeren red vožnje; to ne potvrđuje da autobus ne saobraća."
                 when "source_unavailable" then "Izvor reda vožnje trenutno nije dostupan za provjeru."
                 when "incomplete_search" then "Pretraga nije završena; ne mogu potvrditi prvi ili najbrži polazak."
                 when "no_eligible_trip_in_reviewed_scope" then "U pregledanom opsegu nisam našla polazak za zadate uslove; to ne isključuje nepregledane linije."
                 else
                   kind == "clarification" ? "Koje tačno mjesto ili stajalište misliš?" :
                     "Za traženi datum, mjesto ili polazak nemam dovoljno potvrđenih podataka. Mogu provjeriti precizniji upit."
                 end
          Rendered.new(text: script(text, locale), reason: "high_risk_unverified", claim_count: 0)
        end
      end
    end
  end
end
