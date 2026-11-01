# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    class CityServiceEventFeed
      EVENT_KEYWORDS = %w(
        struja struje strujom elektric iskljuc iskljucenja prekid vode voda vodom
        kvar obavjestenje obavjestenja trenutno danas sutra grijanje grejanje toplana toplovod
      ).freeze
      LOCATION_WORDS = %w(u za na kod mz komsiluk naselje).freeze
      LOCATION_PHRASES = ["mjesna zajednica"].freeze
      CURRENT_WINDOW = 12.hours
      SOURCE_CHECK_TTL = 10.minutes
      SOURCE_CHECK_CACHE_VERSION = 2
      QUERY_LIMIT = 20
      SERVICE_FILTERS = {
        electricity: {
          key: :electricity,
          keywords: %w(struja struje strujom elektric elektro),
          source_keys: %w(electricity_outages),
          event_types: %w(planned_outage unplanned_outage restoration_update),
          service_i18n_key: :electricity
        },
        water: {
          key: :water,
          keywords: %w(voda vode vodom vodovod vodosnabdijevanje vodosnabdevanje),
          source_keys: %w(water_service),
          event_types: %w(planned_interruption unplanned_interruption restoration_update),
          service_i18n_key: :water
        },
        heating: {
          key: :heating,
          keywords: %w(grijanje grejanje toplana toplovod),
          source_keys: %w(heating_service),
          event_types: %w(heating_interruption restoration_update fuel_supply_warning),
          service_i18n_key: :heating
        }
      }.freeze

      ScopedServiceQuery = Struct.new(
        :status,
        :events,
        :topic,
        :area_identifiers,
        :starts_at,
        :ends_at,
        :error_code,
        keyword_init: true
      ) do
        STATUSES = [:ok, :empty, :conflict, :invalid, :unavailable, :deadline_exceeded].freeze

        def initialize(**attributes)
          attributes[:status] = attributes.fetch(:status).to_sym
          raise ArgumentError, "unknown scoped query status: #{attributes[:status]}" unless STATUSES.include?(attributes[:status])

          attributes[:events] = Array(attributes[:events]).freeze
          attributes[:area_identifiers] = Array(attributes[:area_identifiers]).map(&:to_s).uniq.freeze
          attributes[:error_code] = attributes[:error_code]&.to_sym
          super
          freeze
        end
      end

      def initialize(organization:, source_checker: nil)
        @organization = organization
        @matcher = CityServiceAreaMatcher.new(organization:)
        @source_checker = source_checker || CityServiceSourceCheckStore.new
      end

      def answer(text:, locale: I18n.locale)
        folded = fold(text)
        return nil unless EVENT_KEYWORDS.any? { |keyword| folded.include?(keyword) }

        match = @matcher.match_query(text)
        return location_not_recognized(locale:) if wants_location?(folded) && match.unknown?

        filter = service_filter_for(folded)
        return I18n.t("decidim_app.city_service_events.bot.source_disabled_by_owner", locale:) if filter &&
          filter.fetch(:source_keys).any? { |source_key| !CityServiceSources.enabled?(source_key) }

        now = Time.current
        result = query(
          topic: filter&.fetch(:key),
          area_identifiers: match.slugs,
          starts_at: now,
          ends_at: now + CURRENT_WINDOW,
          deadline: nil
        )
        return no_current_event(match, filter, locale:, query_result: result) if result.events.empty?

        if result.status == :conflict
          warning = I18n.t("decidim.bih.dialogue.read_warning_conflicting_facts", locale:)
          return ([warning] + result.events.map { |event| current_event(event, locale:, requested_area_slugs: match.slugs) }).join("\n\n")
        end

        current_event(result.events.first, locale:, requested_area_slugs: match.slugs)
      end

      # Structured callers pass accepted topic/area/time slots directly. All
      # scope predicates are applied in SQL before ordering and limiting.
      def query(topic:, area_identifiers:, starts_at:, ends_at:, deadline:)
        context = { topic:, area_identifiers:, starts_at:, ends_at: }
        return query_result(:invalid, context, error_code: :invalid_deadline) unless valid_deadline?(deadline)
        return query_result(:deadline_exceeded, context, error_code: :deadline_exceeded) if deadline_expired?(deadline)

        filter = filter_for_topic(topic)
        if filter && filter.fetch(:source_keys).any? { |source_key| !CityServiceSources.enabled?(source_key) }
          return query_result(:unavailable, context, error_code: :source_disabled_by_owner)
        end
        validation_error = query_validation_error(context, filter)
        return query_result(:invalid, context, error_code: validation_error) if validation_error

        slugs = Array(area_identifiers).map(&:to_s).compact_blank.uniq
        context[:area_identifiers] = slugs
        events, conflict = scoped_events(filter:, slugs:, starts_at:, ends_at:, deadline:)
        return query_result(:deadline_exceeded, context, error_code: :deadline_exceeded) if deadline_expired?(deadline)

        completed_query_result(context, events:, conflict:)
      rescue StandardError => e
        error_code = query_error_code(e)
        log_query_failure(e, error_code)
        status = error_code == :deadline_exceeded ? :deadline_exceeded : :unavailable
        query_result(status, context, error_code:)
      end

      private

      attr_reader :organization, :source_checker

      def completed_query_result(context, events:, conflict:)
        return query_result(:conflict, context, events:, error_code: :conflicting_current_facts) if conflict

        query_result(events.empty? ? :empty : :ok, context, events:)
      end

      def current_event(event, locale:, requested_area_slugs: [])
        checked_at = formatted_checked_at(event.fetched_at)
        key = checked_at ? "current" : "current_unchecked"
        values = {
          locale:,
          title: event.title,
          summary: event.summary,
          source: event.source_label_text,
          url: event.source_url
        }
        values[:checked_at] = checked_at if checked_at
        text = I18n.t("decidim_app.city_service_events.bot.#{key}", **values)
        text += operator_correction_notice(event, locale:)
        text += unconfirmed_evidence_notice(event, locale:)
        text += "\n\n#{CityServicePlaceContext.notice(event, locale:)}" if CityServicePlaceContext.places(event).any?
        coverage = event.extraction_metadata.fetch("coverage", {})
        partial = CityServicePlaceContext.partial_coverage?(coverage)
        overlap_only = CityServicePlaceContext.overlap_only?(coverage, requested_area_slugs)
        text += "\n\n#{I18n.t("decidim_app.city_service_events.bot.partial_coverage", locale:)}" if partial
        text += "\n\n#{I18n.t("decidim_app.city_service_events.bot.possible_overlap", locale:)}" if overlap_only
        text
      end

      def unconfirmed_evidence_notice(event, locale:)
        keys = []
        keys << "unconfirmed_facts" unless event.facts_confirmed?
        keys << "unconfirmed_area" if event.targeting_level == "unknown"
        keys << "unconfirmed_time" if event.starts_at.nil? || event.ends_at.nil?
        keys.map { |key| "\n\n#{I18n.t("decidim_app.city_service_events.bot.#{key}", locale:)}" }.join
      end

      def operator_correction_notice(event, locale:)
        return "" if event.extraction_metadata["operator_review"].blank?

        "\n\n#{I18n.t("decidim.bih.dialogue.read_warning_operator_correction", locale:)}"
      end

      def no_current_event(match, filter, locale:, query_result:)
        area = if match.targeting_level == "citywide"
                 I18n.t("decidim_app.city_service_events.bot.citywide_area", locale:)
               else
                 match.slugs.presence&.join(", ") || I18n.t("decidim_app.city_service_events.bot.your_area", locale:)
               end
        if filter && filter.fetch(:source_keys).any? { |source_key| !CityServiceSources.enabled?(source_key) }
          return I18n.t("decidim_app.city_service_events.bot.source_disabled_by_owner", locale:)
        end
        if unavailable_query?(query_result) && filter
          return I18n.t("decidim_app.city_service_events.bot.source_unavailable", locale:, area:, service: service_label(filter, locale:))
        end

        if filter
          source_check = latest_source_check(filter)
          return source_check_answer(source_check, area:, filter:, locale:) if source_check

          return I18n.t("decidim_app.city_service_events.bot.source_unavailable", locale:, area:, service: service_label(filter, locale:))
        end

        I18n.t("decidim_app.city_service_events.bot.none", locale:, area:)
      end

      def location_not_recognized(locale:)
        I18n.t("decidim_app.city_service_events.bot.location_unknown", locale:)
      end

      def wants_location?(folded)
        tokens = folded.split
        LOCATION_PHRASES.any? { |phrase| folded.include?(phrase) } ||
          LOCATION_WORDS.any? { |word| tokens.include?(word) }
      end

      def service_filter_for(folded)
        SERVICE_FILTERS.values.find do |filter|
          filter.fetch(:keywords).any? { |keyword| folded.include?(keyword) }
        end
      end

      def filter_for_topic(topic)
        return if topic.blank?

        SERVICE_FILTERS[topic.to_s.to_sym]
      end

      def valid_time_bound?(value)
        value.nil? || value.is_a?(Time) || value.is_a?(DateTime) || value.is_a?(ActiveSupport::TimeWithZone)
      end

      def query_validation_error(context, filter)
        return :invalid_topic if context.fetch(:topic).present? && !filter
        return :invalid_time_bound unless valid_time_bound?(context.fetch(:starts_at)) && valid_time_bound?(context.fetch(:ends_at))

        starts_at = context.fetch(:starts_at)
        ends_at = context.fetch(:ends_at)
        :invalid_time_window if starts_at && ends_at && ends_at <= starts_at
      end

      def scoped_events(filter:, slugs:, starts_at:, ends_at:, deadline:)
        scope = CityServiceEvent.for_organization(organization).milica_available
        disabled = CityServiceSources.all.reject { |source| source.fetch(:enabled, true) }.map { |source| source.fetch(:key) }
        scope = scope.where.not(source_key: disabled) if disabled.any?
        scope = scope.where("starts_at IS NULL OR starts_at < ?", ends_at) if ends_at
        scope = scope.where("ends_at IS NULL OR ends_at > ?", starts_at) if starts_at
        scope = scope.where(source_key: filter.fetch(:source_keys)) if filter
        scope = scope.where(event_type: filter.fetch(:event_types)) if filter
        scope = scope_for_areas(scope, slugs) if slugs.any?
        CityServiceNoticeCollector.send(:within_deadline, deadline) do
          with_statement_timeout(deadline) do
            conflicts = CityServiceEvidenceConflict.events(scope)
            next [conflicts, true] if conflicts.any?

            if slugs.any?
              priority = CityServiceEvent.sanitize_sql_array([
                                                               "CASE WHEN affected_area_slugs ?| ARRAY[:slugs]::text[] THEN 0 " \
                                                               "WHEN targeting_level = 'citywide' THEN 1 " \
                                                               "WHEN #{prepared_match_sql(slugs)} THEN 2 " \
                                                               "WHEN #{context_match_sql(slugs)} THEN 3 WHEN targeting_level = 'unknown' THEN 5 ELSE 4 END", { slugs: }
                                                             ])
              scope = scope.order(Arel.sql(priority))
            end
            [scope.order(Arel.sql("COALESCE(starts_at, created_at) ASC"), :id).limit(QUERY_LIMIT).to_a, false]
          end
        end
      end

      def scope_for_areas(scope, slugs)
        relevant = scope.where(
          "targeting_level IN (:citywide, 'unknown') OR affected_area_slugs ?| ARRAY[:slugs]::text[]",
          citywide: "citywide", slugs:
        )
        relevant = relevant.or(scope.where(context_match_sql(slugs)))
        slugs.each do |slug|
          relevant = relevant.or(scope.where(
                                   "extraction_metadata -> 'coverage' -> 'notification_candidates' @> ?::jsonb", [{ slug: }].to_json
                                 ))
          relevant = relevant.or(scope.where(
                                   "extraction_metadata -> 'coverage' -> 'affected_places' @> ?::jsonb", [{ slug: }].to_json
                                 ))
        end
        relevant
      end

      def context_match_sql(slugs)
        matches = slugs.map do |slug|
          CityServiceEvent.sanitize_sql_array(["extraction_metadata -> 'place_context' -> 'places' @> ?::jsonb", [{ slug:, relation: "context_only" }].to_json])
        end.join(" OR ")
        "(extraction_metadata -> 'place_context' ->> 'source_content_version' = content_version AND (#{matches}))"
      end

      def prepared_match_sql(slugs)
        matches = slugs.flat_map do |slug|
          %w(affected_places notification_candidates).map do |key|
            CityServiceEvent.sanitize_sql_array(["extraction_metadata -> 'coverage' -> '#{key}' @> ?::jsonb", [{ slug: }].to_json])
          end
        end.join(" OR ")
        "(extraction_metadata -> 'coverage' ->> 'source_content_version' = content_version AND (#{matches}))"
      end

      def unavailable_query?(query_result)
        [:unavailable, :deadline_exceeded].include?(query_result.status)
      end

      def latest_source_check(filter)
        source_key = filter.fetch(:source_keys).first
        source = CityServiceSources.fetch(source_key)
        check = source_checker.check(keys: [source_key], max_items: 1).first
        { provider: source.fetch(:provider), result: check } if check
      rescue StandardError => e
        Rails.logger.warn("[CityServiceEventFeed] prepared source read failed error_class=#{e.class.name}")
        nil
      end

      def cache_fetch_source_check(source_key, &)
        return yield unless defined?(Rails.cache) && Rails.cache

        observed = nil
        attempted = false
        begin
          Rails.cache.fetch("bijeljina/city-service-event-feed/v#{SOURCE_CHECK_CACHE_VERSION}/source-check/#{source_key}", expires_in: SOURCE_CHECK_TTL) do
            attempted = true
            observed = yield
          end
        rescue StandardError
          # A cache write/serialization failure must not discard a completed
          # source check or repeat its network call. A failed cache read may
          # fall through to exactly one uncached check.
          return observed if observed
          raise if attempted

          yield
        end
      end

      def formatted_checked_at(value)
        time = normalized_time(value)&.in_time_zone("Europe/Sarajevo")
        return unless time

        time.strftime("%d.%m.%Y. u %H:%M")
      rescue StandardError
        nil
      end

      def source_check_answer(source_check, area:, filter:, locale:)
        result = source_check.fetch(:result)
        checked_at = formatted_checked_at(result.checked_at)
        status = effective_source_check_status(result, checked_at, filter)
        key = source_check_translation_key(status, checked_at)

        values = {
          locale:,
          area:,
          source: source_check.fetch(:provider),
          service: service_label(filter, locale:)
        }
        values[:checked_at] = checked_at if checked_at
        I18n.t("decidim_app.city_service_events.bot.#{key}", **values)
      end

      def effective_source_check_status(result, checked_at, filter)
        return :stale if checked_at && source_check_stale?(result.checked_at, filter)

        result.status
      end

      def source_check_translation_key(status, checked_at)
        return :source_unavailable unless checked_at || [:unavailable, :malformed].include?(status)

        {
          ok: :pending_review,
          empty: :none_reviewed,
          unreviewed: :source_unreviewed,
          malformed: :source_malformed,
          stale: :source_stale
        }.fetch(status, :source_unavailable)
      end

      def source_check_stale?(checked_at, filter)
        time = normalized_time(checked_at)
        return true unless time

        time < Time.current - CityServiceSources::HEALTH_MAX_AGES.fetch(
          CityServiceSources.fetch(filter.fetch(:source_keys).first).fetch(:scrape_cadence)
        )
      rescue StandardError
        true
      end

      def normalized_time(value)
        return if value.blank?

        time = if value.is_a?(String)
                 Time.iso8601(value)
               elsif valid_time_bound?(value)
                 value.in_time_zone("Europe/Sarajevo")
               end
        return if time.nil? || time > Time.current

        time
      rescue StandardError
        nil
      end

      def query_result(status, context, events: [], error_code: nil)
        ScopedServiceQuery.new(status:, events:, error_code:, **context)
      end

      def deadline_expired?(deadline)
        seconds = CityServiceNoticeCollector.send(:remaining_seconds, deadline)
        seconds && seconds <= 0
      end

      def valid_deadline?(deadline)
        CityServiceNoticeCollector.send(:remaining_seconds, deadline)
        true
      rescue CityServiceNoticeCollector::InvalidDeadline
        false
      end

      def with_statement_timeout(deadline)
        seconds = CityServiceNoticeCollector.send(:remaining_seconds, deadline)
        return yield if seconds.nil?
        raise CityServiceNoticeCollector::DeadlineExceeded, "query deadline expired" if seconds <= 0

        milliseconds = [(seconds * 1000).floor, 1].max
        connection = CityServiceEvent.connection
        previous = connection.select_value("SHOW statement_timeout")
        connection.transaction(requires_new: true) do
          connection.execute("SET LOCAL statement_timeout = #{milliseconds}")
          result = yield
          connection.execute("SET LOCAL statement_timeout = #{connection.quote(previous)}")
          result
        end
      end

      def query_error_code(error)
        return :deadline_exceeded if error.is_a?(CityServiceNoticeCollector::DeadlineExceeded)
        return :deadline_exceeded if defined?(ActiveRecord::QueryCanceled) && error.is_a?(ActiveRecord::QueryCanceled)

        :query_failed
      end

      def log_query_failure(error, error_code)
        Rails.logger.warn(
          "[CityServiceEventFeed] scoped query failed error_class=#{error.class.name} error_code=#{error_code}"
        )
      end

      def service_label(filter, locale:)
        I18n.t(
          "decidim_app.city_service_events.bot.services.#{filter.fetch(:service_i18n_key)}",
          locale:
        )
      end

      def fold(value)
        Decidim::Bih::Text.fold(value.to_s)
      end
    end
  end
end
