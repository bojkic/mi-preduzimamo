# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/public_reference_source_registry"

module DecidimApp
  module Bijeljina
    class CityServiceSourcesTest < ActiveSupport::TestCase
      include PublicReferenceSourceRegistry
      test "catalog retains every reviewed source and records owner disabled ones" do
        sources = CityServiceSources.all

        assert_operator sources.size, :>=, 10
        assert_equal sources.size, sources.map { |source| source.fetch(:key) }.uniq.size

        sources.each do |source|
          assert_includes source.fetch(:delivery_modes), CityServiceSources::ON_DEMAND
          assert_match(%r{\Ahttps://}, source.fetch(:source_url))
          assert source.fetch(:area_mapping).present?
        end
      end

      test "only outage safety and emergency sources are Viber alert candidates" do
        candidate_keys = CityServiceSources.alert_candidates.map { |source| source.fetch(:key) }

        assert_includes candidate_keys, "electricity_outages"
        assert_includes candidate_keys, "water_service"
        assert_includes candidate_keys, "civil_protection"
        assert_includes candidate_keys, "weather_warnings"
        assert_not_includes candidate_keys, "waste_schedule"
        assert_not_includes candidate_keys, "sistem48_public_archive"
        assert_not_includes candidate_keys, "air_quality"
        assert_not_includes candidate_keys, "air_quality_realtime"
      end

      test "all Viber alert candidates require operator review" do
        CityServiceSources.alert_candidates.each do |source|
          assert_equal true, source.fetch(:viber).fetch(:requires_operator_review),
                       "#{source.fetch(:key)} must not bypass operator review"
        end
      end

      test "summary exposes disabled Viber automation by default" do
        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => nil) do
          summary = CityServiceSources.summary

          assert_equal CityServiceSources.all.size, summary.fetch(:source_count)
          assert_operator summary.fetch(:viber_candidate_count), :>, 0
          assert_operator summary.fetch(:four_hourly_scrape_count), :>, 0
          assert_operator summary.fetch(:daily_scrape_count), :>, 0
          assert_operator summary.fetch(:weekly_scrape_count), :>, 0
          assert_equal false, summary.fetch(:automatic_viber_enabled)
          assert_includes CityServiceSources.summary_detail, "viber_alerts=disabled"
          assert_includes CityServiceSources.summary_detail, "four_hourly_scrape="
          assert_includes CityServiceSources.summary_detail, "daily_scrape="
          assert_includes CityServiceSources.summary_detail, "weekly_scrape="
        end
      end

      test "source scrape cadence covers every reviewed source exactly once" do
        hourly_keys = CityServiceSources.hourly_sources.map { |source| source.fetch(:key) }
        four_hourly_keys = CityServiceSources.four_hourly_sources.map { |source| source.fetch(:key) }
        daily_keys = CityServiceSources.daily_sources.map { |source| source.fetch(:key) }
        weekly_keys = CityServiceSources.weekly_sources.map { |source| source.fetch(:key) }
        all_keys = CityServiceSources.all.map { |source| source.fetch(:key) }

        assert_empty four_hourly_keys & daily_keys
        assert_empty four_hourly_keys & weekly_keys
        assert_empty daily_keys & weekly_keys
        assert_equal %w(water_service road_conditions civil_protection weather_warnings), hourly_keys
        assert_empty hourly_keys & (four_hourly_keys + daily_keys + weekly_keys)
        enabled_keys = CityServiceSources.all.select { |source| source.fetch(:enabled, true) }.map { |source| source.fetch(:key) }
        assert_equal enabled_keys.sort, (hourly_keys + four_hourly_keys + daily_keys + weekly_keys).sort
        assert_includes all_keys, "heating_service"
        assert_not_includes daily_keys, "heating_service"
        assert_includes four_hourly_keys, "air_quality_realtime"
        assert_includes daily_keys, "electricity_outages"
        assert_includes hourly_keys, "weather_warnings"
        assert_includes daily_keys, "air_quality"
        assert_includes weekly_keys, "waste_schedule"
        assert_includes weekly_keys, "public_transport"
        assert_includes weekly_keys, "police_service_information"
      end

      test "catalogue rows do not claim unobserved runtime source health" do
        rows = CityServiceSources.status_rows(now: Time.zone.parse("2026-06-19 12:00"))
        by_key = rows.index_by { |row| row.fetch(:key) }

        assert_equal CityServiceSources.all.size, rows.size
        electricity = by_key.fetch("service_source.electricity_outages")

        assert_equal "Izmišljeni izvor electricity_outages", electricity.fetch(:label)
        assert_equal "warn", electricity.fetch(:status)
        assert_nil electricity.fetch(:last_updated_on)
        assert_equal "script/mi_city_service_source_probe electricity_outages",
                     electricity.fetch(:refresh_command)
        assert_includes electricity.fetch(:detail), "delivery=viber_alert_candidate"
        assert_includes electricity.fetch(:detail), "catalogue_reviewed_on=2026-06-19"
        assert_includes electricity.fetch(:detail), "runtime_health=unobserved"
        assert_includes electricity.fetch(:detail), "scrape=daily"
        assert_includes electricity.fetch(:detail), "target=area_required"

        waste = by_key.fetch("service_source.waste_schedule")
        assert_includes waste.fetch(:detail), "delivery=on_demand"
        assert_includes waste.fetch(:detail), "scrape=weekly"
      end

      test "status rows use observed content checks and mark stale evidence" do
        checked_at = Time.zone.parse("2026-06-19 10:00")
        check = CityServiceNoticeCollector::SourceCheckResult.new(
          source_key: "electricity_outages",
          status: :empty,
          notices: [],
          checked_at:,
          error_code: nil
        )

        fresh = CityServiceSources.status_rows(checks: [check], now: checked_at + 1.hour)
                                  .index_by { |row| row.fetch(:key) }
                                  .fetch("service_source.electricity_outages")
        stale = CityServiceSources.status_rows(checks: [check], now: checked_at + 3.days)
                                  .index_by { |row| row.fetch(:key) }
                                  .fetch("service_source.electricity_outages")

        assert_equal "ok", fresh.fetch(:status)
        assert_equal "2026-06-19", fresh.fetch(:last_updated_on)
        assert_includes fresh.fetch(:detail), "runtime_health=empty"
        assert_equal "warn", stale.fetch(:status)
      end

      test "owner disabled heating remains visible as disabled despite an old provider failure" do
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "heating_service", status: :unavailable,
                                                                  notices: [], error_code: :source_provider_blocked)
        row = CityServiceSources.status_rows(checks: [check]).find { |entry| entry[:key] == "service_source.heating_service" }
        assert_equal "disabled", row.fetch(:status)
        assert_nil row.fetch(:refresh_command)
        assert_not row.fetch(:provider_blocked)
        assert_includes row.fetch(:detail), "disabled_reason=owner_disabled_2026_09_29"
        assert_includes row.fetch(:detail), "error_code=source_provider_blocked"
        assert_not CityServiceSources.enabled?("heating_service")
        assert_not_includes CityServiceSources.alert_candidates.map { |source| source.fetch(:key) }, "heating_service"
      end

      test "muted source keeps its real status and carries its end date and reason until muted_until, then notes the expiry" do
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "civil_protection", status: :unavailable,
                                                                  notices: [], error_code: :source_unreachable)
        find = ->(rows) { rows.find { |entry| entry[:key] == "service_source.civil_protection" } }

        during = find.call(CityServiceSources.status_rows(checks: [check], now: Time.zone.parse("2026-11-21 23:00")))
        assert_equal "fail", during.fetch(:status), "the real health status stays visible (admin pages)"
        assert_equal "2026-11-21", during.fetch(:muted_until)
        assert_nil during.fetch(:mute_expired)
        assert_includes during.fetch(:detail), "muted_until=2026-11-21 muted_reason=ruczrs_org_refuses_tcp"
        assert_includes during.fetch(:detail), "error_code=source_unreachable"
        assert_includes during.fetch(:detail), "owner=administrator"

        expired = find.call(CityServiceSources.status_rows(checks: [check], now: Time.zone.parse("2026-11-22 08:00")))
        assert_equal "fail", expired.fetch(:status)
        assert_nil expired.fetch(:muted_until)
        assert_equal "2026-11-21", expired.fetch(:mute_expired)
        assert_includes expired.fetch(:detail), "mute_expired=2026-11-21"
      end

      test "sistem48 is muted, road conditions is not, every source has an owner and mutes carry reasons" do
        by_key = CityServiceSources.all.index_by { |source| source.fetch(:key) }
        assert_equal Date.new(2026, 11, 21), by_key.fetch("sistem48_public_archive").fetch(:muted_until)
        assert_nil by_key.fetch("road_conditions")[:muted_until]
        assert_equal "administrator", by_key.fetch("road_conditions").fetch(:owner)
        assert_equal "administrator", by_key.fetch("heating_service").fetch(:owner)
        assert_equal "owner_disabled_2026_09_29", by_key.fetch("heating_service").fetch(:disabled_reason)
        assert_not CityServiceSources.enabled?("heating_service")
        CityServiceSources.all.select { |source| source[:muted_until] }.each do |source|
          assert source[:muted_reason].present?, "#{source.fetch(:key)} is muted without a reason"
          assert_includes CityServiceSources.status_rows(now: Time.zone.parse("2026-10-21")).find { |r| r[:key] == "service_source.#{source.fetch(:key)}" }.fetch(:detail), "owner="
        end
      end

      test "muted? is true only until muted_until and never for disabled sources" do
        civil = CityServiceSources.fetch("civil_protection")
        assert CityServiceSources.muted?(civil, Time.zone.parse("2026-11-21 23:59"))
        assert_not CityServiceSources.muted?(civil, Time.zone.parse("2026-11-22 00:01"))
        assert_not CityServiceSources.muted?(CityServiceSources.fetch("heating_service"), Time.zone.parse("2026-10-21"))
        assert_not CityServiceSources.muted?(CityServiceSources.fetch("road_conditions"), Time.zone.parse("2026-10-21"))
      end

      test "a per-source freshness threshold overrides the cadence default" do
        source = CityServiceSources.find("water_levels").merge(freshness_max_age: 1.hour)
        checked_at = Time.zone.parse("2026-10-21 08:00")
        check = { source_key: "water_levels", status: "ok", checked_at: }
        CityServiceSources.stub(:all, [source]) do
          assert_equal "warn", CityServiceSources.status_rows(checks: [check], now: checked_at + 2.hours).first.fetch(:status)
        end
        CityServiceSources.stub(:all, [source.except(:freshness_max_age)]) do
          assert_equal "ok", CityServiceSources.status_rows(checks: [check], now: checked_at + 2.hours).first.fetch(:status)
        end
      end

      test "source publication staleness is visible as a warning with its cause" do
        check = CityServiceNoticeCollector::SourceCheckResult.new(source_key: "civil_protection", status: :stale,
                                                                  notices: [], error_code: :source_feed_stale)
        after_mute = Time.zone.parse("2026-12-01 12:00")
        row = CityServiceSources.status_rows(checks: [check], now: after_mute).find { |entry| entry[:key] == "service_source.civil_protection" }
        assert_equal "warn", row.fetch(:status)
        assert_includes row.fetch(:detail), "runtime_health=stale"
        assert_includes row.fetch(:detail), "error_code=source_feed_stale"
      end

      test "reachability-only probes never become successful content health" do
        row = CityServiceSources.status_rows(
          checks: [
            {
              source_key: "electricity_outages",
              check_scope: "reachability_only",
              status: "ok",
              checked_at: Time.zone.parse("2026-06-19 10:00")
            }
          ],
          now: Time.zone.parse("2026-06-19 11:00")
        ).index_by { |entry| entry.fetch(:key) }.fetch("service_source.electricity_outages")

        assert_equal "warn", row.fetch(:status)
        assert_includes row.fetch(:detail), "check_scope=reachability_only"
      end

      test "future and invalid check timestamps cannot claim fresh source health" do
        now = Time.zone.parse("2026-06-19 11:00")
        checks = [
          {
            source_key: "electricity_outages",
            status: "empty",
            checked_at: now + 1.hour
          },
          {
            source_key: "water_service",
            status: "empty",
            checked_at: "not-a-time"
          }
        ]
        rows = CityServiceSources.status_rows(checks:, now:).index_by { |entry| entry.fetch(:key) }

        %w(electricity_outages water_service).each do |source_key|
          row = rows.fetch("service_source.#{source_key}")
          assert_equal "fail", row.fetch(:status)
          assert_nil row.fetch(:last_updated_on)
          assert_not_includes row.fetch(:detail), "checked_at="
        end
      end

      test "disabled heating cannot become an alert candidate" do
        decision = CityServiceAlertPolicy.evaluate(source_key: "heating_service", event_type: "heating_interruption",
                                                   severity: "service_outage", target_area_slugs: ["mz-centar"], operator_approved: true)
        assert_equal false, decision.fetch(:send_now)
        assert_equal "source_disabled_by_owner", decision.fetch(:reason)
      end

      test "routine source events stay on demand" do
        decision = CityServiceAlertPolicy.evaluate(
          source_key: "waste_schedule",
          event_type: "regular_pickup",
          severity: "routine",
          target_area_slugs: %w(mz-centar)
        )

        assert_equal false, decision.fetch(:viber_candidate)
        assert_equal false, decision.fetch(:send_now)
        assert_equal CityServiceSources::ON_DEMAND, decision.fetch(:delivery)
        assert_equal "on_demand_only", decision.fetch(:reason)
      end

      test "area-targeted outage is an automatic push candidate but waits for operator review" do
        decision = CityServiceAlertPolicy.evaluate(
          source_key: "electricity_outages",
          event_type: "planned_outage",
          severity: "service_outage",
          target_area_slugs: %w(mz-izmisljeni-vrt mz-izmisljeni-vrt),
          fingerprint: "elektro-2026-06-20-dvorovi"
        )

        assert_equal true, decision.fetch(:viber_candidate)
        assert_equal true, decision.fetch(:automatic_push_candidate)
        assert_equal false, decision.fetch(:send_now)
        assert_equal "operator_review", decision.fetch(:delivery)
        assert_equal "operator_review_required", decision.fetch(:reason)
        assert_equal %w(mz-izmisljeni-vrt), decision.fetch(:target_area_slugs)
        assert_match(/\Acity_service_alert:[a-f0-9]{24}\z/, decision.fetch(:dedupe_key))
        assert_equal 360, decision.fetch(:cooldown_minutes)
        assert_equal 2, decision.fetch(:max_per_area_per_day)
        assert_equal true, decision.fetch(:requires_operator_review)
        assert_equal true, decision.fetch(:honor_opt_out)
        assert_equal "mi_city_service_alerts_viber", decision.fetch(:opt_out_key)
        assert_equal "komsiluk_board", decision.fetch(:legacy_opt_out_key)
        assert_equal "city_service_alerts", decision.fetch(:opt_out_topic)
        assert_equal "viber", decision.fetch(:opt_out_channel)
      end

      test "area-required outage is rejected without MZ or Komsiluk targeting" do
        decision = CityServiceAlertPolicy.evaluate(
          source_key: "water_service",
          event_type: "planned_interruption",
          severity: "service_outage"
        )

        assert_equal false, decision.fetch(:viber_candidate)
        assert_equal "target_area_required", decision.fetch(:reason)
      end

      test "citywide emergency candidates are automatic push candidates" do
        decision = CityServiceAlertPolicy.evaluate(
          source_key: "civil_protection",
          event_type: "flood_warning",
          severity: "emergency"
        )

        assert_equal true, decision.fetch(:viber_candidate)
        assert_equal true, decision.fetch(:automatic_push_candidate)
        assert_equal false, decision.fetch(:send_now)
        assert_equal "operator_review", decision.fetch(:delivery)
        assert_equal "operator_review_required", decision.fetch(:reason)
      end

      test "operator-approved candidate dry-runs while Viber alert switch is disabled" do
        decision = CityServiceAlertPolicy.evaluate(
          source_key: "electricity_outages",
          event_type: "planned_outage",
          severity: "service_outage",
          target_area_slugs: %w(mz-izmisljeni-vrt),
          operator_approved: true
        )

        assert_equal true, decision.fetch(:viber_candidate)
        assert_equal true, decision.fetch(:automatic_push_candidate)
        assert_equal false, decision.fetch(:send_now)
        assert_equal "dry_run", decision.fetch(:delivery)
        assert_equal "alerts_disabled", decision.fetch(:reason)
      end

      test "automatic candidate still requires operator approval when Viber alert switch is enabled" do
        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "1") do
          decision = CityServiceAlertPolicy.evaluate(
            source_key: "electricity_outages",
            event_type: "planned_outage",
            severity: "service_outage",
            target_area_slugs: %w(mz-centar)
          )

          assert_equal true, decision.fetch(:viber_candidate)
          assert_equal true, decision.fetch(:automatic_push_candidate)
          assert_equal false, decision.fetch(:send_now)
          assert_equal "operator_review", decision.fetch(:delivery)
          assert_equal "operator_review_required", decision.fetch(:reason)
          assert_equal true, decision.fetch(:requires_operator_review)
        end
      end

      test "operator-approved candidate sends only when Viber alert switch is enabled" do
        with_env("MI_CITY_SERVICE_VIBER_ALERTS_ENABLED" => "1") do
          decision = CityServiceAlertPolicy.evaluate(
            source_key: "electricity_outages",
            event_type: "planned_outage",
            severity: "service_outage",
            target_area_slugs: %w(mz-centar),
            operator_approved: true
          )

          assert_equal true, decision.fetch(:viber_candidate)
          assert_equal true, decision.fetch(:send_now)
          assert_equal "viber_alert", decision.fetch(:delivery)
          assert_equal "ready", decision.fetch(:reason)
        end
      end

      private

      def with_env(values)
        previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
        values.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
        yield
      ensure
        previous.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
      end
    end
  end
end
