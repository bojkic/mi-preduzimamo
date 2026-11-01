# frozen_string_literal: true

require "date"
require "json"
require "uri"
require "active_support/core_ext/integer/time"

module DecidimApp
  module Bijeljina
    # Reviewed source catalog for citizen-facing service information.
    #
    # The catalog deliberately separates "can answer on demand" from "may ever
    # become an outbound Viber alert". It does not fetch sources or send
    # messages; parsers/jobs must use CityServiceAlertPolicy before fan-out.
    module CityServiceSources
      SOURCE_REVIEWED_ON = Date.new(2026, 6, 19)
      ALERTS_ENABLED_ENV = "MI_CITY_SERVICE_VIBER_ALERTS_ENABLED"

      ON_DEMAND = "on_demand"
      VIBER_ALERT_CANDIDATE = "viber_alert_candidate"
      HOURLY = "hourly"
      FOUR_HOURLY = "four_hourly"
      DAILY = "daily"
      WEEKLY = "weekly"
      HEALTH_MAX_AGES = {
        HOURLY => 3.hours,
        FOUR_HOURLY => 8.hours,
        DAILY => 2.days,
        WEEKLY => 14.days
      }.freeze

      # Semantic source capabilities consumed by prepared typed reads. Provider
      # metadata and cadence remain in SOURCES, not a second catalogue.
      TOPIC_SOURCE_KEYS = {
        "air_quality" => %w(air_quality_realtime air_quality),
        "water_levels" => %w(water_levels),
        "police" => %w(police_service_information),
        "sistem48" => %w(sistem48_public_archive),
        "weather" => %w(weather_warnings),
        "civil_protection" => %w(civil_protection),
        "roads" => %w(road_conditions),
        "bulky_waste" => %w(bulky_waste)
      }.freeze

      # Measured 2026-09-14 09:35 UTC during source review (task 8a). Freshness
      # for these providers must come from the date INSIDE the content plus a
      # content hash, never from an HTTP header:
      #
      #   * komunalacbn.com and elektrobijeljina.com return a Last-Modified
      #     equal to the request time, so every page looks edited seconds ago;
      #   * bnvodovod.com and gradskatoplanabijeljina.com send neither
      #     Last-Modified nor ETag;
      #   * all four send Cache-Control: no-store, no-cache, must-revalidate.
      #
      # This is a registry, not a comment, so a test can assert the rule and a
      # future conditional-request optimisation trips over it rather than
      # silently reintroducing a false freshness signal.
      HTTP_FRESHNESS_UNUSABLE_HOSTS = {
        "komunalacbn.com" => "last_modified_equals_request_time",
        "elektrobijeljina.com" => "last_modified_equals_request_time",
        "bnvodovod.com" => "no_last_modified_no_etag",
        "gradskatoplanabijeljina.com" => "no_last_modified_no_etag"
      }.freeze
      CONTENT_FRESHNESS_MEASURED_ON = Date.new(2026, 9, 14)

      # Per-source operations fields (all optional):
      #   owner:              who repairs/decides; "unassigned" until the owner names someone
      #   freshness_max_age:  overrides HEALTH_MAX_AGES for this source
      #   muted_until:        Date; the scheduled scrape skips the source and ops
      #                       health/digest do not alert on it until this date, then it
      #                       is fetched again and alerts with a "mute expired" note until
      #                       handled. Needs muted_reason:. Published events and the real
      #                       health status are untouched; only fetching and alerts pause.
      #   disabled_reason:    (with enabled: false) why the source is switched off
      #   disabled_detail:    free text for the operator: the fix needed before re-enabling
      UNASSIGNED_OWNER = "unassigned"

      AREA_REQUIRED = "area_required"
      CITYWIDE_ALLOWED = "citywide_allowed"

      ROUTINE_ONLY = {
        eligible: false,
        requires_operator_review: true,
        event_types: [],
        severities: [],
        target: AREA_REQUIRED,
        cooldown_minutes: nil,
        max_per_area_per_day: 0
      }.freeze

      REFERENCE_SOURCES = [
        {
          key: "electricity_outages",
          label: "Elektro Bijeljina planned outages",
          provider: "Elektro Bijeljina",
          source_url: "https://elektrobijeljina.com/lt/podrska/iskljucenja/index.php?rj=41",
          source_kind: "official_table",
          scrape_cadence: DAILY,
          update_cadence: "daily_when_planned_outages_exist",
          location_granularity: "settlement_transformer_or_low_voltage_output",
          area_mapping: "match affected-place text to MZ/Komsiluk aliases before fan-out",
          delivery_modes: [ON_DEMAND, VIBER_ALERT_CANDIDATE],
          viber: {
            eligible: true,
            requires_operator_review: true,
            event_types: %w(planned_outage unplanned_outage restoration_update),
            severities: %w(service_outage emergency),
            target: AREA_REQUIRED,
            cooldown_minutes: 360,
            max_per_area_per_day: 2
          }
        },
        {
          key: "water_service",
          label: "Vodovod service information",
          provider: "AD Vodovod i kanalizacija Bijeljina",
          source_url: "https://www.bnvodovod.com/v2/category/servisne-informacije/",
          source_kind: "official_posts",
          scrape_cadence: HOURLY,
          update_cadence: "workday_or_incident",
          location_granularity: "street_settlement_or_citywide_water-system",
          area_mapping: "geocode/alias affected streets and settlements to MZ/Komsiluk",
          follows_article_links: true,
          delivery_modes: [ON_DEMAND, VIBER_ALERT_CANDIDATE],
          viber: {
            eligible: true,
            requires_operator_review: true,
            event_types: %w(planned_interruption unplanned_interruption restoration_update),
            severities: %w(service_outage emergency),
            target: AREA_REQUIRED,
            cooldown_minutes: 360,
            max_per_area_per_day: 2
          }
        },
        {
          key: "waste_schedule",
          label: "Komunalac regular waste schedule",
          provider: "AD Komunalac Bijeljina",
          source_url: "https://www.komunalacbn.com/images/Razno/Program_odvoza_otpada_za_2026.pdf",
          max_bytes: 2_000_000,
          source_kind: "official_pdf",
          scrape_cadence: WEEKLY,
          update_cadence: "annual_or_program_change",
          location_granularity: "settlement_or_route",
          area_mapping: "match schedule areas to MZ/Komsiluk aliases",
          delivery_modes: [ON_DEMAND],
          viber: ROUTINE_ONLY
        },
        {
          key: "bulky_waste",
          label: "Komunalac bulky-waste and cleaning actions",
          provider: "AD Komunalac Bijeljina",
          source_url: "https://www.komunalacbn.com/info-centar/aktuelnosti",
          source_kind: "official_posts",
          scrape_cadence: WEEKLY,
          update_cadence: "seasonal_campaigns",
          location_granularity: "citywide_or_route",
          area_mapping: "route or settlement aliases when listed",
          follows_article_links: true,
          delivery_modes: [ON_DEMAND],
          viber: ROUTINE_ONLY
        },
        {
          key: "city_official_notices",
          label: "Grad Bijeljina official notices",
          provider: "Grad Bijeljina",
          source_url: "https://www.gradbijeljina.org/lat/news/obavjestenja/",
          source_kind: "official_posts",
          scrape_cadence: DAILY,
          follows_article_links: true,
          update_cadence: "as_published",
          location_granularity: "street_settlement_or_citywide",
          area_mapping: "parse listed locations, then resolve to MZ/Komsiluk",
          delivery_modes: [ON_DEMAND, VIBER_ALERT_CANDIDATE],
          viber: {
            eligible: true,
            requires_operator_review: true,
            event_types: %w(road_closure mosquito_spraying public_health_notice emergency_notice),
            severities: %w(safety service_outage emergency),
            target: CITYWIDE_ALLOWED,
            cooldown_minutes: 360,
            max_per_area_per_day: 2
          }
        },
        {
          key: "sistem48_public_archive",
          owner: "administrator",
          muted_until: Date.new(2026, 11, 21),
          muted_reason: "bitninja_waf_http_447_to_our_user_agent_ask_grad_bijeljina_it_to_allowlist",
          label: "Sistem 48 public reports",
          provider: "Grad Bijeljina Sistem 48",
          source_url: "https://www.bijeljina48.org/pregled/",
          source_kind: "official_public_archive",
          scrape_cadence: WEEKLY,
          update_cadence: "continuous_public_reports",
          location_granularity: "report_location_when_public",
          area_mapping: "aggregate only; never rebroadcast raw citizen content",
          delivery_modes: [ON_DEMAND],
          viber: ROUTINE_ONLY
        },
        {
          key: "heating_service",
          enabled: false,
          disabled_reason: "owner_disabled_2026_09_29",
          owner: "administrator",
          disabled_detail: "nginx WAF returns 403 to our user agent only; ask Gradska toplana to allowlist it, then set enabled: true",
          label: "Gradska toplana notices",
          provider: "JP Gradska toplana Bijeljina",
          source_url: "https://www.gradskatoplanabijeljina.com/vijesti.php",
          source_kind: "official_posts",
          scrape_cadence: DAILY,
          update_cadence: "heating_season_or_incident",
          location_granularity: "heating-network_area_or_city_center",
          area_mapping: "requires host-maintained heating-network to MZ/Komsiluk mapping",
          # The listing publishes truncated teasers; the notice only exists
          # behind vijesti-detaljno.php?id=N, which CityServiceHeatingArticles
          # follows. Without it the parser sees a sentence fragment.
          follows_article_links: true,
          # The provider has never published which streets or buildings are on
          # the toplovodna mreza, so an unmatched heating notice is unmapped
          # coverage - never evidence that a household is unaffected.
          network_footprint: "not_published",
          delivery_modes: [ON_DEMAND, VIBER_ALERT_CANDIDATE],
          viber: {
            eligible: true,
            requires_operator_review: true,
            event_types: %w(heating_interruption restoration_update fuel_supply_warning),
            severities: %w(service_outage emergency),
            target: AREA_REQUIRED,
            cooldown_minutes: 480,
            max_per_area_per_day: 2
          }
        },
        {
          key: "public_transport",
          label: "Public transport routes and notices",
          provider: "Grad Bijeljina",
          source_url: "https://www.gradbijeljina.org/sr/news/novosti//7243.od-sutra-novi-red-voznje.html",
          source_kind: "official_reviewed_image_set",
          scrape_cadence: WEEKLY,
          update_cadence: "route_change_or_service_notice",
          location_granularity: "line_stop_or_settlement",
          area_mapping: "map route stops and settlements to MZ/Komsiluk",
          delivery_modes: [ON_DEMAND],
          viber: ROUTINE_ONLY
        },
        {
          key: "road_conditions",
          owner: "administrator",
          # Keep enabled: Satwork recovered on Oct 22. Its Oct 21 "error, try later"
          # redirect is classified as source_unreachable if the outage recurs.
          label: "AMS RS road conditions",
          provider: "Auto-moto savez Republike Srpske",
          # Exact report iframe linked by the official AMS page; the wrapper
          # contains navigation and consent text but no road report.
          source_url: "https://v3.satwork.net/ExtServices/ams/stanjeNaPutevima.php",
          source_kind: "official_regional_posts",
          scrape_cadence: HOURLY,
          update_cadence: "continuous",
          location_granularity: "regional_or_main_road_segment",
          area_mapping: "alert only for Bijeljina segments mapped to affected MZ/Komsiluk",
          delivery_modes: [ON_DEMAND, VIBER_ALERT_CANDIDATE],
          viber: {
            eligible: true,
            requires_operator_review: true,
            event_types: %w(road_closure road_hazard restoration_update),
            severities: %w(safety service_outage emergency),
            target: AREA_REQUIRED,
            cooldown_minutes: 360,
            max_per_area_per_day: 2
          }
        },
        {
          key: "civil_protection",
          owner: "administrator",
          muted_until: Date.new(2026, 11, 21),
          muted_reason: "ruczrs_org_refuses_tcp_80_443_since_2026_09_15_ask_rucz_for_status_and_crawl_permission",
          label: "Civil protection warnings",
          provider: "Republička uprava civilne zaštite / Grad Bijeljina",
          source_url: "https://ruczrs.org/feed/",
          source_kind: "official_warning_posts",
          scrape_cadence: HOURLY,
          update_cadence: "incident_or_warning",
          location_granularity: "citywide_river_corridor_or_settlement",
          area_mapping: "prefer affected MZ/Komsiluk; citywide only for official emergency warnings",
          delivery_modes: [ON_DEMAND, VIBER_ALERT_CANDIDATE],
          viber: {
            eligible: true,
            requires_operator_review: true,
            event_types: %w(flood_warning storm_warning fire_warning evacuation_notice emergency_notice),
            severities: %w(safety emergency),
            target: CITYWIDE_ALLOWED,
            cooldown_minutes: 180,
            max_per_area_per_day: 3
          }
        },
        {
          key: "weather_warnings",
          label: "Weather warnings",
          provider: "MeteoAlarm / RHMZ RS",
          source_url: "https://feeds.meteoalarm.org/api/v1/warnings/feeds-bosnia-herzegovina",
          source_kind: "official_warning_cap_json",
          scrape_cadence: HOURLY,
          update_cadence: "continuous",
          location_granularity: "region_or_city",
          area_mapping: "citywide only for orange/red or civil-protection-confirmed warnings",
          delivery_modes: [ON_DEMAND, VIBER_ALERT_CANDIDATE],
          viber: {
            eligible: true,
            requires_operator_review: true,
            event_types: %w(severe_weather heat_warning storm_warning flood_risk),
            severities: %w(safety emergency),
            target: CITYWIDE_ALLOWED,
            cooldown_minutes: 360,
            max_per_area_per_day: 2
          }
        },
        {
          key: "water_levels",
          label: "Sava/Drina water levels",
          provider: "Hydromet sources via local public pages",
          source_url: "https://www.bijeljina.org/vodostaji.html",
          source_kind: "secondary_aggregator",
          scrape_cadence: DAILY,
          update_cadence: "continuous_when_available",
          location_granularity: "river_station",
          area_mapping: "requires flood-prone MZ/Komsiluk corridor map before outbound use",
          delivery_modes: [ON_DEMAND, VIBER_ALERT_CANDIDATE],
          viber: {
            eligible: true,
            requires_operator_review: true,
            event_types: %w(flood_watch flood_warning level_normalized),
            severities: %w(safety emergency),
            target: AREA_REQUIRED,
            cooldown_minutes: 240,
            max_per_area_per_day: 3
          }
        },
        {
          key: "air_quality",
          label: "Bijeljina air quality",
          provider: "Grad Bijeljina / air-quality station feeds",
          source_url: "https://www.gradbijeljina.org/lat/news/servisne/kvalitet-vazduha/1442.podaci-o-kvalitetu-vazduha-u-gradu-bijeljina.html",
          source_kind: "official_or_station_feed",
          scrape_cadence: DAILY,
          update_cadence: "continuous_when_station_available",
          location_granularity: "city_or_station",
          area_mapping: "citywide; no neighborhood fan-out until station coverage expands",
          delivery_modes: [ON_DEMAND],
          viber: ROUTINE_ONLY
        },
        {
          key: "air_quality_realtime",
          label: "Bijeljina realtime air quality",
          provider: "Klimerko",
          source_url: "https://klimerko.org/map?pollutant=pm2&range=latest&zoom=15&latitude=44.76497&longitude=19.21337",
          source_kind: "community_realtime_map",
          scrape_cadence: FOUR_HOURLY,
          update_cadence: "every_4_hours",
          location_granularity: "city",
          area_mapping: "citywide community-sensor aggregate; no neighborhood fan-out",
          delivery_modes: [ON_DEMAND],
          viber: ROUTINE_ONLY
        },
        {
          key: "police_service_information",
          label: "Police service and safety notices",
          provider: "MUP RS / PU Bijeljina",
          source_url: "https://mup.vladars.rs/lat/ministarstvo/pubn",
          source_kind: "official_posts",
          max_bytes: 1_500_000,
          scrape_cadence: WEEKLY,
          update_cadence: "as_published",
          location_granularity: "city_or_police_area",
          area_mapping: "use only service/safety notices; avoid routine crime rebroadcasts",
          delivery_modes: [ON_DEMAND],
          viber: ROUTINE_ONLY
        }
      ].freeze

      # Referentni opisi ne uključuju prikupljanje. Svaka zajednica izričito
      # zadaje svoj katalog; ne nasljeđuju se URL-ovi ili primaoci Bijeljine.
      CONFIG_PATH = ENV.fetch("MI_CITY_SOURCES_PATH", "").freeze
      SOURCES = (CONFIG_PATH.empty? ? [] : JSON.parse(File.read(CONFIG_PATH), symbolize_names: true).fetch(:sources)).map do |source|
        raise ArgumentError, "community source needs an explicit key and URL" if source.fetch(:key).to_s.empty? || source.fetch(:source_url).to_s.empty?

        source.merge(key: source.fetch(:key).to_s, enabled: source.fetch(:enabled, false)).freeze
      end.freeze

      class << self
        def all
          SOURCES.map(&:deep_dup)
        end

        def find(key)
          all.find { |source| source.fetch(:key) == key.to_s }
        end

        def fetch(key)
          find(key) || raise(KeyError, "unknown city service source: #{key}")
        end

        def enabled?(key)
          source = find(key)
          source.present? && source.fetch(:enabled, true)
        end

        def alert_candidates
          all.select { |source| source.fetch(:enabled, true) && source.fetch(:delivery_modes).include?(VIBER_ALERT_CANDIDATE) }
        end

        def hourly_sources
          sources_for_cadence(HOURLY)
        end

        def daily_sources
          sources_for_cadence(DAILY)
        end

        def four_hourly_sources
          sources_for_cadence(FOUR_HOURLY)
        end

        def weekly_sources
          sources_for_cadence(WEEKLY)
        end

        def sources_for_cadence(cadence)
          all.select { |source| source.fetch(:enabled, true) && source.fetch(:scrape_cadence).to_s == cadence.to_s }
        end

        def summary
          sources = all
          candidates = sources.select { |source| source.fetch(:enabled, true) && source.fetch(:viber).fetch(:eligible) }
          {
            source_count: sources.size,
            on_demand_count: sources.count { |source| source.fetch(:enabled, true) && source.fetch(:delivery_modes).include?(ON_DEMAND) },
            viber_candidate_count: candidates.size,
            operator_review_required_count: candidates.count { |source| source.fetch(:viber).fetch(:requires_operator_review) },
            hourly_scrape_count: hourly_sources.size,
            four_hourly_scrape_count: four_hourly_sources.size,
            daily_scrape_count: daily_sources.size,
            weekly_scrape_count: weekly_sources.size,
            automatic_viber_enabled: alerts_enabled?
          }
        end

        def summary_detail
          values = summary
          [
            "catalogue_configuration=reviewed",
            "runtime_health=reported_separately",
            "sources=#{values.fetch(:source_count)}",
            "on_demand=#{values.fetch(:on_demand_count)}",
            "viber_candidates=#{values.fetch(:viber_candidate_count)}",
            "hourly_scrape=#{values.fetch(:hourly_scrape_count)}",
            "four_hourly_scrape=#{values.fetch(:four_hourly_scrape_count)}",
            "daily_scrape=#{values.fetch(:daily_scrape_count)}",
            "weekly_scrape=#{values.fetch(:weekly_scrape_count)}",
            "operator_review_required=#{values.fetch(:operator_review_required_count)}",
            "viber_alerts=#{values.fetch(:automatic_viber_enabled) ? "enabled" : "disabled"}"
          ].join(" ")
        end

        def alerts_enabled?
          ENV.fetch(ALERTS_ENABLED_ENV, "0").match?(/\A(1|true|yes)\z/i)
        end

        # True when the source's host publishes no usable HTTP freshness
        # metadata, so only an in-content date plus a content hash may be used.
        def content_freshness_only?(key)
          host = URI.parse(fetch(key).fetch(:source_url)).host.to_s.downcase.sub(/\Awww\./, "")
          HTTP_FRESHNESS_UNUSABLE_HOSTS.has_key?(host)
        rescue KeyError, URI::InvalidURIError
          false
        end

        def http_freshness_evidence(key)
          host = URI.parse(fetch(key).fetch(:source_url)).host.to_s.downcase.sub(/\Awww\./, "")
          HTTP_FRESHNESS_UNUSABLE_HOSTS[host]
        rescue KeyError, URI::InvalidURIError
          nil
        end

        def status_rows(checks: [], now: Time.current)
          checks = Array(checks)
          all.map do |source|
            check = checks.reverse.find { |candidate| check_value(candidate, :source_key).to_s == source.fetch(:key) }
            checked_at = checked_at_value(check, now:)
            {
              key: "service_source.#{source.fetch(:key)}",
              label: source.fetch(:label),
              status: source_status(source, check, checked_at, now),
              muted_until: active_mute?(source, now) ? source.fetch(:muted_until).iso8601 : nil,
              mute_expired: mute_expired?(source, now) ? source.fetch(:muted_until).iso8601 : nil,
              last_updated_on: checked_at&.to_date&.iso8601,
              refresh_command: source.fetch(:enabled, true) ? "script/mi_city_service_source_probe #{source.fetch(:key)}" : nil,
              provider_blocked: source.fetch(:enabled, true) && provider_blocked?(check),
              detail: status_detail(source, check:, checked_at:, now:)
            }
          end
        end

        def owner_for(source) = source.fetch(:owner, UNASSIGNED_OWNER)

        # True while the source's mute date has not passed (disabled sources are
        # "disabled", not muted).
        def muted?(source, now = Time.current) = active_mute?(source, now)

        def active_mute?(source, now)
          source.fetch(:enabled, true) && source[:muted_until].present? && now.to_date <= source.fetch(:muted_until)
        end

        def mute_expired?(source, now)
          source.fetch(:enabled, true) && source[:muted_until].present? && now.to_date > source.fetch(:muted_until)
        end

        private

        def source_status(source, check, checked_at, now)
          return "disabled" unless source.fetch(:enabled, true)

          health_status(source, check, checked_at, now)
        end

        def mute_detail(source, now)
          date = source[:muted_until]&.iso8601
          return ["muted_until=#{date} muted_reason=#{source.fetch(:muted_reason)}"] if active_mute?(source, now)

          mute_expired?(source, now) ? ["mute_expired=#{date}"] : []
        end

        # rubocop:disable Metrics/CyclomaticComplexity -- one flat list of optional detail fragments; splitting it would only scatter the format
        def status_detail(source, check:, checked_at:, now:)
          viber = source.fetch(:viber)
          delivery = viber.fetch(:eligible) ? VIBER_ALERT_CANDIDATE : ON_DEMAND
          target = viber.fetch(:eligible) ? viber.fetch(:target) : "none"
          check_status = check_value(check, :status).presence || "unobserved"
          check_scope = check_value(check, :check_scope).presence || (check ? "content" : "none")

          [
            "provider=#{source.fetch(:provider)}",
            "catalogue_reviewed_on=#{SOURCE_REVIEWED_ON.iso8601}",
            "runtime_health=#{source.fetch(:enabled, true) ? check_status : "disabled_by_owner"}",
            ("disabled_reason=#{source.fetch(:disabled_reason)}" unless source.fetch(:enabled, true)),
            *mute_detail(source, now),
            "owner=#{owner_for(source)}",
            ("error_code=#{check_value(check, :error_code)}" if check_value(check, :error_code).present?),
            "check_scope=#{check_scope}",
            ("checked_at=#{checked_at.iso8601}" if checked_at),
            "delivery=#{delivery}",
            "scrape=#{source.fetch(:scrape_cadence)}",
            "target=#{target}",
            "source_kind=#{source.fetch(:source_kind)}"
          ].compact.join(" ")
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        def health_status(source, check, checked_at, now)
          return "warn" unless check
          return "warn" if provider_blocked?(check)
          return "warn" if check_value(check, :check_scope).to_s == "reachability_only"

          case check_value(check, :status).to_s
          when "ok", "empty"
            return "fail" unless checked_at

            checked_at < now - source.fetch(:freshness_max_age, HEALTH_MAX_AGES.fetch(source.fetch(:scrape_cadence))) ? "warn" : "ok"
          when "unavailable", "malformed", "fail"
            "fail"
          else
            "warn"
          end
        end

        # The site refuses the collector: an outside request to its admin, not
        # a fault here, and retried once a day (CitySourceRequestPolicy).
        def provider_blocked?(check)
          check_value(check, :error_code).to_s == "source_provider_blocked"
        end

        def checked_at_value(check, now:)
          value = check_value(check, :checked_at)
          return if value.blank?

          time = value.respond_to?(:in_time_zone) ? value : Time.zone.parse(value.to_s)
          return if time.nil? || time > now

          time
        rescue StandardError
          nil
        end

        def check_value(check, key)
          return if check.nil?
          return check.public_send(key) if check.respond_to?(key)
          return check[key] if check.respond_to?(:has_key?) && check.has_key?(key)
          return check[key.to_s] if check.respond_to?(:has_key?) && check.has_key?(key.to_s)

          nil
        end
      end
    end
  end
end
