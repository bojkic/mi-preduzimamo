# frozen_string_literal: true

require "digest"
require "json"

module DecidimApp
  module Bijeljina
    # The citizen path only reads durable prepared checks. Network work belongs
    # in refresh/record, invoked by the scheduled source scraper. The database
    # is authoritative: Redis loss or a Puma restart cannot erase last-good data.
    class CityServiceSourceCheckStore
      PARSER_VERSION = "source-check-v2"
      MAX_ITEMS = 30
      HISTORY_LIMIT = 12
      Result = Struct.new(:source_key, :status, :notices, :checked_at, :error_code,
                          :attempted_at, :last_success_at, :content_hash, :coverage, :last_good_evidence, keyword_init: true)

      def initialize(model: DecidimApp::CityServiceSourceSnapshot, collector: CityServiceNoticeCollector, clock: -> { Time.current })
        @model = model
        @collector = collector
        @clock = clock
      end

      def self.check(**)
        new.check(**)
      end

      # Keep the legacy timeout keyword; prepared reads use the caller deadline.
      def check(keys: [], max_items: MAX_ITEMS, deadline: nil, timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
        limit = bounded_limit(max_items)
        sources(keys).map do |source|
          within_deadline(deadline) { read_check(source, limit:) }
        end
      end

      # A lock loser reads current prepared state immediately; it never starts a
      # duplicate fetch. A caller timeout does not overwrite shared source health.
      def refresh(keys: [], max_items: MAX_ITEMS, deadline: nil, fetcher: nil, now: nil)
        bounded_limit(max_items)
        deadline ||= SourceRefreshBudget.new(timeout: 120)
        sources(keys).map do |source|
          within_deadline(deadline) do
            refreshed = with_refresh_lock(source.fetch(:key)) do
              observed_response = nil
              upstream = fetcher || ->(**arguments) { CityServiceNoticeCollector.send(:fetch_source, **arguments) }
              capturing_fetcher = lambda do |**arguments|
                arguments = arguments.except(:deadline) unless accepts_deadline?(upstream)
                observed_response = upstream.call(**arguments)
              end
              options = { keys: [source.fetch(:key)], max_items: MAX_ITEMS, deadline:, now: now || clock.call, fetcher: capturing_fetcher }
              check = collector.check(**options).first
              check = record(check:, source:, response: observed_response, attempted_at: now || clock.call) unless caller_timeout?(check, deadline)
              check
            end
            refreshed || read_check(source, limit: MAX_ITEMS)
          end
        end
      end

      # Feed a response already fetched by the source scraper through the same
      # collector and record contract; no second HTTP request is necessary.
      def record(check:, source: nil, response: nil, attempted_at: clock.call, diagnostics: {})
        return unless check

        return if [:deadline_exceeded, :invalid_deadline].include?(check.error_code)

        source ||= CityServiceSources.fetch(check.source_key)
        raise ArgumentError, "source/check identity mismatch" unless source.fetch(:key) == check.source_key

        if source.fetch(:key) == "weather_warnings" && [:ok, :empty, :unreviewed].include?(check.status) && check.error_code.nil?
          acquired = check.weather_region_review_id if check.respond_to?(:weather_region_review_id)
          notices_bound = check.notices.all? do |notice|
            notice.source_key == source.fetch(:key) && notice.metadata.is_a?(Hash) &&
              notice.metadata["weather_region_review_id"] == acquired
          end
          unless acquired && acquired == weather_review_id_for(source) && notices_bound
            check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: check.source_key, status: :unavailable,
              notices: [], checked_at: nil, error_code: :weather_acquisition_review_changed)
          end
        end
        payload = serialize_check(check)
        payload["collection"] = collection_health(check, diagnostics, attempted_at)
        payload["http_status"] = response[:http_status] if response
        hash = response && Digest::SHA256.hexdigest(response.fetch(:body, "").to_s)
        hash ||= Digest::SHA256.hexdigest(JSON.generate(payload.fetch("notices")))
        version_options = payload["weather_region_review_id"] ? { weather_region_review_id: payload["weather_region_review_id"] } : {}
        promote(source_key: source.fetch(:key), source_version: version_for(source, **version_options), payload:,
                success: [:ok, :empty, :unreviewed].include?(check.status) && check.error_code.nil?, attempted_at:,
                checked_at: check.checked_at, content_hash: hash)
        check
      end

      # Shared durable primitive for the transport materializer. Payload must be
      # normalized public data. Failed stages only change latest-attempt state.
      # Explicit keyword evidence fields prevent positional source/version mixups.
      def promote(source_key:, source_version:, payload:, success:, attempted_at:, checked_at: nil, content_hash: nil) # rubocop:disable Metrics/ParameterLists
        model.transaction do
          row = model.find_or_create_by!(source_key:) { |entry| entry.source_version = source_version }
          row.lock!
          same_version = row.source_version == source_version
          history = same_version ? Array(row.check_payload["history"]) : []
          previous = row.check_payload.except("history")
          history << previous.slice("status", "checked_at", "attempted_at", "error_code", "content_hash", "collection", "weather_region_review_id") if previous.present?
          row.check_payload = payload.merge("attempted_at" => attempted_at.iso8601, "content_hash" => content_hash,
                                            "history" => history.last(HISTORY_LIMIT))
          row.attempted_at = attempted_at
          if success
            row.source_version = source_version
            row.last_good_payload = payload
            row.last_success_at = checked_at
            row.content_hash = content_hash
          elsif !same_version
            # Retain previous payload/version for recovery, but mark which new
            # version failed so it can never be read as a successful new source.
            row.check_payload = row.check_payload.merge("failed_source_version" => source_version)
          end
          row.save!
          row
        end
      end

      def snapshot(source_key:)
        model.find_by(source_key:)
      end

      def with_refresh_lock(source_key)
        # Session advisory locks cover HTTP/parsing without a long transaction.
        # Separate refreshes of unrelated sources remain independent.
        lock_id = Digest::SHA256.hexdigest("milica-source-refresh:#{source_key}")[0, 15].to_i(16)
        model.connection_pool.with_connection do |connection|
          acquired = connection.select_value("SELECT pg_try_advisory_lock(#{lock_id})")
          next unless acquired == true || acquired == "t"

          begin
            yield
          ensure
            connection.select_value("SELECT pg_advisory_unlock(#{lock_id})")
          end
        end
      end

      def version_for(source, weather_region_review_id: :current)
        identity = [PARSER_VERSION, source]
        parser = event_parser_identity(source.fetch(:key))
        identity << parser if parser
        if source.fetch(:key) == "weather_warnings"
          review_id = weather_region_review_id == :current ? weather_review_id_for(source) : weather_region_review_id
          identity << ["weather-acquisition-review-v1", review_id || "unavailable"]
        end
        Digest::SHA256.hexdigest(JSON.generate(identity))
      end

      private

      attr_reader :model, :collector, :clock

      def weather_review_id_for(source)
        WeatherRegionConfiguration.for_source(source_url: source.fetch(:source_url),
          day: clock.call.in_time_zone("Europe/Sarajevo").to_date).identity
      rescue WeatherRegionConfiguration::InvalidConfiguration
        nil
      end

      def event_parser_identity(key)
        return ElectricityOutageParser::PARSER_VERSION if key == ElectricityOutageParser::SOURCE_KEY
        return WeatherCapFeed::VERSION if key == "weather_warnings"
        return CityServiceNoticeCollector::WATER_LEVEL_PARSER_VERSION if key == "water_levels"

        CityServiceOfficialPostParser::PARSER_VERSIONS[key]
      end

      def sources(keys)
        selected = Array(keys).map(&:to_s).reject(&:empty?)
        selected.empty? ? CityServiceSources.all : selected.uniq.map { |key| CityServiceSources.fetch(key) }
      end

      def bounded_limit(value)
        limit = Integer(value)
        raise ArgumentError, "max_items must be between 1 and #{MAX_ITEMS}" unless limit.between?(1, MAX_ITEMS)

        limit
      end

      def accepts_deadline?(upstream)
        upstream.parameters.any? { |kind, name| kind == :keyrest || ([:key, :keyreq].include?(kind) && name == :deadline) }
      end

      def checked_status(status, checked_at, source)
        return status unless [:ok, :empty, :unreviewed].include?(status)

        max_age = CityServiceSources::HEALTH_MAX_AGES.fetch(source.fetch(:scrape_cadence))
        checked_at && checked_at <= clock.call && checked_at >= clock.call - max_age ? status : :stale
      end

      def read_check(source, limit:)
        row = snapshot(source_key: source.fetch(:key))
        return unavailable(source, :prepared_source_missing) unless row
        current_version = version_for(source)
        if row.source_version != current_version
          # A failed refresh records the attempted version without replacing
          # the last successful version. Its failure remains current evidence.
          payload = row.check_payload || {}
          failed_current = payload["failed_source_version"] == current_version && payload["error_code"].present?
          return unavailable(source, :prepared_source_version_changed, row:) unless failed_current
        end

        payload = row.check_payload
        status = payload.fetch("status", "unavailable").to_sym
        checked_at = parse_time(payload["checked_at"])
        status = checked_status(status, checked_at, source)
        # A partial collector result may carry status=ok for its individual
        # notices; the batch itself is not safe as current answer evidence.
        if payload["error_code"].present? && [:ok, :empty, :unreviewed].include?(status)
          status = payload["error_code"].start_with?("partial_") ? :partial : :unavailable
        end
        notices = [:ok, :unreviewed].include?(status) ? deserialize_notices(payload["notices"]).first(limit) : []
        Result.new(source_key: source.fetch(:key), status:, notices:, checked_at:,
                   error_code: status == :stale && payload["status"] != "stale" ? :prepared_source_stale : payload["error_code"]&.to_sym,
                   attempted_at: row.attempted_at, last_success_at: row.last_success_at,
                   last_good_evidence: last_good_evidence(row),
                   content_hash: payload["content_hash"], coverage: { "max_items" => MAX_ITEMS, "returned_items" => notices.size, "prepared" => true }.merge(
                     source.fetch(:key) == "weather_warnings" ? { "weather_region_review_id" => payload["weather_region_review_id"] } : {}))
      rescue ActiveRecord::ActiveRecordError, JSON::ParserError, TypeError, KeyError
        unavailable(source, :prepared_source_unavailable)
      end

      def unavailable(source, code, row: nil)
        Result.new(source_key: source.fetch(:key), status: :unavailable, notices: [], error_code: code,
                   attempted_at: row&.attempted_at, last_success_at: row&.last_success_at, content_hash: row&.content_hash,
                   coverage: { "prepared" => true }, last_good_evidence: row && last_good_evidence(row))
      end

      def last_good_evidence(row)
        payload = row.last_good_payload || {}
        { "available" => payload.present?, "checked_at" => payload["checked_at"],
          "record_count" => Array(payload["notices"]).size,
          "usage" => "retained_for_review_not_current_answer_evidence" }
      end

      def collection_health(check, diagnostics, attempted_at)
        code = check.error_code&.to_s
        previous = snapshot(source_key: check.source_key)
        last_good = code.nil? && [:ok, :empty, :unreviewed].include?(check.status) ? check.checked_at : previous&.last_success_at
        normalized = diagnostics.deep_stringify_keys
        normalized["retry_at"] = normalized["retry_at"].iso8601 if normalized["retry_at"].respond_to?(:iso8601)
        normalized.merge("outcome" => collection_outcome(check, code), "complete" => code.nil? && [:ok, :empty, :unreviewed].include?(check.status),
                         "last_good_age_seconds" => last_good && [attempted_at - last_good, 0].max.to_i)
      end

      def collection_outcome(check, code)
        if %w(source_host_busy source_host_backoff).include?(code)
          "deferred"
        elsif %w(robots_disallowed source_ai_input_disallowed source_provider_blocked).include?(code)
          "policy_blocked"
        elsif code&.start_with?("partial_")
          "partial"
        elsif code
          "failed"
        else
          { "empty" => "healthy_empty", "unreviewed" => "awaiting_review", "ok" => "healthy" }.fetch(check.status.to_s, "failed")
        end
      end

      def serialize_check(check)
        provenance = if check.source_key == "weather_warnings" && check.respond_to?(:weather_region_review_id)
                       { "weather_region_review_id" => check.weather_region_review_id }.compact
                     else
                       {}
                     end
        provenance.merge("status" => check.status.to_s, "checked_at" => check.checked_at&.iso8601,
          "error_code" => check.error_code&.to_s,
          "notices" => Array(check.notices).first(MAX_ITEMS).map do |notice|
            notice.to_h.transform_values { |value| value.respond_to?(:iso8601) ? value.iso8601 : value }
          end)
      end

      def deserialize_notices(notices)
        Array(notices).map do |attributes|
          values = attributes.symbolize_keys.slice(*CityServiceNoticeCollector::Notice.members)
          values[:fetched_at] = parse_time(values[:fetched_at])
          CityServiceNoticeCollector::Notice.new(**values)
        end
      end

      def parse_time(value)
        Time.iso8601(value.to_s) if value.present?
      rescue ArgumentError
        nil
      end

      def caller_timeout?(check, deadline)
        deadline && (deadline.expired? || [:deadline_exceeded, :invalid_deadline].include?(check&.error_code))
      end

      def within_deadline(deadline, &)
        CityServiceNoticeCollector.send(:remaining_seconds, deadline)
        CityServiceNoticeCollector.send(:within_deadline, deadline, &)
      end
    end
  end
end
