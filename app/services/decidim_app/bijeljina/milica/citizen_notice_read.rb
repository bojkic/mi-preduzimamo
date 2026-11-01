# frozen_string_literal: true

require_relative "../citizen_notice_pilots"
require_relative "read/base"

module DecidimApp
  module Bijeljina
    module Milica
      class CitizenNoticeRead
        include Read::Base

        class AmbiguousPeriod < ArgumentError; end

        def self.source_key(topic:, entities:)
          query = Decidim::Bih::Text.fold(entities["query"].to_s)
          return if unsupported_notice_query?(query)
          return "bihamk_border" if topic == "roads" && border_query?(query)
          return unless topic == "social_welfare" && benefit_notice_query?(query)
          return unless query.match?(/penzij|djecij\w* dodat|materinsk\w* dodat|jfdz|fond pio/)

          query.match?(/penzij|fond pio/) ? "pio_notices" : "jfdz_notices"
        end

        def self.unsupported_notice_query?(query)
          facet = Decidim::Bih::Concierge::Dialogue::QuestionFacet
          # Decline mixed requests too: a payment or wait report cannot answer
          # the contact, location, opening-hours or application half of a turn.
          [facet::CONTACT, facet::WEBSITE, facet::OPERATOR, facet::HOURS, facet::LOCATION].any? { |pattern| query.match?(pattern) } ||
            query.match?(/\b(?:radi|rade|otvara\w*|zatvara\w*|zahtjev\w*|zahtev\w*|prijav\w*|uslov\w*|uvjet\w*|dokument\w*|procedur\w*|ostvar\w*)\b/)
        end

        def self.benefit_notice_query?(query)
          query.match?(/\b(?:isplat\w*|stiz\w*|stig\w*|legl\w*|leci|lijez\w*|lez[eu])\b/) ||
            query.match?(/\b(?:kad|kada)\s+(?:(?:ce|je|su)\s+)?(?:penzij\w*|djecij\w*\s+dodat\w*|materinsk\w*\s+dodat\w*)\b/) ||
            schooling_deadline_query?(query)
        end

        def self.schooling_deadline_query?(query)
          query.match?(/potvrd\w*.*skol|skol\w*.*potvrd/) && query.match?(/\b(?:rok\w*|do kad|do kada)\b/)
        end

        def self.border_query?(query)
          crossing = query.match?(/\b(?:granic\w*|granica|gp raca|gp popovi|gp sepak|pavlovic\w* most\w*|raca|raci|popovi|sepak|sepku)\b/)
          crossing && query.match?(/\b(?:stanj\w*|status|guzv\w*|ceka\w*|zadrz\w*|prohod\w*|otvoren\w*|zatvoren\w*|saobrac\w*|situacij\w*)\b/)
        end

        def initialize(source_store: nil)
          @store = source_store || CityServiceSourceCheckStore.new
        end

        def call(topic:, entities:, context:, locale:)
          return not_authorized_result unless authorized?(context)

          key = self.class.source_key(topic:, entities:)
          return { status: "unavailable", warnings: ["unsupported_public_notice_query"] } unless key

          read_source(key:, entities:, context:, locale:)
        end

        # Typed tool selection bypasses topic-language routing, while preserving
        # public-only, time, freight and source review constraints.
        def read_source(key:, entities:, context:, locale:)
          return not_authorized_result unless authorized?(context)
          return { status: "unavailable", warnings: ["unsupported_public_notice_source"] } unless CitizenNoticePilots::SOURCES.has_key?(key)

          return unavailable(key, "personal_entitlement_not_supported") if fold(entities["query"]).match?(/\b(?:moja|moje|moju|meni|racun)\b/)
          return unavailable(key, "future_or_historical_pilot_query_not_supported") unless supported_time?(entities, context.now)
          return unavailable(key, "freight_wait_not_supported") if freight_query?(key, entities)

          prepared = prepared_payload(key)
          return unavailable(key, "public_notice_pilot_not_prepared") unless prepared

          payload, failed = prepared
          validate_record_clocks!(payload.fetch("records"), key:, now: context.now)
          records = select_records(payload.fetch("records"), key:, query: fold(entities["query"]), now: context.now)
          build_result(records, payload:, key:, state: { failed:, now: context.now }, locale:)
        rescue AmbiguousPeriod
          unavailable(key, "payment_period_ambiguous")
        rescue KeyError, ArgumentError, TypeError
          key ? unavailable(key, "public_notice_pilot_malformed") : { status: "unavailable", warnings: ["public_notice_pilot_malformed"] }
        end

        private

        def freight_query?(key, entities)
          key == "bihamk_border" && fold(entities["query"]).match?(/teret|kamion/)
        end

        def prepared_payload(key)
          row = @store.snapshot(source_key: CitizenNoticePilots.snapshot_key(key))
          return unless row && row.source_version == CitizenNoticePilots.version_for(key)

          payload = row.check_payload
          failed = %w(ok empty).exclude?(payload["status"])
          payload = row.last_good_payload if failed
          return unless payload.is_a?(Hash) && %w(ok empty).include?(payload["status"]) && payload["pilot_key"] == key

          [payload, failed]
        end

        def supported_time?(entities, now)
          request = requested_day(entities, now:)
          [:none, :today].include?(request.kind) || (request.kind == :explicit && request.day == local_date(now))
        end

        def select_records(records, key:, query:, now:)
          return selected_border_records(records, query) if key == "bihamk_border"
          return selected_deadlines(records, query:, now:) if query.match?(/rok|potvrd|do kada|do kad/)

          period = requested_period(query)
          records.select { |record| payment_matches?(record, period:) }
                 .sort_by { |record| record["source_published_on"].to_s }.reverse.first(3)
        end

        def requested_period(query)
          years = query.scan(/\b(?:19|20|21)\d{2}\b/).uniq
          months = CitizenNoticePilotParser::MONTHS.filter_map { |name, number| number if query.match?(/\b#{Regexp.escape(name)}\b/) }.uniq
          raise AmbiguousPeriod, "ambiguous payment period" if years.size > 1 || months.size > 1

          { year: years.first, month: months.first }
        end

        def payment_matches?(record, period:)
          return false unless record["kind"] == "payment_start_notice"

          period_matches?(record["period_covered"], period:)
        end

        def period_matches?(value, period:)
          covered = value.to_s
          (!period[:year] || covered.start_with?("#{period[:year]}-")) &&
            (!period[:month] || covered.end_with?(format("-%02d", period[:month])))
        end

        def validate_record_clocks!(records, key:, now:)
          raise ArgumentError, "invalid cached records" unless records.is_a?(Array)

          records.each do |record|
            raise ArgumentError, "invalid cached record" unless record.is_a?(Hash)

            record.fetch(key == "bihamk_border" ? "observed_at" : "source_published_on")
            captured_time(record["observed_at"], now:) if record.has_key?("observed_at")
            validate_publication!(record["source_published_on"], now:) if record.has_key?("source_published_on")
            next if key == "bihamk_border"

            unless record["subject_id"] == key && record["personal_status"] == false
              raise ArgumentError, "invalid cached public notice scope"
            end
            if record["kind"] == "payment_start_notice"
              captured_date(record.fetch("payment_starts_on"))
              period = record["period_covered"]
              if period
                raise ArgumentError, "invalid cached payment period" unless period.is_a?(String) && /\A\d{4}-\d{2}\z/.match?(period)

                captured_date("#{period}-01")
              end
            end
          end
        end

        def validate_publication!(value, now:)
          raise ArgumentError, "future cached publication" if captured_date(value) > local_date(now)
        end

        def captured_date(value)
          raise ArgumentError, "invalid cached date" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          Date.iso8601(value)
        end

        def captured_time(value, now:)
          raise ArgumentError, "cached timestamp offset missing" unless value.is_a?(String) && value.match?(/T.*(?:Z|[+-]\d{2}:\d{2})\z/)

          timestamp = Time.iso8601(value)
          raise ArgumentError, "future cached timestamp" if timestamp > now

          timestamp
        end

        def selected_deadlines(records, query:, now:)
          audience = CitizenNoticePilotParser.obligation_audience(query)
          period = requested_period(query)
          records.select do |record|
            record["kind"] == "obligation_deadline" && Date.iso8601(record.fetch("deadline_on")) >= local_date(now) &&
              (!audience || record["audience"] == audience) && period_matches?(record["deadline_on"].to_s[0, 7], period:)
          end
        end

        def selected_border_records(records, query)
          names = { "raca" => /raca|raci/, "popovi" => /popovi|pavlovic/, "sepak" => /sepak|sepku/ }
          requested = names.filter_map { |key, pattern| "bihamk:#{key}" if query.match?(pattern) }
          records.select { |record| record["kind"] == "border_report" && (requested.empty? || requested.include?(record["subject_id"])) }
        end

        def build_result(records, payload:, key:, state:, locale:)
          now = state.fetch(:now)
          failed = state.fetch(:failed)
          checked = captured_time(payload.fetch("checked_at"), now:)
          source = CitizenNoticePilots::SOURCES.fetch(key)

          stale = stale_records?(records, checked:, threshold: now - source[:max_age])
          last_known = failed || stale
          facts = records.first(8).map { |record| fact(record, key:, last_known:, locale:) }
          warnings = ["selected_public_notices_not_complete_inventory"]
          warnings << "latest_pilot_attempt_failed" if failed
          warnings << "last_known_notice_not_current_status" if last_known
          result(result_status(facts, last_known:), source: source_descriptor(key), facts:, checked_at: checked.iso8601,
                                                    coverage: { "scope" => "selected_public_notices", "personal_status_supported" => false },
                                                    validity: { "live_status" => false, "last_known_only" => last_known }, warnings:)
        end

        def stale_records?(records, checked:, threshold:)
          checked < threshold || records.any? { |record| record["observed_at"] && Time.iso8601(record["observed_at"]) < threshold }
        end

        def result_status(facts, last_known:)
          return "unreviewed" if last_known

          facts.empty? ? "empty" : "ok"
        end

        def payment_text(record)
          "#{record["subject_label"]}: objavljen početak isplate #{record["payment_starts_on"]}; " \
            "period na koji se isplata odnosi: #{record["period_covered"] || "nije potvrđen"}. Datum pojedinačne uplate nije potvrđen."
        end

        def fact(record, key:, last_known:, locale:)
          url = CitizenNoticePilots.approved_url(record.fetch("source_url"), key)
          text = record_text(record)
          text = "Posljednja sačuvana objava; trenutni status nije potvrđen. #{text}" if last_known
          record.merge("text" => localize(text, locale:), "source_url" => url, "source_id" => key,
                       "source_label" => CitizenNoticePilots::SOURCES.fetch(key)[:label], "warning_codes" => record["warnings"],
                       "validity" => { "last_known_only" => last_known, "personal_status" => false })
        end

        def record_text(record)
          return payment_text(record) if record["kind"] == "payment_start_notice"

          if record["kind"] == "obligation_deadline"
            audience = record["audience"] == "secondary_school_students" ? "učenici srednjih škola" : "studenti"
            return "Fond PIO RS: #{record["text"]}, #{audience}: #{record["deadline_on"]}. Provjerite uputstvo u službenoj objavi."
          end

          "#{record["subject_label"]}, izvještaj #{record["observed_at"]}: #{record["text"]}"
        end

        def source_descriptor(key)
          source = CitizenNoticePilots::SOURCES.fetch(key)
          { "id" => key, "label" => source[:label], "url" => source[:url] }
        end

        def unavailable(key, warning)
          result("unavailable", source: source_descriptor(key), warnings: [warning])
        end
      end
    end
  end
end
