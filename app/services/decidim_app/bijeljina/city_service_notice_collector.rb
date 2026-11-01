# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "nokogiri"
require "timeout"
require "uri"

require_relative "city_service_sources"
require_relative "city_source_request_policy"
require_relative "city_service_content_filter"
require_relative "city_service_evidence_parser"

module DecidimApp
  module Bijeljina
    # Bounded read-only collection for reviewed service-information sources.
    #
    # It extracts reviewed, read-only notice candidates from official pages.
    # Source-specific adapters keep noisy navigation-heavy pages useful without
    # turning collection-only sources into automatically published alerts.
    module CityServiceNoticeCollector
      DEFAULT_TIMEOUT = 8
      DEFAULT_MAX_BYTES = 262_144
      DEFAULT_MAX_ITEMS = 20
      WATER_LEVEL_PARSER_VERSION = "portal-json-fixed-utc-plus-one-stations-v2"
      DEFAULT_USER_AGENT = CitySourceRequestPolicy::USER_AGENT
      DEFAULT_CONTACT_EMAIL = nil # No upstream-project identity for another operator.
      MAX_REDIRECTS = 3
      CONTENT_LINK_SELECTOR = "article a, .post a, .entry-title a, h1 a, h2 a, h3 a, table a, tbody a"
      NON_CONTENT_SELECTOR = "script, style, nav, header, footer, aside, form"
      REVIEWED_PARSER_SOURCE_KEYS = %w(
        water_levels air_quality air_quality_realtime public_transport
        sistem48_public_archive police_service_information
      ).freeze
      KLIMERKO_BIJELJINA_PATTERN = /
        name:"Bijeljina",country:"Bosna\ i\ Hercegovina",
        value:(?<value>null|-?\d+(?:\.\d+)?),
        aqiIndex:(?<aqi_index>null|\d+),
        location:\{
          latitude:(?<latitude>-?\d+(?:\.\d+)?),
          longitude:(?<longitude>-?\d+(?:\.\d+)?)
        \}
      /x

      Notice = Struct.new(
        :source_key,
        :source_label,
        :provider,
        :title,
        :body,
        :url,
        :fingerprint,
        :fetched_at,
        :metadata,
        keyword_init: true
      )

      # One immutable result per requested source. A successful extraction is
      # not an editorial review, publication decision, or proof that a service
      # is operating normally.
      SourceCheckResult = Struct.new(
        :source_key,
        :status,
        :notices,
        :checked_at,
        :error_code,
        keyword_init: true
      ) do
        STATUSES = [:ok, :empty, :unreviewed, :unavailable, :malformed, :stale].freeze
        SUCCESS_STATUSES = [:ok, :empty, :unreviewed].freeze
        FAILURE_STATUSES = [:unavailable, :malformed, :stale].freeze

        # Optional acquisition provenance deliberately stays outside Struct
        # members/to_h, preserving the established five-field result contract.
        attr_reader :weather_region_review_id

        def initialize(**attributes)
          @weather_region_review_id = attributes.delete(:weather_region_review_id)
          unless @weather_region_review_id.nil? || (@weather_region_review_id.is_a?(String) && /\A[a-f0-9]{64}\z/.match?(@weather_region_review_id))
            raise ArgumentError, "invalid weather acquisition identity"
          end
          @weather_region_review_id = @weather_region_review_id&.dup&.freeze
          attributes[:source_key] = attributes.fetch(:source_key).to_s
          attributes[:status] = attributes.fetch(:status).to_sym
          attributes[:notices] = Array(attributes[:notices]).freeze
          attributes[:error_code] = attributes[:error_code]&.to_sym
          validate_attributes!(attributes)

          super(**attributes)
          freeze
        end

        private

        def validate_attributes!(attributes)
          status = attributes.fetch(:status)
          raise ArgumentError, "unknown source check status: #{status}" unless STATUSES.include?(status)

          validate_checked_at!(status, attributes[:checked_at])
          validate_notices!(status, attributes.fetch(:notices))
        end

        def validate_checked_at!(status, checked_at)
          raise ArgumentError, "successful source check requires checked_at" if SUCCESS_STATUSES.include?(status) && checked_at.nil?
          raise ArgumentError, "successful source check requires a typed checked_at" if SUCCESS_STATUSES.include?(status) && !typed_time?(checked_at)
          raise ArgumentError, "failed source check cannot have checked_at" if FAILURE_STATUSES.include?(status) && checked_at
        end

        def typed_time?(value)
          value.is_a?(Time) ||
            (defined?(ActiveSupport::TimeWithZone) && value.is_a?(ActiveSupport::TimeWithZone))
        end

        def validate_notices!(status, notices)
          raise ArgumentError, "ok source check requires notices" if status == :ok && notices.empty?
          raise ArgumentError, "empty source check cannot have notices" if status == :empty && notices.any?
          raise ArgumentError, "failed source check cannot have notices" if FAILURE_STATUSES.include?(status) && notices.any?
        end
      end
      CheckResult = SourceCheckResult

      class DeadlineExceeded < StandardError; end

      # The provider redirected to its own "error, try later" page (Satwork for
      # road_conditions answers every client with a 302 to /PhpLogin/access-error.php).
      # That is the provider being unavailable, not a layout change.
      class ProviderErrorPage < StandardError; end
      PROVIDER_ERROR_HOST = "v3.satwork.net"
      PROVIDER_ERROR_PATH = %r{/access-error}i

      class InvalidDeadline < ArgumentError; end

      class ParserError < StandardError; end

      class StaleSourceError < ParserError; end

      ERROR_CODE_BY_CLASS = {
        StaleSourceError => :source_feed_stale,
        DeadlineExceeded => :deadline_exceeded,
        ProviderErrorPage => :source_unreachable,
        InvalidDeadline => :invalid_deadline
      }.freeze
      ERROR_CODE_BY_MESSAGE_PREFIX = {
        "source returned an empty body" => :empty_body,
        "source returned an invalid check time" => :invalid_checked_at,
        "source returned HTTP" => :http_error
      }.freeze

      class << self
        def call(keys: [], **)
          check(keys:, **).flat_map(&:notices)
        end

        def check(keys: [], **options)
          options = collection_options(options)

          selected_sources(keys).map do |source|
            check_source(source, options)
          end
        end

        private

        def collection_options(options)
          {
            timeout: options.fetch(:timeout, DEFAULT_TIMEOUT),
            max_bytes: options.fetch(:max_bytes, DEFAULT_MAX_BYTES),
            max_items: options.fetch(:max_items, DEFAULT_MAX_ITEMS),
            user_agent: options.fetch(:user_agent, DEFAULT_USER_AGENT),
            fetcher: options.fetch(:fetcher, nil) || method(:fetch_source),
            now: options.fetch(:now, nil),
            clock: options.fetch(:clock, nil) || -> { Time.current },
            deadline: options.fetch(:deadline, nil),
            weather_region: options.fetch(:weather_region, nil)
          }
        end

        def selected_sources(keys)
          selected = Array(keys).map(&:to_s).compact_blank
          candidates = selected.empty? ? CityServiceSources.all : selected.map { |key| CityServiceSources.fetch(key) }
          candidates.select { |source| source.fetch(:enabled, false) == true }.uniq { |source| source.fetch(:key) }
        end

        def check_source(source, options)
          parsing = false
          deadline = bounded_deadline(options.fetch(:deadline), options.fetch(:timeout))
          timeout = effective_timeout(options.fetch(:timeout), deadline)
          fetch_options = {
            source:,
            timeout:,
            max_bytes: source.fetch(:max_bytes, options.fetch(:max_bytes)),
            user_agent: options.fetch(:user_agent)
          }
          fetch_options[:deadline] = deadline if fetcher_accepts_deadline?(options.fetch(:fetcher))
          weather_region = nil
          if source.fetch(:key) == "weather_warnings"
            day = (options[:now] || options.fetch(:clock).call).in_time_zone("Europe/Sarajevo").to_date
            weather_region = options[:weather_region]
            weather_region = WeatherRegionConfiguration.for_source(source_url: source.fetch(:source_url), day:) if weather_region.nil?
            WeatherRegionConfiguration.assert_current!(weather_region, source_url: source.fetch(:source_url), day:)
          end
          response = within_deadline(deadline, max_seconds: timeout) do
            options.fetch(:fetcher).call(**fetch_options)
          end
          raise "source returned HTTP #{response.fetch(:http_status)}" unless successful_response?(response)

          parsing = true
          content_type = response.fetch(:content_type, "").to_s
          # Parsers receive valid UTF-8 or untouched bytes; see SourceText.
          body = SourceText.normalize(response.fetch(:body).to_s, content_type:, charset: response[:charset])
          raise ArgumentError, "source returned an empty body" if body.b.strip.empty?

          checked_at = checked_at_for(response, options)
          raise ArgumentError, "source returned an invalid check time" unless checked_at

          final_url = response.fetch(:final_url, source.fetch(:source_url)).presence || source.fetch(:source_url)
          evidence_options = weather_region ? { weather_region: } : {}
          evidence = CityServiceEvidenceParser.call(source:, body:, url: final_url, now: checked_at, **evidence_options)
          notices = parsed_notices(source, response: { evidence:, content_type:, body:, final_url: }, options:, checked_at:)
          reviewed = extraction_reviewed?(source, content_type, body, evidence:)
          validate_extraction!(source:, body:, reviewed: reviewed && evidence.nil?, notices:)
          if weather_region
            day = (options[:now] || options.fetch(:clock).call).in_time_zone("Europe/Sarajevo").to_date
            WeatherRegionConfiguration.assert_current!(weather_region, source_url: source.fetch(:source_url), day:)
          end

          SourceCheckResult.new(
            source_key: source.fetch(:key),
            status: check_status(reviewed:, notices:),
            notices:,
            checked_at:,
            error_code: extraction_error(source, notices, evidence:, reviewed:),
            weather_region_review_id: weather_region&.identity
          )
        rescue StandardError => e
          Rails.logger.warn("[CityServiceNoticeCollector] #{source.fetch(:key)} collection failed: #{safe_error(e)}")
          SourceCheckResult.new(
            source_key: source.fetch(:key),
            status: failure_status(e, parsing:),
            notices: [],
            checked_at: nil,
            error_code: error_code_for(e, parsing:)
          )
        end

        def parsed_notices(source, response:, options:, checked_at:)
          notices = if response[:evidence]
                      response[:evidence].map do |attrs|
                        attrs[:fingerprint] = fingerprint_for(source.fetch(:key), attrs.fetch(:title), attrs.fetch(:body))
                        build_notice(source:, attrs:, now: checked_at)
                      end
                    elsif html_content?(response[:content_type], response[:body])
                      html_notices(source, response[:body], response[:final_url], max_items: options.fetch(:max_items), now: checked_at)
                    else
                      fallback_notice(source, response[:final_url], checked_at)
                    end
          notices.first(options.fetch(:max_items))
        end

        def extraction_reviewed?(source, content_type, body, evidence:)
          evidence ? reviewed_evidence?(evidence) : reviewed_parser?(source, content_type, body)
        end

        def reviewed_evidence?(evidence)
          evidence.all? { |item| item[:metadata]["geographic_status"] != "unverified" && item[:metadata]["temporal_status"] != "unknown" }
        end

        def extraction_error(source, notices, evidence:, reviewed:)
          return content_quality_error(source, notices) unless evidence

          :unverified_source_coverage unless reviewed
        end

        def content_quality_error(source, notices)
          "no_relevant_content" if CityServiceContentFilter::SOURCES.include?(source.fetch(:key)) && notices.empty?
        end

        def check_status(reviewed:, notices:)
          return :unreviewed unless reviewed

          notices.empty? ? :empty : :ok
        end

        def validate_extraction!(source:, body:, reviewed:, notices:)
          return unless reviewed && notices.empty?
          return if valid_reviewed_empty_page?(source, body)

          raise ParserError, "reviewed parser did not recognize the source page"
        end

        def effective_timeout(timeout, deadline)
          seconds = remaining_seconds(deadline)
          raise DeadlineExceeded, "source-check deadline expired" if seconds && seconds <= 0

          seconds ? [timeout.to_f, seconds].min : timeout
        end

        def remaining_seconds(deadline)
          return if deadline.nil?

          required = [:deadline, :remaining_seconds, :expired?, :within]
          raise InvalidDeadline, "unsupported deadline object" unless required.all? { |method| deadline.respond_to?(method) }
          return 0.0 if deadline.expired?

          seconds = Float(deadline.remaining_seconds)
          raise InvalidDeadline, "remaining deadline must be finite" unless seconds.finite?

          seconds
        rescue TypeError, ArgumentError => e
          raise e if e.is_a?(InvalidDeadline)

          raise InvalidDeadline, "remaining deadline must be numeric"
        end

        def bounded_deadline(deadline, max_seconds)
          return if deadline.nil?

          remaining_seconds(deadline)
          deadline.within(max_seconds)
        end

        def within_deadline(deadline, max_seconds: nil, &)
          seconds = remaining_seconds(deadline)
          seconds = [seconds, max_seconds.to_f].compact.min if max_seconds
          return yield if seconds.nil?
          raise DeadlineExceeded, "source-check deadline expired" if seconds <= 0

          Timeout.timeout(seconds, DeadlineExceeded, &)
        end

        def fetcher_accepts_deadline?(fetcher)
          fetcher.parameters.any? do |kind, name|
            kind == :keyrest || ([:key, :keyreq].include?(kind) && name == :deadline)
          end
        end

        def checked_at_for(response, options)
          reference = options.fetch(:now) || options.fetch(:clock).call
          value = response[:checked_at] || reference
          time = value.respond_to?(:in_time_zone) ? value : Time.zone.parse(value.to_s)
          return if time.nil? || time > reference

          time
        rescue StandardError
          nil
        end

        def reviewed_parser?(source, content_type, body)
          REVIEWED_PARSER_SOURCE_KEYS.include?(source.fetch(:key)) && html_content?(content_type, body)
        end

        def valid_reviewed_empty_page?(source, body)
          document = Nokogiri::HTML(body)
          case source.fetch(:key)
          when "water_levels"
            document.at_css(".okvircijena").present?
          when "air_quality"
            normalize(document.text).match?(/kvalitet\s+(vazduha|zraka)/i)
          when "public_transport"
            normalize(document.text).match?(/(red\s+vo[zž]nje|javni\s+(gradski\s+)?prevoz)/i)
          when "sistem48_public_archive"
            document.at_css('select[name="tip_zahteva"], select[name="zahtevi_status"]').present?
          when "police_service_information"
            normalize(document.text).match?(/(pu\s+bijeljina|policijsk|e-?usluge)/i)
          else
            false
          end
        end

        def failure_status(error, parsing:)
          return :stale if error.is_a?(StaleSourceError)

          parsing ? :malformed : :unavailable
        end

        def error_code_for(error, parsing:)
          return error.code if error.is_a?(CitySourceRequestPolicy::PolicyError)

          by_class = ERROR_CODE_BY_CLASS.find { |klass, _code| error.is_a?(klass) }
          return by_class.last if by_class

          by_message = ERROR_CODE_BY_MESSAGE_PREFIX.find { |prefix, _code| error.message.to_s.start_with?(prefix) }
          return by_message.last if by_message

          parsing ? :parser_error : :fetch_error
        end

        def fetch_source(source:, timeout:, max_bytes:, user_agent:, deadline: nil)
          fetch_url(source.fetch(:source_url), { timeout:, max_bytes:, user_agent:, deadline:, redirects: 0 })
        end

        def fetch_url(url, options)
          uri = URI.parse(url)
          raise ArgumentError, "unsupported URL scheme" unless %w(http https).include?(uri.scheme)

          timeout = effective_timeout(options.fetch(:timeout), options.fetch(:deadline))
          max_bytes = options.fetch(:max_bytes)
          user_agent = options.fetch(:user_agent)
          deadline = options.fetch(:deadline)
          redirects = options.fetch(:redirects)
          policy = CitySourceRequestPolicy.default
          timeout = policy.before_request(uri, timeout:)
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout) do |http|
            request = Net::HTTP::Get.new(uri)
            request["User-Agent"] = DEFAULT_USER_AGENT
            contact = CitySourceRequestPolicy.contact_email
            request["From"] = contact if contact
            request["Accept"] = "text/html,application/json,application/pdf;q=0.8,*/*;q=0.5"

            http.request(request) do |response|
              policy.observe_response(uri, response)
              return follow_redirect(response, uri, timeout:, max_bytes:, user_agent:, deadline:, redirects:) if response.is_a?(Net::HTTPRedirection)

              body = read_limited_body(response, max_bytes)
              return {
                http_status: response.code.to_i,
                final_url: uri.to_s,
                content_type: response["content-type"].to_s.split(";").first,
                charset: response.type_params["charset"],
                body:
              }
            end
          end
        end

        def follow_redirect(response, uri, **options)
          redirects = options.fetch(:redirects)
          raise "too many redirects" if redirects >= MAX_REDIRECTS

          location = response["location"].to_s
          raise "redirect without location" if location.blank?

          target = URI.join(uri.to_s, location)
          raise ProviderErrorPage, "provider error page" if target.host == PROVIDER_ERROR_HOST && target.path.to_s.match?(PROVIDER_ERROR_PATH)

          redirect_options = {
            timeout: options.fetch(:timeout),
            max_bytes: options.fetch(:max_bytes),
            user_agent: options.fetch(:user_agent),
            deadline: options.fetch(:deadline),
            redirects: redirects + 1
          }
          fetch_url(target.to_s, redirect_options)
        end

        def read_limited_body(response, max_bytes)
          limit = max_bytes.to_i
          return +"" if limit <= 0

          body = +""
          response.read_body do |chunk|
            remaining = limit - body.bytesize
            break if remaining <= 0

            body << chunk.byteslice(0, remaining).to_s
          end
          body
        end

        def html_content?(content_type, body)
          content_type.include?("html") || body.lstrip.start_with?("<")
        end

        def successful_response?(response)
          status = response.fetch(:http_status, 200).to_i
          status.between?(200, 299)
        end

        def html_notices(source, body, final_url, max_items:, now:)
          document = Nokogiri::HTML(body)
          if CityServiceContentFilter::SOURCES.include?(source.fetch(:key))
            document.css("#{NON_CONTENT_SELECTOR}, [class*='cookie'], [id*='cookie'], [class*='consent'], [id*='consent']").remove
            return filtered_candidates(source, document, final_url, max_items:, now:)
          end
          source_specific = source_specific_notices(source, document, final_url, max_items:, now:)
          return source_specific.first(max_items) if reviewed_parser?(source, "text/html", body)

          document.css(NON_CONTENT_SELECTOR).remove
          anchor_notices(source, document, final_url, max_items:, now:).presence ||
            title_notice(source, document, final_url, now:)
        end

        def filtered_candidates(source, document, final_url, max_items:, now:)
          key = source.fetch(:key)
          # Filter before limiting; a page full of vacancies must not hide a
          # relevant warning later in the same document.
          document.css("a").each do |anchor|
            anchor.remove unless CityServiceContentFilter.relevant?(key, normalize(anchor.text), now:)
          end
          notices = anchor_notices(source, document, final_url, max_items:, now:)
          if key == "road_conditions"
            paragraphs = road_paragraphs(source, document, final_url, now:)
            notices = (paragraphs + notices).uniq(&:fingerprint).first(max_items)
          end
          notices.each do |notice|
            notice.metadata = { "content_role" => "review_candidate", "temporal_status" => "unverified",
                                "geographic_status" => "unverified", "filter_version" => "2026-09-13.1" }
          end
          notices
        end

        def road_paragraphs(source, document, final_url, now:)
          key = source.fetch(:key)
          document.css("article p, .entry-content p").filter_map do |node|
            text = normalize(node.text)
            next unless text.length >= 40 && CityServiceContentFilter.relevant?(key, text, now:)
            next unless Decidim::Bih::Text.fold(text).match?(/\b(?:bijeljin\w*|janj[aeiu]|raca|sremska raca)\b/)

            build_notice(source:, attrs: { title: text[0, 220], body: text, url: final_url,
                                           fingerprint: fingerprint_for(key, text, final_url) }, now:)
          end
        end

        def source_specific_notices(source, document, final_url, max_items:, now:)
          case source.fetch(:key)
          when "water_levels"
            water_level_notices(source, document, final_url, now:)
          when "air_quality"
            air_quality_notices(source, document, final_url, max_items:, now:)
          when "air_quality_realtime"
            realtime_air_quality_notices(source, document, final_url, now:)
          when "public_transport"
            public_transport_notices(source, document, final_url, max_items:, now:)
          when "sistem48_public_archive"
            sistem48_archive_notices(source, document, final_url, now:)
          when "police_service_information"
            police_service_notices(source, document, final_url, max_items:, now:)
          else
            []
          end
        end

        def water_level_notices(source, document, final_url, now:)
          readings = if (data = document.at_css("#portal-water-levels-data"))
                       portal_water_level_readings(data.text)
                     elsif document.at_css(".portal-water-level-card")
                       document.css(".portal-water-level-card").filter_map { |node| portal_water_level_card(node) }
                     else
                       document.css(".okvircijena").filter_map { |node| water_level_reading(node) }
                     end
          return [] if readings.empty?

          title = "Vodostaji: #{readings.map { |reading| water_level_title_part(reading) }.join("; ")}"
          body = readings.map { |reading| water_level_body_part(reading) }.join(" | ")

          [
            build_notice(
              source:,
              attrs: {
                title:,
                body:,
                url: final_url,
                metadata: { "kind" => "water_level_observation", "authority" => "secondary_aggregator",
                            "readings" => readings.first(20).map { |reading| water_level_metadata(reading) } },
                fingerprint: fingerprint_for(source.fetch(:key), title, body)
              },
              now:
            )
          ]
        end

        def water_level_metadata(reading)
          metadata = {
            "station" => reading.fetch(:station), "value" => reading.fetch(:level).tr(",", ".").to_f,
            "unit" => "cm", "observation_time_text" => reading[:timestamp],
            "datum" => "station_gauge_zero", "vertical_datum" => "unknown",
            "quality_flags" => ["unknown_station_and_clock"],
            "regular_defense_cm" => reading[:regular_defense_cm]
          }
          return metadata.compact unless reading[:station_id]

          metadata.merge(
            "station_id" => reading[:station_id], "source_clock" => "UTC+1", "upstream_authority" => "RHMZ Serbia",
            "clock_evidence_url" => reading[:source_url] || "https://www.hidmet.gov.rs/latin/osmotreni/nrt_index.php",
            "observed_at" => source_measurement_time(reading[:timestamp], source_clock: "UTC+1"), "quality_flags" => []
          ).compact
        end

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- pre-existing validation of the provider's station payload
        def portal_water_level_readings(body)
          stations = JSON.parse(body).fetch("stations")
          raise ParserError, "water-level stations missing" unless stations.is_a?(Array) && stations.any?

          readings = stations.filter_map do |station|
            name = station.fetch("title")
            id = water_level_station_id(name)
            next unless id

            latest = station["latest"]
            raise ParserError, "water-level latest observation missing" unless latest.is_a?(Hash) &&
                                                                               latest["value"].is_a?(Numeric) && latest["measured_at"].present?

            timestamp = latest.fetch("measured_at")
            raise ParserError, "invalid water-level observation" unless source_measurement_time(timestamp, source_clock: "UTC+1") && station["unit"] == "cm"

            changes = station.fetch("changes", {}).filter_map { |period, change| "#{change}cm/#{period}" if change.is_a?(Numeric) }
            defense = station.dig("regular_defense", "from")
            { station: name, station_id: id, level: latest.fetch("value").to_s,
              timestamp:, changes:, defense_level: ("Kota redovne odbrane od poplava: #{defense}cm" if defense.is_a?(Numeric)),
              regular_defense_cm: defense,
              source_url: station["source_url"] }
          end
          raise ParserError, "water-level latest observations missing" if readings.empty?

          readings
        rescue JSON::ParserError, KeyError, TypeError => e
          raise ParserError, "invalid water-level data: #{e.class.name}"
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def portal_water_level_card(node)
          station = normalize(node.at_css("h2")&.text)
          level = normalize(node.at_css(".portal-water-level-current strong")&.text)[/([-+]?\d+(?:[,.]\d+)?)\s*cm/i, 1]
          timestamp = normalize(node.at_css(".portal-water-level-time")&.text)[/(\d{1,2}\.\d{1,2}\.20\d{2}\.\s+\d{1,2}:\d{2})/, 1]
          return unless water_level_station_id(station) && level && timestamp

          { station:, station_id: water_level_station_id(station), level:, timestamp:, changes: [],
            defense_level: normalize(node.at_css(".portal-water-level-threshold")&.text).presence }
        end

        def water_level_reading(node)
          station = normalize(node.at_css(".nazivartikla")&.text)
          level_text = normalize(node.at_css(".cijenaKM")&.text)
          level = level_text[/Vodostaj:\s*([-+]?\d+(?:[,.]\d+)?)\s*cm/i, 1]
          return if station.blank? || level.blank?

          full_text = normalize(node.text)
          {
            station:,
            station_id: water_level_station_id(station),
            level:,
            timestamp: full_text[/Poslednji podatak:\s*(.*?)(?=Rijeka|\z)/i, 1].to_s.strip.presence,
            changes: node.css(".vodkorekcija .malivodostaj").map { |change| normalize(change.text) }.compact_blank,
            defense_level: normalize(node.at_css(".dodatnipodatak")&.text).presence
          }
        end

        # Reviewed provider identities, never inferred from river name alone.
        def water_level_station_id(station)
          case station
          when /\ARijeka Drina \(Radalj\)\z/i, /\ARadalj\z/i then "RS45882"
          when /\ARijeka Sava \(Jamena\)\z/i, /\AJamena\z/i then "RS45084"
          end
        end

        # Only a complete source date/time is a measurement timestamp. Relative
        # labels and year-less sensor labels remain unknown across refreshes.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- pre-existing branching over the provider's date spellings
        def source_measurement_time(value, source_clock: "Europe/Sarajevo")
          if source_clock == "UTC+1" && (iso = value.to_s.match(/\A(20\d{2})-(\d{2})-(\d{2}) (\d{2}):(\d{2})(?::\d{2})?\z/))
            return Time.new(*iso.captures.map(&:to_i), 0, "+01:00").iso8601
          end

          match = value.to_s.match(/(?<day>\d{1,2})\.(?<month>\d{1,2})\.(?<year>20\d{2})\.?\s+(?<hour>\d{1,2}):(?<minute>\d{2})/)
          return unless match

          date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
          return unless match[:hour].to_i < 24 && match[:minute].to_i < 60

          # RHMZ Serbia publishes fixed UTC+1 throughout the year. This is
          # deliberately opt-in: the community air sensor keeps its civil clock.
          return Time.new(date.year, date.month, date.day, match[:hour].to_i, match[:minute].to_i, 0, "+01:00").iso8601 if source_clock == "UTC+1"
          return unless source_clock == "Europe/Sarajevo"

          civil_time = Time.utc(date.year, date.month, date.day, match[:hour].to_i, match[:minute].to_i)
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          # A civil reading without an offset cannot disambiguate the repeated
          # autumn hour; a spring gap is not a real observation time either.
          return unless zone.tzinfo.periods_for_local(civil_time).one?

          zone.local(date.year, date.month, date.day, match[:hour].to_i, match[:minute].to_i).iso8601
        rescue ArgumentError
          nil
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def water_level_title_part(reading)
          "#{reading.fetch(:station).sub(/\ARijeka\s+/i, "")} #{reading.fetch(:level)}cm"
        end

        def water_level_body_part(reading)
          parts = []
          parts << "Poslednji podatak: #{reading.fetch(:timestamp)}" if reading.fetch(:timestamp).present?
          parts << "#{reading.fetch(:station)}: #{reading.fetch(:level)}cm"
          parts << "promjena #{reading.fetch(:changes).join(", ")}" if reading.fetch(:changes).present?
          parts << reading.fetch(:defense_level) if reading.fetch(:defense_level).present?
          parts.join("; ")
        end

        def air_quality_notices(source, document, final_url, max_items:, now:)
          article_pdf_notices(
            source,
            document,
            final_url,
            {
              max_items:,
              now:,
              title_prefix: "Kvalitet vazduha",
              body_prefix: "PDF izvještaj o kvalitetu vazduha za Bijeljinu",
              link_filter: ->(title, href) { air_quality_document_link?(title, href) }
            }
          ).presence || article_summary_notice(source, document, final_url, "Kvalitet vazduha", now)
        end

        def realtime_air_quality_notices(source, document, final_url, now:)
          measurement = klimerko_bijeljina_measurement(document.to_html)
          return [] unless measurement

          pollutant = pollutant_label(final_url)
          value = measurement.fetch(:value)
          return [] unless %w(PM1 PM2.5 PM10).include?(pollutant)
          return [] unless valid_air_measurement_value?(value)

          value_text = value.nil? ? "nema mjerenja" : "#{value} µg/m³"
          aqi_label = klimerko_aqi_label(measurement.fetch(:aqi_index))
          title = "Kvalitet vazduha uživo: Bijeljina #{pollutant} #{value_text}"
          title = "#{title} (#{aqi_label})" if aqi_label.present?
          updated_at = normalize(document.at_css(".updated-at")&.text).presence
          body = [
            "Klimerko #{pollutant} za Bijeljinu: #{value_text}",
            ("kategorija: #{aqi_label}" if aqi_label.present?),
            updated_at.presence,
            "koordinate: #{measurement.fetch(:latitude)}, #{measurement.fetch(:longitude)}"
          ].compact.join("; ")

          [
            build_notice(
              source:,
              attrs: {
                title:,
                body:,
                url: final_url,
                metadata: { "kind" => "air_quality_observation", "authority" => "community_sensor",
                            "pollutant" => pollutant, "value" => value, "unit" => "µg/m³",
                            "scope" => "community_city_marker", "station" => "Bijeljina (Klimerko javni prikaz)",
                            "latitude" => measurement.fetch(:latitude).to_f, "longitude" => measurement.fetch(:longitude).to_f,
                            "observation_time_text" => updated_at, "observed_at" => source_measurement_time(updated_at) }.compact,
                fingerprint: fingerprint_for(source.fetch(:key), title, updated_at.presence || body)
              },
              now:
            )
          ]
        end

        def valid_air_measurement_value?(value)
          value.nil? || (value.finite? && !value.negative?)
        end

        def klimerko_bijeljina_measurement(html)
          match = html.match(KLIMERKO_BIJELJINA_PATTERN)
          return unless match

          {
            value: number_or_nil(match[:value]),
            aqi_index: integer_or_nil(match[:aqi_index]),
            latitude: match[:latitude],
            longitude: match[:longitude]
          }
        end

        def number_or_nil(value)
          return nil if value.to_s == "null"

          numeric = value.to_f
          numeric == numeric.to_i ? numeric.to_i : numeric
        end

        def integer_or_nil(value)
          return nil if value.to_s == "null"

          value.to_i
        end

        def pollutant_label(final_url)
          query = Rack::Utils.parse_nested_query(URI.parse(final_url).query.to_s)
          case query["pollutant"].to_s
          when "pm10"
            "PM10"
          when "pm1"
            "PM1"
          when "temperature"
            "temperatura"
          when "humidity"
            "vlažnost"
          when "pressure"
            "pritisak"
          else
            "PM2.5"
          end
        rescue URI::InvalidURIError
          "PM2.5"
        end

        def klimerko_aqi_label(index)
          return unless index

          [
            "odlično",
            "dobro",
            "prihvatljivo",
            "zagađeno",
            "jako zagađeno",
            "ekstremno zagađeno"
          ][index.to_i]
        end

        def public_transport_notices(source, document, final_url, max_items:, now:)
          reviewed = ReviewedTransportTimetables.manifest
          if reviewed.fetch("routes").any? &&
             (final_url.to_s == reviewed["source_url"].to_s || ReviewedTransportTimetables.gallery_document?(document))
            return ReviewedTransportTimetables.gallery_entries(document).first(max_items).map do |entry|
              url = entry.dig("timetable", "url")
              build_notice(source:, attrs: {
                             title: "Javni prevoz: #{entry.fetch("title")}",
                             body: "Pregledani red vožnje od #{reviewed.fetch("effective_from")}. Mapa: #{entry.dig("map", "url")}",
                             url:, fingerprint: fingerprint_for(source.fetch(:key), entry.fetch("title"), url)
                           }, now:)
            end
          end

          article_pdf_notices(
            source,
            document,
            final_url,
            {
              max_items:,
              now:,
              title_prefix: "Javni prevoz",
              body_prefix: "Red vožnje, linija ili informacija o stajalištima",
              link_filter: ->(title, href) { public_transport_document_link?(title, href) }
            }
          )
        end

        def article_pdf_notices(source, document, final_url, options)
          title_prefix = options.fetch(:title_prefix)
          body_prefix = options.fetch(:body_prefix)
          link_filter = options.fetch(:link_filter)
          scope = article_scope(document)
          seen_urls = Set.new
          scope.css("a[href]").filter_map do |anchor|
            href = anchor["href"].to_s
            title = normalize(anchor.text).presence || title_from_url(href)
            next if title.blank? || !href.match?(/\.pdf(?:[?#]|\z)/i)
            next unless link_filter.call(title, href)

            url = absolute_url(final_url, href)
            next if seen_urls.include?(url)

            seen_urls << url
            notice_title = "#{title_prefix}: #{title}"
            build_notice(
              source:,
              attrs: {
                title: notice_title,
                body: [body_prefix, article_heading(document), title].compact_blank.join(" - "),
                url:,
                fingerprint: fingerprint_for(source.fetch(:key), notice_title, url)
              },
              now: options.fetch(:now)
            )
          end.first(options.fetch(:max_items))
        end

        def air_quality_document_link?(_title, href)
          href.match?(%r{/Dokumenti/bn[-\d.]+.*\.pdf}i) || href.match?(/kvalitet|vazduh/i)
        end

        def public_transport_document_link?(title, href)
          [title, href].join(" ").match?(/\b[GP]\d+\b|red\s*vožnje|red\s*voznje|stajali|linij|prevoz|mapa/i)
        end

        def article_summary_notice(source, document, final_url, title_prefix, now)
          heading = article_heading(document).presence || normalize(document.at_css("title")&.text).presence || source.fetch(:label)
          body = normalize(article_scope(document).text)[0, 900]

          [
            build_notice(
              source:,
              attrs: {
                title: "#{title_prefix}: #{heading}",
                body: body.presence || heading,
                url: final_url,
                fingerprint: fingerprint_for(source.fetch(:key), heading, final_url)
              },
              now:
            )
          ]
        end

        def sistem48_archive_notices(source, document, final_url, now:)
          categories = select_options(document, "tip_zahteva")
          statuses = select_options(document, "zahtevi_status")
          periods = select_options(document, "datum")
          return [] if categories.empty? && statuses.empty? && periods.empty?

          status_counts = sistem48_status_counts(document)
          title = "Sistem 48 javni pregled: #{categories.size} vrsta problema"
          body = [
            "Filtri po vrstama problema: #{listed_values(categories)}",
            sistem48_entries_sentence(status_counts),
            "statusi: #{listed_values(statuses)}",
            "periodi: #{listed_values(periods)}",
            "Sadržaj je namijenjen agregatnom pregledu; sirovi tekst građanskih prijava se ne preuzima za obavještenja."
          ].compact_blank.join(". ")

          [
            build_notice(
              source:,
              attrs: {
                title:,
                body:,
                url: final_url,
                metadata: { "kind" => "public_archive_summary", "entries" => status_counts.values.sum, "status_counts" => status_counts },
                fingerprint: fingerprint_for(source.fetch(:key), title, body)
              },
              now:
            )
          ]
        end

        # Aggregate only: how many public reports the page lists per status
        # label. Report texts never leave the page (see the source's area_mapping).
        def sistem48_status_counts(document)
          document.css("div.list-group a.list-group-item.active p.pull-right").map { |node| normalize(node.text) }.compact_blank.tally
        end

        def sistem48_entries_sentence(status_counts)
          return if status_counts.empty?

          labels = status_counts.map { |label, count| "#{label} #{count}" }.join(", ")
          "javno prikazanih prijava na stranici: #{status_counts.values.sum} (#{labels})"
        end

        def police_service_notices(source, document, final_url, max_items:, now:)
          notices = []
          contact = police_contact_notice(source, document, final_url, now:)
          notices << contact if contact
          notices.concat(police_link_notices(source, document, final_url, max_items: max_items - notices.size, now:)) if notices.size < max_items
          notices
        end

        def police_contact_notice(source, document, final_url, now:)
          rows = police_contact_rows(document)
          return if rows.empty?

          title = "PU Bijeljina: policijske stanice i kontakti"
          body = "Kontakti sa zvanične stranice PU Bijeljina: #{rows.join(" | ")}"
          build_notice(
            source:,
            attrs: {
              title:,
              body:,
              url: final_url,
              fingerprint: fingerprint_for(source.fetch(:key), title, body)
            },
            now:
          )
        end

        def police_contact_rows(document)
          document.css("table tr").drop(1).filter_map do |row|
            cells = row.css("td").map { |cell| normalize(cell.text) }
            next if cells.size < 4

            name, address, city, phone = cells
            next unless [name, city].join(" ").match?(/BIJELJINA|BIJELjINA|JANjA|JANJA/i)

            [name, address, city, "tel. #{phone}"].compact_blank.join(", ")
          end
        end

        def police_link_notices(source, document, final_url, max_items:, now:)
          seen_urls = Set.new
          document.css("a[href]").filter_map do |anchor|
            title = normalize(anchor.text)
            href = anchor["href"].to_s
            next if title.blank? || !police_service_link?(title, href)

            url = absolute_url(final_url, href)
            next if seen_urls.include?(url)

            seen_urls << url
            notice_title = "MUP RS servis: #{title}"
            build_notice(
              source:,
              attrs: {
                title: notice_title,
                body: "Zvanični MUP RS servis ili javna informacija dostupna preko stranice PU Bijeljina.",
                url:,
                fingerprint: fingerprint_for(source.fetch(:key), notice_title, url)
              },
              now:
            )
          end.first(max_items)
        end

        def police_service_link?(title, href)
          return false if title.match?(/B\.?\s*Luka|Banja Luka/i)
          return true if href.match?(%r{/informisanje-javnosti/(najave|servisne-informacije)}i)
          return true if href.match?(%r{/mup-servisi/(stars|provjera-dokumenata|pohvala|zalba|prijava)}i)
          return true if href.match?(%r{\Ahttps://e-servisi-mup\.vladars\.rs/?}i)

          title.match?(/eUsluge|Prekršaj|radar|Provjera nevažećih dokumenata|Pohvale|Žalbe|Anonimna prijava|Prijavite krivično/i)
        end

        def anchor_notices(source, document, final_url, max_items:, now:)
          seen_fingerprints = Set.new
          seen_urls = Set.new
          anchors = document.css(CONTENT_LINK_SELECTOR)
          anchors = document.css("a") if anchors.empty?

          anchors.filter_map do |anchor|
            title = normalize(anchor.text)
            next if title.length < 12

            url = absolute_url(final_url, anchor["href"])
            next if non_content_url?(url)
            next if seen_urls.include?(url)

            fingerprint = fingerprint_for(source.fetch(:key), title, url)
            next if seen_fingerprints.include?(fingerprint)

            seen_urls << url
            seen_fingerprints << fingerprint
            build_notice(
              source:,
              attrs: {
                title:,
                body: normalize(anchor.parent&.text).presence || title,
                url:,
                fingerprint:
              },
              now:
            )
          end.first(max_items)
        end

        def title_notice(source, document, final_url, now:)
          title = normalize(document.at_css("title")&.text).presence || source.fetch(:label)
          body = normalize(document.css("body").text)[0, 900]

          [
            build_notice(
              source:,
              attrs: {
                title:,
                body: body.presence || title,
                url: final_url,
                fingerprint: fingerprint_for(source.fetch(:key), title, final_url)
              },
              now:
            )
          ]
        end

        def fallback_notice(source, final_url, now)
          [
            build_notice(
              source:,
              attrs: {
                title: source.fetch(:label),
                body: "Source document requires a source-specific parser before automatic publication.",
                url: final_url,
                fingerprint: fingerprint_for(source.fetch(:key), source.fetch(:label), final_url)
              },
              now:
            )
          ]
        end

        def build_notice(source:, attrs:, now:)
          Notice.new(
            source_key: source.fetch(:key),
            source_label: source.fetch(:label),
            provider: source.fetch(:provider),
            title: truncate(attrs.fetch(:title), 220),
            body: truncate(attrs.fetch(:body), 1_500),
            url: attrs.fetch(:url),
            fingerprint: attrs.fetch(:fingerprint),
            fetched_at: now,
            metadata: attrs.fetch(:metadata, {})
          )
        end

        def article_scope(document)
          document.at_css("article") ||
            document.at_css(".entry__article") ||
            document.at_css(".blog__content") ||
            document
        end

        def article_heading(document)
          normalize(
            document.at_css(".single-post__entry-title, .entry-title, article h1, h1")&.text
          )
        end

        def title_from_url(href)
          path = URI.parse(href.to_s).path
          File.basename(path).sub(/\.pdf\z/i, "").tr("-_", " ").squish
        rescue URI::InvalidURIError
          ""
        end

        def select_options(document, name)
          document.css("select[name='#{name}'] option").map { |option| normalize(option.text) }
                  .reject { |value| value.blank? || value.match?(/\A-+\s*SVE\s*-+\z/i) }
        end

        def listed_values(values, limit: 12)
          visible = values.first(limit)
          suffix = values.size > limit ? " i još #{values.size - limit}" : nil
          [visible.join(", "), suffix].compact_blank.join(" ")
        end

        def absolute_url(base_url, href)
          value = href.to_s.strip
          return base_url if value.blank? || value.start_with?("#", "javascript:", "mailto:", "tel:")

          URI.join(base_url, value).to_s
        rescue URI::InvalidURIError
          base_url
        end

        def non_content_url?(url)
          uri = URI.parse(url)
          path = uri.path.to_s
          path.blank? || path == "/" || path.match?(%r{/(author|category|tag)/}i)
        rescue URI::InvalidURIError
          false
        end

        def normalize(value)
          ActionController::Base.helpers.strip_tags(value.to_s).gsub(/\s+/, " ").strip
        end

        def truncate(value, limit)
          text = value.to_s
          return text if text.length <= limit

          text[0, limit].rstrip
        end

        def fingerprint_for(source_key, title, url)
          Digest::SHA256.hexdigest([source_key, title, url].join("|"))[0, 24]
        end

        def safe_error(error)
          if defined?(Decidim::Bih::LogRedactor)
            "#{error.class}: #{Decidim::Bih::LogRedactor.error_message(error)}"
          else
            "#{error.class}: #{error.message.to_s.split.join(" ")[0, 240]}"
          end
        end
      end
    end
  end
end
