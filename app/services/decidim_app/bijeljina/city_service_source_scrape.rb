# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # Periodic live scrape runner for reviewed Bijeljina service sources.
    #
    # The runner fetches every selected source on the configured cadence
    # cadence. Sources with deterministic parsers create/update pending-review
    # CityServiceEvent rows. Sources without parsers are still fetched and
    # counted through the bounded notice collector, but never auto-published.
    class CityServiceSourceScrape
      # Sources whose listing page publishes teasers, so the notice only exists
      # behind the article link. Water has always been here; heating was the
      # omission that kept the heating domain silent even though its source,
      # its catalogue entry and its parser profile were all correct — every
      # Toplana card is cut at "..." and was therefore parsed from a sentence
      # fragment. Each source names the follower that understands its markup.
      ARTICLE_FOLLOWERS = {
        "water_service" => CityServiceArticleFetcher,
        "heating_service" => CityServiceHeatingArticles,
        "city_official_notices" => CityServiceArticleFetcher,
        "bulky_waste" => CityServiceArticleFetcher
      }.freeze

      CADENCES = {
        "hourly" => -> { CityServiceSources.hourly_sources },
        "four_hourly" => -> { CityServiceSources.four_hourly_sources },
        "daily" => -> { CityServiceSources.daily_sources },
        "weekly" => -> { CityServiceSources.weekly_sources },
        "all" => -> { CityServiceSources.all }
      }.freeze

      Result = Struct.new(
        :source_key,
        :cadence,
        :status,
        :http_status,
        :collected_count,
        :created,
        :updated,
        :unchanged,
        :parser,
        :checked_at,
        :error_code,
        :detail,
        :retry_at,
        :attempts,
        keyword_init: true
      ) do
        def healthy? = %w(ok empty unreviewed).include?(status) && error_code.nil?

        # A site refusing the collector is reported through source health, once;
        # it is not a failure of the scheduled job that respected the refusal.
        def fails_run? = !healthy? && status != "blocked"
      end

      def initialize(organization:, fetcher: nil, now: Time.current, source_store: nil, article_fetcher: nil)
        @organization = organization
        @fetcher = fetcher || method(:fetch_source)
        @prepare_network = fetcher.nil? && article_fetcher.nil?
        @now = now
        @source_store = source_store || CityServiceSourceCheckStore.new
        @article_fetcher = article_fetcher
      end

      def call(cadence: "daily", keys: [])
        selected_sources(cadence:, keys:).map do |source|
          scrape_source(source, cadence: cadence.to_s)
        end
      end

      def self.format(results)
        header = %w(source cadence status http_status parser checked_at error_code collected created updated unchanged detail)
        rows = Array(results).map do |result|
          [
            result.source_key,
            result.cadence,
            result.status,
            result.http_status,
            result.parser,
            result.checked_at&.iso8601,
            result.error_code,
            result.collected_count,
            result.created,
            result.updated,
            result.unchanged,
            sanitize(result.detail)
          ]
        end
        ([header] + rows).map { |values| values.join("\t") }.join("\n")
      end

      def self.sanitize(value)
        value.to_s.split.join(" ")[0, 500]
      end

      private

      attr_reader :organization, :fetcher, :now, :source_store, :article_fetcher

      def selected_sources(cadence:, keys:)
        selected_keys = Array(keys).map(&:to_s).compact_blank
        if selected_keys.any?
          disabled = selected_keys.reject { |key| CityServiceSources.enabled?(key) }
          raise ArgumentError, "disabled city-service source: #{disabled.join(", ")}" if disabled.any?

          return selected_keys.map { |key| CityServiceSources.fetch(key) }
        end

        selector = CADENCES.fetch(cadence.to_s) do
          raise ArgumentError, "unknown city-service scrape cadence: #{cadence}"
        end
        sources = selector.call
        # Muted sources are not fetched until muted_until; "all" and explicit
        # keys still reach them so an operator can probe a fix.
        cadence.to_s == "all" ? sources : sources.reject { |source| CityServiceSources.muted?(source, now) }
      end

      def scrape_source(source, cadence:)
        source_store.with_refresh_lock(source.fetch(:key)) do
          @deadline = SourceRefreshBudget.new(timeout: 120)
          @attempts = 0
          @article_diagnostics = nil
          @transport_diagnostics = nil
          @weather_region = nil
          if source.fetch(:key) == "weather_warnings"
            @weather_region = WeatherRegionConfiguration.for_source(source_url: source.fetch(:source_url), day: now.in_time_zone("Europe/Sarajevo").to_date)
            WeatherRegionConfiguration.assert_current!(@weather_region, source_url: source.fetch(:source_url),
              day: now.in_time_zone("Europe/Sarajevo").to_date, organization_host: organization.host)
          end
          response = fetch_response(source)
          if @weather_region
            WeatherRegionConfiguration.assert_current!(@weather_region, source_url: source.fetch(:source_url),
              day: Time.current.in_time_zone("Europe/Sarajevo").to_date, organization_host: organization.host)
          end
          unless successful_response?(response)
            record_failure(source, :http_error, http_status: response[:http_status])
            next non_success_result(source, cadence:, response:)
          end

          if CityServiceEventIngestor.parser_registered?(source.fetch(:key))
            ingest_parsed_source(source, cadence:, response:)
          else
            collect_unparsed_source(source, cadence:, response:)
          end
        end || Result.new(source_key: source.fetch(:key), cadence:, status: "busy", parser: parser_label(source),
                          collected_count: 0, created: 0, updated: 0, unchanged: 0, detail: "source_refresh_in_progress")
      rescue StandardError => e
        record_failure(source, failure_code(e), retry_at: (e.retry_at if e.respond_to?(:retry_at)))
        failure_result(source, cadence:, error: e)
      end

      def record_failure(source, code, **diagnostics)
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: source.fetch(:key), status: :unavailable,
                                                                  notices: [], checked_at: nil, error_code: code)
        source_store.record(check:, source:, attempted_at: now, diagnostics: diagnostics.merge(attempts: @attempts))
      rescue StandardError => e
        Rails.logger.warn("[CityServiceSourceScrape] health recording failed error_class=#{e.class.name}")
        nil
      end

      def fetch_response(source)
        options = {
          source:, timeout: CityServiceNoticeCollector::DEFAULT_TIMEOUT,
          max_bytes: source.fetch(:max_bytes, CityServiceNoticeCollector::DEFAULT_MAX_BYTES),
          user_agent: CityServiceNoticeCollector::DEFAULT_USER_AGENT
        }
        options[:deadline] = @deadline if fetcher.parameters.any? { |kind, name| kind == :keyrest || ([:key, :keyreq].include?(kind) && name == :deadline) }
        begin
          @attempts += 1
          response = CityServiceNoticeCollector.send(:within_deadline, @deadline) { fetcher.call(**options) }
          # Parsers receive valid UTF-8 or untouched bytes, as on the
          # collection-only path; a provider truncating a Cyrillic excerpt
          # mid-character must not fail the whole source.
          body = CityServiceNoticeCollector::SourceText.normalize(response[:body].to_s, content_type: response[:content_type].to_s,
                                                                                        charset: response[:charset])
          response.merge(body:)
        rescue CitySourceRequestPolicy::PolicyError => e
          # Only pacing contention is retried here. Robots refusal and provider
          # backoff retain their policy and are reported for the next run.
          wait = e.retry_at ? [e.retry_at - Time.current, 0].max : CitySourceRequestPolicy::MIN_INTERVAL
          if pacing_retry?(e, wait)
            sleep(wait)
            retry
          end
          raise
        end
      end

      def pacing_retry?(error, wait)
        error.code == :source_host_busy && @attempts < 3 && wait >= 0 && wait < @deadline.remaining_seconds
      end

      def successful_response?(response)
        response.fetch(:http_status, 0).to_i.between?(200, 299)
      end

      def non_success_result(source, cadence:, response:)
        Result.new(
          source_key: source.fetch(:key),
          cadence:,
          status: "fail",
          http_status: response.fetch(:http_status, nil),
          parser: parser_label(source),
          checked_at: nil,
          error_code: "http_error",
          collected_count: 0,
          created: 0,
          updated: 0,
          unchanged: 0,
          detail: "source returned HTTP #{response.fetch(:http_status, "unknown")}"
        )
      end

      def ingest_parsed_source(source, cadence:, response:)
        ingestor = CityServiceEventIngestor.new(organization:)
        if source.fetch(:key) == "city_official_notices"
          PublicCallsPreparation.new(organization:, source_store:).call(
            html: response.fetch(:body), source_url: response.fetch(:final_url, source.fetch(:source_url)),
            fetched_at: now, deadline: @deadline
          )
        end
        result, complete = parsed_batch(source, response:, ingestor:)
        area_preparation.call(events: result.events, geocode: @prepare_network, deadline: @deadline)
        notices = result.events.first(CityServiceSourceCheckStore::MAX_ITEMS).map do |event|
          CityServiceNoticeCollector::Notice.new(source_key: event.source_key, source_label: event.source_label,
                                                 provider: event.provider, title: event.title, body: event.summary,
                                                 url: event.source_url, fingerprint: event.source_fingerprint, fetched_at: now, metadata: event.extraction_metadata)
        end
        check_status = parsed_check_status(complete, notices)
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: source.fetch(:key), status: check_status,
                                                                  notices:, checked_at: now,
                                                                  error_code: complete ? nil : :partial_source_coverage)
        check = typed_source_check(source, response:, fallback: check)
        complete &&= check.error_code.nil?
        recorded = source_store.record(check:, source:, response:, attempted_at: now, diagnostics: { attempts: @attempts, articles: @article_diagnostics })
        complete &&= recorded && recorded.error_code.nil? if source.fetch(:key) == "weather_warnings"
        CityServiceAiAssessment.new(organization:).call(events: result.events, deadline: @deadline) if complete && source.fetch(:key) == "city_official_notices"
        CityServiceAutomation.new(organization:).call(events: result.events) if complete
        # Notices held longer than an hour go to the boards they could be placed in.
        CityServiceHeldFallback.new(organization:, now:).call
        # After automation, so the bell only counts what is still left for a person.
        CityServiceReviewNudge.new(organization:, now:).call(events: result.events)
        Result.new(source_key: source.fetch(:key), cadence:, status: parsed_status(result, complete:),
                   http_status: response.fetch(:http_status), parser: parser_label(source), checked_at: now,
                   error_code: complete ? nil : "partial_source_coverage", collected_count: result.events.size,
                   created: result.created, updated: result.updated, unchanged: result.unchanged,
                   detail: "pending_review_events=#{result.events.size}")
      end

      def parsed_check_status(complete, notices)
        return :unreviewed unless complete

        notices.empty? ? :empty : :ok
      end

      # Preserve richer answer evidence when a source also produces board notices.
      def typed_source_check(source, response:, fallback:) # rubocop:disable Metrics/CyclomaticComplexity
        return fallback unless %w(road_conditions civil_protection bulky_waste weather_warnings).include?(source.fetch(:key))
        # A complete Komunalac listing with no current matching article is
        # verified empty; its excerpt-only typed reader cannot establish that.
        return fallback if source.fetch(:key) == "bulky_waste" && fallback.status == :empty && fallback.error_code.nil?

        typed = CityServiceNoticeCollector.check(keys: [source.fetch(:key)], fetcher: ->(**_args) { response },
                                                 now:, max_items: CityServiceSourceCheckStore::MAX_ITEMS, deadline: @deadline, **weather_collection_options(source)).first
        if fallback.error_code.nil? && typed.error_code.nil?
          return CityServiceNoticeCollector::SourceCheckResult.new(**typed.to_h,
            status: complete_typed_status(typed, fallback), notices: typed.notices.presence || fallback.notices,
            weather_region_review_id: typed.weather_region_review_id)
        end
        return typed if fallback.error_code.nil? || typed.error_code

        # Rich answer evidence cannot turn an incomplete event extraction into
        # a healthy source snapshot. Keep typed notices and their provenance.
        CityServiceNoticeCollector::SourceCheckResult.new(**typed.to_h, status: :unreviewed, error_code: fallback.error_code,
          weather_region_review_id: typed.weather_region_review_id)
      end

      # Board events and answer evidence have separate thresholds: a yellow
      # weather warning is a typed notice but never a board event. When only the
      # typed reader found notices, they keep the status it gave them; an empty
      # check cannot carry notices (2026-10-20 hourly weather failure).
      def complete_typed_status(typed, fallback)
        fallback.status == :empty && typed.notices.any? ? typed.status : fallback.status
      end

      def weather_collection_options(source)
        source.fetch(:key) == "weather_warnings" ? { weather_region: @weather_region } : {}
      end

      def area_preparation
        @area_preparation ||= CityServiceAreaPreparation.new(organization:)
      end

      def parsed_status(result, complete:)
        return "partial" unless complete

        result.events.empty? ? "empty" : "ok"
      end

      def parsed_batch(source, response:, ingestor:)
        complete = true
        if ARTICLE_FOLLOWERS.has_key?(source.fetch(:key))
          result, complete = article_batch(source, response:, ingestor:)
        else
          complete = ElectricityOutageParser.new(organization:, source:).complete_snapshot?(html: response.fetch(:body)) if source.fetch(:key) == "electricity_outages"
          if CityServiceOfficialPostParser::SOURCE_KEYS.include?(source.fetch(:key))
            complete = CityServiceOfficialPostParser.new(organization:, source:).complete_snapshot?(html: response.fetch(:body))
          end
          result = ingestor.ingest(source_key: source.fetch(:key), html: response.fetch(:body),
                                   source_url: response.fetch(:final_url, source.fetch(:source_url)), fetched_at: now,
                                   **(source.fetch(:key) == "weather_warnings" ? { weather_region: @weather_region } : {}))
          complete &&= result.complete?
        end
        [result, complete]
      end

      def article_batch(source, response:, ingestor:)
        loader = article_fetcher || ARTICLE_FOLLOWERS.fetch(source.fetch(:key)).new(source:)
        articles = loader.call(html: response.fetch(:body), source_url: response.fetch(:final_url, source.fetch(:source_url)),
                               fetched_at: now, deadline: @deadline)
        @article_diagnostics = { "status" => articles.status.to_s, "error_code" => articles.error_code&.to_s,
                                 "failures" => (articles.respond_to?(:failures) ? articles.failures : []),
                                 "returned_articles" => articles.articles.size }
        batches = articles.articles.select(&:complete).map { |article| ingestor.ingest_article(source:, article:, fetched_at: now) }
        complete = articles.status == :ok && batches.all?(&:complete?)
        [aggregate_ingestions(batches, complete:), complete]
      end

      def aggregate_ingestions(batches, complete:)
        CityServiceEventIngestor::Result.new(created: batches.sum(&:created), updated: batches.sum(&:updated),
                                             unchanged: batches.sum(&:unchanged), events: batches.flat_map(&:events), complete:)
      end

      def collect_unparsed_source(source, cadence:, response:)
        check = CityServiceNoticeCollector.check(
          keys: [source.fetch(:key)],
          fetcher: ->(**_args) { response },
          now:,
          max_items: CityServiceSourceCheckStore::MAX_ITEMS,
          deadline: @deadline
        ).first
        check = prepare_transport_check(source, check)
        notices = check.notices
        source_store.record(check:, source:, response:, attempted_at: now,
                            diagnostics: { attempts: @attempts, articles: @article_diagnostics, transport: @transport_diagnostics })

        Result.new(
          source_key: source.fetch(:key),
          cadence:,
          status: check.error_code == :partial_timetable_preparation ? "unreviewed" : check.status.to_s,
          http_status: response.fetch(:http_status),
          parser: parser_label(source),
          checked_at: check.checked_at,
          error_code: check.error_code&.to_s,
          collected_count: notices.size,
          created: 0,
          updated: 0,
          unchanged: 0,
          detail: collection_only_detail(notices, check:)
        )
      end

      def prepare_transport_check(source, check) # rubocop:disable Metrics/CyclomaticComplexity
        return check unless source.fetch(:key) == "public_transport" && check.status == :ok

        prepared = PublicTransportTimetable.new.prepare(notices: check.notices, deadline: @deadline)
        return check if prepared.all? { |item| item[:status] == :ok }

        failed = prepared.reject { |item| item[:status] == :ok }
        @transport_diagnostics = {
          "failed_count" => failed.size,
          "failures" => failed.first(5).map do |item|
            { "document_id" => Digest::SHA256.hexdigest(item[:source_url].to_s)[0, 12],
              "status" => item[:status].to_s, "error_class" => item[:error_code].to_s.gsub(/[^A-Za-z0-9_:]/, "")[0, 80] }
          end
        }
        successful_urls = prepared.select { |item| item[:status] == :ok }.map { |item| item[:source_url] }
        notices = check.notices.select { |notice| successful_urls.include?(notice.url) }
        transport_preparation_failure(source, notices)
      end

      def transport_preparation_failure(source, notices)
        CityServiceNoticeCollector::SourceCheckResult.new(
          source_key: source.fetch(:key), status: notices.any? ? :ok : :unavailable,
          notices:, checked_at: notices.any? ? now : nil,
          error_code: notices.any? ? :partial_timetable_preparation : :timetable_preparation_failed
        )
      end

      def collection_only_detail(notices, check:)
        if check.error_code
          detail = "source_check=#{check.status} error_code=#{check.error_code}"
          if @transport_diagnostics
            failures = @transport_diagnostics.fetch("failures").map do |item|
              "#{item.fetch("document_id")}:#{item.fetch("status")}:#{item.fetch("error_class")}"
            end
            detail = "#{detail} transport_failures=#{@transport_diagnostics.fetch("failed_count")} sample=#{failures.join(",")}"
          end
          return detail
        end

        titles = Array(notices).first(3).map(&:title).compact_blank
        return "source_check=#{check.status} collection_only_notices=#{notices.size}" if titles.empty?

        "source_check=#{check.status} collection_only_notices=#{notices.size} sample=#{titles.join(" | ")}"
      end

      def failure_result(source, cadence:, error:)
        Result.new(
          source_key: source.fetch(:key),
          cadence:,
          status: failure_status(failure_code(error)),
          retry_at: (error.retry_at if error.respond_to?(:retry_at)), attempts: @attempts,
          http_status: nil,
          parser: parser_label(source),
          checked_at: nil,
          error_code: failure_code(error).to_s,
          collected_count: 0,
          created: 0,
          updated: 0,
          unchanged: 0,
          detail: "#{error.class}: #{safe_error(error)}"
        )
      end

      def failure_code(error)
        return error.code if error.is_a?(CitySourceRequestPolicy::PolicyError)
        return :background_refresh_deadline_exceeded if error.is_a?(CityServiceNoticeCollector::DeadlineExceeded)
        return :source_unreachable if error.is_a?(Errno::ECONNREFUSED) || error.is_a?(Timeout::Error) ||
                                      error.is_a?(CityServiceNoticeCollector::ProviderErrorPage)

        :scrape_error
      end

      def failure_status(code)
        return "blocked" if code == :source_provider_blocked # admin UI: policy_blocked
        return "deferred" if [:source_host_busy, :source_host_backoff].include?(code)
        return "policy_blocked" if [:robots_disallowed, :source_ai_input_disallowed].include?(code)

        "fail"
      end

      def parser_label(source)
        CityServiceEventIngestor.parser_registered?(source.fetch(:key)) ? "deterministic_event_parser" : "collection_only"
      end

      def fetch_source(source:, timeout:, max_bytes:, user_agent:, deadline: nil)
        CityServiceNoticeCollector.send(:fetch_source, source:, timeout:, max_bytes:, user_agent:, deadline:)
      end

      def safe_error(error)
        if defined?(Decidim::Bih::LogRedactor)
          Decidim::Bih::LogRedactor.error_message(error)
        else
          error.message.to_s.split.join(" ")[0, 240]
        end
      end
    end
  end
end
