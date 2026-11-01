# frozen_string_literal: true

require "digest"
require "uri"
require_relative "read/base"
require_relative "water_level_answer"
require_relative "../weather_region_configuration"

module DecidimApp
  module Bijeljina
    module Milica
      # Prepared public observations with source-level type, time and spatial
      # evidence. Collection time never stands in for a measurement timestamp.
      class SourceRead
        include Read::Base

        MAX_FACTS = 8
        MAX_TEXT = 900
        AREA_WIDE_TERMS = %w(grad gradsko gradski).freeze
        NOTICE_TOPICS = %w(weather civil_protection roads bulky_waste).freeze
        NOTICE_KINDS = %w(official_warning road_condition campaign_status).freeze
        NOTICE_FIELDS = %w(kind source_published_at affected_area_text geographic_status coverage_status review_required
                           last_campaign_starts_at last_campaign_ends_at provider_severity provider_area_code relevant_city
                           area_evidence_url area_evidence_checked_on provider_identifier provider_sender effective_at
                           provider_language provider_event provider_instruction provider_url license_url attribution source_format
                           provider_message_type transformation weather_region_review_id weather_organization_host reviewed_region_label area_review_valid_until).freeze

        def initialize(source_checker:, organization: nil)
          @source_checker = source_checker
          @organization = organization
        end

        def call(topic:, context:, locale:, entities:)
          return not_authorized_result unless authorized?(context)

          keys = CityServiceSources::TOPIC_SOURCE_KEYS.fetch(topic, [])
          return { status: "unavailable", warnings: ["unsupported_source_topic"] } if keys.empty?

          keys = keys.select { |key| CityServiceSources.enabled?(key) }
          return { status: "unavailable", warnings: ["source_not_configured"] } if keys.empty?

          @weather_region = nil
          @weather_region_mismatch = false
          @weather_warning_invalid = false
          if topic == "weather"
            unless @organization && @organization.respond_to?(:host)
              return { status: "unavailable", facts: [], warnings: ["weather_organization_required"] }
            end
            source = CityServiceSources.fetch(keys.first)
            @weather_region = WeatherRegionConfiguration.for_source(source_url: source.fetch(:source_url), day: local_date(context.now))
            unless @weather_region.bound_to?(organization_host: @organization.host, source_url: source.fetch(:source_url))
              return { status: "unavailable", facts: [], warnings: ["weather_region_review_not_bound_to_organization"] }
            end
          end

          day, time_warning = requested_source_day(entities, context.now, future_notices: NOTICE_TOPICS.include?(topic))
          return { status: "unavailable", warnings: [time_warning] } if time_warning

          query = { topic:, area: entities["area_query"].to_s.presence, day:, text: entities["query"].to_s,
                    requested_severity: topic == "weather" && entities["category"] == "weather_yellow" ? "Moderate" : nil }
          read_prepared(keys, query:, context:, locale:)
        rescue WeatherRegionConfiguration::InvalidConfiguration
          { status: "unavailable", facts: [], warnings: ["weather_region_review_not_eligible"] }
        end

        private

        # ReadPort validates the trusted context. This seam also supports
        # standalone source contracts; when supplied, organization is checked
        # by the shared tenant guard, and weather additionally requires a host.
        def trusted_context?(_context)
          true
        end

        def read_prepared(keys, query:, context:, locale:)
          # Select across all prepared candidates before applying the fact limit.
          checks = @source_checker.check(keys:, max_items: CityServiceSourceCheckStore::MAX_ITEMS, deadline: context.deadline)
          candidates = prepared_facts(checks, context)
          selection = select_measurements(candidates, query:, now: context.now)
          shaped_water = query[:topic] == "water_levels" && WaterLevelAnswer.shape(selection.fetch(:facts), text: query[:text], locale:)
          facts = localized_facts(selection.fetch(:facts), locale:)
          warnings = selection_warnings(selection, checks:, query:)
          sources = keys.map { |key| CityServiceSources.fetch(key) }
          validity = { "live_status" => false, "requested_date" => query[:day]&.iso8601, "observation_time" => "only_if_stated_in_source" }
          validity["answer_shape"] = "water_level_v1" if shaped_water
          coverage = { "organization_id" => context.organization_id, "scope" => "source_declared_coverage",
                       "area_query" => query[:area].to_s[0, 160], "area_resolved" => false, "prepared_candidate_count" => candidates.size }
          coverage["reviewed_region_scope"] = reviewed_weather_scope if @weather_region
          status = selection_status(selection, checks:, day: query[:day])
          if @weather_region
            warnings << "weather_region_review_mismatch" if @weather_region_mismatch
            warnings << "weather_warning_metadata_invalid" if @weather_warning_invalid
            # An empty result needs acquisition provenance too. The currently
            # configured region cannot lend its identity to an earlier fetch.
            empty_unbound = checks.any? do |check|
              next false unless check.status == :empty

              acquired = check.coverage.to_h["weather_region_review_id"] if check.respond_to?(:coverage)
              check.source_key != "weather_warnings" || acquired != @weather_region.identity
            end
            warnings << "weather_empty_snapshot_not_region_bound" if empty_unbound
            status = "unavailable" if facts.empty? && (@weather_region_mismatch || @weather_warning_invalid || empty_unbound)
          end
          { status:, facts:,
            source: { "id" => keys.join(":"), "label" => sources.map { |row| row.fetch(:provider) }.uniq.join("; "), "url" => sources.first.fetch(:source_url) },
            checked_at: checks.filter_map(&:checked_at).max&.iso8601,
            coverage:, validity:, warnings: }
        end

        def prepared_facts(checks, context)
          checks.select { |check| [:ok, :unreviewed].include?(check.status) }.flat_map do |check|
            check.notices.flat_map { |notice| notice_facts(notice, check, context) }.each do |fact|
              fact["warning_codes"] = Array(fact["warning_codes"]) + ["source_facts_unconfirmed"] if check.status == :unreviewed
            end
          end
        end

        def select_measurements(candidates, query:, now:)
          selected = filter_area(candidates, query[:area], query[:topic], text: query[:text])
          selected = selected.select { |fact| fact["provider_severity"] == query[:requested_severity] } if query[:requested_severity]
          requested_scope = query[:area].presence || (WaterLevelAnswer.requested_rivers(query[:text]).presence if query[:topic] == "water_levels")
          unsupported = unsupported_area?(candidates, selected, requested_scope)
          day = query[:day]
          selected = selected.select { |fact| observed_on?(fact, day) } if day
          historical = historical_day?(day, now)
          eligible = selected.select { |fact| eligible_measurement?(fact, historical:, requested_day: day) }
          conflicts = SourceMeasurement.conflicting_observations(eligible)
          facts = conflicts.any? ? conflicts : eligible.first(MAX_FACTS)
          { facts:, conflict: conflicts.any?, area_unsupported: unsupported, historical:, candidates_empty: candidates.empty?,
            expired: selected.any? { |fact| fact["_expired"] },
            stale: selected.any? { |fact| fact["_stale"] }, future: selected.any? { |fact| fact["_future"] } }
        end

        def unsupported_area?(candidates, selected, area)
          area.present? && candidates.any? && selected.empty?
        end

        def historical_day?(day, now)
          day && day < local_date(now)
        end

        def eligible_measurement?(fact, historical:, requested_day:)
          return !fact["_expired"] || requested_day.present? if NOTICE_KINDS.include?(fact["kind"])

          !fact["_future"] && (!fact["_stale"] || historical)
        end

        def observed_on?(fact, day)
          return notice_applies_on?(fact, day) if NOTICE_KINDS.include?(fact["kind"])

          fact["observed_at"] && local_date(Time.iso8601(fact["observed_at"])) == day
        end

        def notice_applies_on?(fact, day)
          # A report timestamp is an observation date, not an outage window.
          return source_time_on?(fact["source_published_at"], day) if fact["kind"] == "road_condition"
          return source_time_on?(fact["checked_at"], day) if fact["kind"] == "campaign_status" && fact["temporal_status"] == "no_current_campaign_listed"

          start_at, end_at = [fact["starts_at"], fact["ends_at"]].map { |value| parse_source_time(value) }
          return false unless start_at && end_at

          day_start, day_end = local_day_bounds(day)
          start_at < day_end && end_at > day_start
        end

        def source_time_on?(value, day)
          time = parse_source_time(value)
          time.present? && local_date(time) == day
        end

        def localized_facts(facts, locale:)
          facts.each do |fact|
            fact.delete("_stale")
            fact.delete("_future")
            fact.delete("_expired")
            fact["text"] = clean_text(fact["text"], limit: MAX_TEXT)
            if fact.fetch("warning_codes", []).include?("source_facts_unconfirmed")
              fact["text"] = "#{I18n.t("decidim_app.city_service_events.bot.unconfirmed_facts", locale:)} #{fact["text"]}"
            end
            fact["text"] = cyrillize(fact["text"], locale:)
          end
        end

        def selection_warnings(selection, checks:, query:)
          facts = selection.fetch(:facts)
          warnings = facts.flat_map { |fact| fact.fetch("warning_codes", []) }
          warnings.unshift("conflicting_current_facts") if selection[:conflict]
          warnings << "source_observation_not_area_status"
          warnings << "partial_source_coverage" if checks.any? { |check| check.status != :ok || check.error_code.present? }
          flags = {
            "source_notice_expired" => selection[:expired],
            "measurement_stale" => selection[:stale], "measurement_time_in_future" => selection[:future],
            "measurement_metadata_not_available" => missing_measurement_metadata?(selection, checks, query[:topic]),
            "historical_snapshot_not_complete_series" => selection[:historical],
            "requested_area_not_supported_by_source" => selection[:area_unsupported],
            "requested_date_not_available_in_snapshot" => query[:day] && facts.empty?
          }
          flags.each { |warning, present| warnings << warning if present }
          warnings.uniq
        end

        def missing_measurement_metadata?(selection, checks, topic)
          selection[:candidates_empty] && checks.any? { |check| check.status == :ok } && %w(air_quality water_levels).include?(topic)
        end

        def selection_status(selection, checks:, day:)
          return "unreviewed" if selection[:conflict]
          return "ambiguous" if selection[:area_unsupported]
          return "ok" if selection.fetch(:facts).any?
          return "stale" if selection[:stale] || checks.any? { |check| check.status == :stale }

          source_status(checks, day:)
        end

        def source_status(checks, day:)
          return "unavailable" if checks.any? { |check| [:unavailable, :malformed].include?(check.status) }
          return "unreviewed" if checks.any? { |check| check.status == :unreviewed }
          return "empty" if !day && checks.any? && checks.all? { |check| check.status == :empty }

          "unavailable"
        end

        def notice_facts(notice, check, context)
          source = CityServiceSources.fetch(check.source_key)
          return [] unless safe_source_url?(notice.url, source)

          metadata = notice.respond_to?(:metadata) && notice.metadata.is_a?(Hash) ? notice.metadata.deep_stringify_keys : {}
          return [] if check.source_key == "weather_warnings" && !eligible_weather_notice?(metadata, notice.url, context.now)

          case check.source_key
          when "water_levels"
            Array(metadata["readings"]).filter_map.with_index do |reading, index|
              measurement_fact(notice, check, context, metadata.merge(reading).merge("unit" => reading["unit"], "kind" => "water_level_observation"), index:)
            end
          when "air_quality_realtime"
            value = measurement_fact(notice, check, context, metadata, index: 0)
            value ? [value] : []
          when "air_quality"
            [base_fact(notice, check, context).merge(
              "kind" => "source_document",
              "text" => "#{notice.title}. Ovo je poveznica na izvještaj; vrijednosti mjerenja i njihovo vrijeme nisu izdvojeni iz PDF-a. #{notice.url}",
              "authority" => "official_document", "warning_codes" => %w(document_link_not_measurement measurement_period_not_extracted)
            )]
          else
            [information_fact(notice, check, context, metadata)]
          end
        end

        def information_fact(notice, check, context, metadata)
          fact = base_fact(notice, check, context).merge("kind" => "source_information", "text" => [notice.title, notice.body].compact.uniq.join("\n"))
          NOTICE_KINDS.include?(metadata["kind"]) ? source_notice_fact(fact, metadata, context.now) : fact
        end

        def source_notice_fact(fact, metadata, now)
          starts_at = parse_source_time(metadata["starts_at"])
          ends_at = parse_source_time(metadata["ends_at"])
          valid_window = starts_at && ends_at && ends_at > starts_at
          expired = valid_window && ends_at <= now
          fact = weather_region_fact(fact, metadata)
          metadata = metadata.merge("affected_area_text" => fact["verified_region_label"]) if fact["verified_region_label"]
          fact.merge(metadata.slice(*NOTICE_FIELDS)).merge(
            "starts_at" => valid_window ? starts_at.in_time_zone("Europe/Sarajevo").iso8601 : nil,
            "ends_at" => valid_window ? ends_at.in_time_zone("Europe/Sarajevo").iso8601 : nil,
            "source_validity" => metadata.slice("starts_at", "ends_at"),
            "display_timezone" => "Europe/Sarajevo",
            "local_validity" => valid_window ? "#{starts_at.in_time_zone('Europe/Sarajevo').strftime('%d.%m.%Y. %H:%M %:z')} – #{ends_at.in_time_zone('Europe/Sarajevo').strftime('%d.%m.%Y. %H:%M %:z')} (Europe/Sarajevo)" : nil,
            "time_presentation" => "Use local_validity for citizen-facing dates and clock times. Original body/source_validity may use UTC; do not present UTC clock values as local time.",
            "temporal_status" => valid_window ? notice_temporal_status(starts_at, ends_at, now) : metadata["temporal_status"],
            "coverage" => fact.fetch("coverage").merge("source_area_text" => metadata["affected_area_text"], "area_ids" => []),
            "warning_codes" => fact.fetch("warning_codes") + ["source_coverage_not_verified_mz_or_komsiluk"], "_expired" => expired == true
          )
        end

        def reviewed_weather_scope
          { "basis" => "operator_reviewed_region_coverage", "review_id" => @weather_region.identity,
            "provider_area_code" => @weather_region.provider_area_code, "region_label" => @weather_region.region_label,
            "community_label" => @weather_region.community_label, "source_url" => @weather_region.source_url,
            "evidence_url" => @weather_region.evidence_url, "reviewed_on" => @weather_region.reviewed_on.iso8601,
            "valid_until" => @weather_region.valid_until.iso8601, "live_warning_status" => false }
        end

        def eligible_weather_notice?(metadata, url, now)
          unless @weather_region && @organization && @weather_region.matches_metadata?(metadata,
                   organization_host: @organization.host, source_url: url, day: local_date(now))
            @weather_region_mismatch = true
            return false
          end
          start = parse_source_time(metadata["starts_at"])
          finish = parse_source_time(metadata["ends_at"])
          effective = parse_source_time(metadata["effective_at"] || metadata["source_published_at"])
          published = parse_source_time(metadata["source_published_at"])
          valid = metadata["kind"] == "official_warning" && start && finish && finish > start &&
                  effective && effective <= now && published && published <= now
          @weather_warning_invalid = true unless valid
          valid
        end

        def weather_region_fact(fact, metadata)
          return fact unless fact["source_id"] == "weather_warnings" && @weather_region

          region = @weather_region.display_label
          explanation = "Prema operatorovom pregledanom regionalnom obuhvatu: #{region}. " \
                        "Naziv regiona u izvoru je #{metadata['affected_area_text']}; to nije prognoza za pojedinu ulicu ili kuću."
          fact.merge("verified_region_label" => region, "provider_region_label" => metadata["affected_area_text"],
                     "city_applicability" => explanation,
                     "board_publication_policy" => { "eligible_severities" => CityServiceWeatherParser::BOARD_SEVERITIES,
                                                     "absence_not_warning_absence" => true,
                                                     "regional_targeting" => "Regional scope does not assign MZ or komsiluk board targets." },
                     "text" => "#{explanation}\n#{fact.fetch('text')}")
        end

        def notice_temporal_status(starts_at, ends_at, now)
          return "expired" if ends_at <= now

          starts_at > now ? "upcoming" : "active"
        end

        def parse_source_time(value)
          Time.iso8601(value.to_s) if value.present?
        rescue ArgumentError
          nil
        end

        def measurement_fact(notice, check, context, metadata, index:)
          observation = SourceMeasurement.call(metadata:, source_key: check.source_key, now: context.now)
          return unless observation

          base_fact(notice, check, context).merge(observation).merge(
            "id" => "source:#{check.source_key}:#{Digest::SHA256.hexdigest([notice.fingerprint, observation["station"], index].join(":"))[0, 20]}"
          )
        end

        def base_fact(notice, check, context)
          source = CityServiceSources.fetch(check.source_key)
          { "id" => "source:#{check.source_key}:#{Digest::SHA256.hexdigest(notice.fingerprint.to_s)[0, 20]}",
            "source_id" => check.source_key, "source_label" => source.fetch(:provider), "source_url" => notice.url,
            "checked_at" => check.checked_at&.iso8601,
            "coverage" => { "organization_id" => context.organization_id, "scope" => source.fetch(:location_granularity) },
            "warning_codes" => ["source_observation_not_area_status"] }
        end

        def filter_area(facts, area, topic, text: nil)
          return WaterLevelAnswer.select(facts, area:, text:) if topic == "water_levels"

          return facts if area.blank? || AREA_WIDE_TERMS.include?(fold(area))

          if NOTICE_TOPICS.include?(topic)
            needle = " #{fold(area)} "
            return facts.select { |fact| " #{fold([fact["affected_area_text"], fact["provider_region_label"]].compact.join(" "))} ".include?(needle) }
          end
          return facts unless %w(water_levels air_quality).include?(topic)

          needle = fold(area)
          facts.select { |fact| fact["station"].present? && " #{fold(fact["station"])} ".include?(" #{needle} ") }
        end

        # Reader policy over the shared day vocabulary: yesterday is a valid
        # measurement day, tomorrow only for notices, and an explicit date may
        # be written the way the source writes it (ISO, dd.mm.yyyy or named).
        def requested_source_day(entities, now, future_notices: false)
          value = (entities["date"].presence || entities["time_expression"]).to_s.strip
          return [nil, nil] if value.empty?

          today = local_date(now)
          parsed = relative_day(fold(value), today:)
          case parsed.kind
          when :today, :yesterday then [parsed.day, nil]
          when :tomorrow then future_notices ? [parsed.day, nil] : [nil, "future_measurement_not_available"]
          else explicit_requested_day(value, today, future_notices:)
          end
        rescue ArgumentError
          [nil, "measurement_time_query_not_supported"]
        end

        def explicit_requested_day(value, today, future_notices:)
          date = explicit_date(value)
          return [nil, "measurement_time_query_not_supported"] unless date
          return [nil, "future_measurement_not_available"] if date > today && !future_notices

          [date, nil]
        end

        def explicit_date(value)
          value.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(value) : CityServiceTime.date(value, reference: nil)
        end

        def safe_source_url?(value, source)
          uri = URI.parse(value.to_s)
          configured = URI.parse(source.fetch(:source_url))
          uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? && uri.host&.delete_prefix("www.") == configured.host&.delete_prefix("www.")
        rescue URI::InvalidURIError
          false
        end
      end
    end
  end
end
