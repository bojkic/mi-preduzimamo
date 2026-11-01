# frozen_string_literal: true

require "date"
require_relative "waste_schedule"
require_relative "parking_zones"
require_relative "budget"
require_relative "gazette"
require_relative "gazette_data"
require_relative "city_directory"
require_relative "city_services_data"
require_relative "city_service_sources"

module DecidimApp
  module Bijeljina
    # Machine-readable freshness contract for Bijeljina city-data snapshots.
    #
    # This is host-owned because the data sources and editorial cadence are
    # Bijeljina-specific. The shared engine consumes only #statuses hashes.
    module CityDataFreshness
      REFRESH_COMMAND = "bin/refresh-city-data.sh"
      READINESS_COMMAND = "script/mi_city_data_refresh_readiness"
      GEO_REFRESH_COMMAND = [
        "#{READINESS_COMMAND} local_areas",
        "rake decidim_bih:geo:validate[HOST]",
        "rake decidim_bih:geo:import_areas[path,HOST]",
        "rake decidim_bih:geo:validate[HOST]"
      ].join(" && ").freeze

      STATIC_SOURCES = [
        {
          key: "waste_schedule",
          label: "Waste schedule",
          last_updated_on: WasteSchedule::SOURCE_CAPTURED_ON,
          stale_after_days: 400,
          refresh_command: "#{READINESS_COMMAND} waste_schedule",
          count: -> { WasteSchedule.default.areas.size },
          detail: ->(_count) { WasteSchedule.coverage_detail }
        },
        {
          key: "parking_zones",
          label: "Parking zones",
          last_updated_on: ParkingZones::SOURCE_CAPTURED_ON,
          stale_after_days: 365,
          refresh_command: "#{READINESS_COMMAND} parking_zones",
          count: -> { ParkingZones.street_count },
          detail: ->(_count) { ParkingZones.coverage_detail }
        },
        {
          key: "budget_snapshot",
          label: "Budget snapshot",
          last_updated_on: Budget::SOURCE_CAPTURED_ON,
          stale_after_days: 400,
          refresh_command: "#{READINESS_COMMAND} budget_snapshot",
          count: -> { Budget.default.line_items.size },
          detail: ->(count) { "source_year=#{Budget::YEAR} line_items=#{count}" }
        },
        {
          key: "gazette_index",
          label: "Gazette index",
          last_updated_on: GazetteData::SOURCE_CAPTURED_ON,
          stale_after_days: 45,
          refresh_command: "#{READINESS_COMMAND} gazette_index",
          count: -> { Gazette.index.all.size },
          detail: ->(count) { "captured_issues=#{count}" }
        },
        {
          key: "service_directory",
          label: "Service directory",
          last_updated_on: CityServicesData::SOURCE_VERIFIED_ON,
          stale_after_days: 365,
          refresh_command: "#{READINESS_COMMAND} service_directory",
          count: -> { CityDirectory.all.size },
          detail: ->(count) { CityServicesData.coverage_detail(count) }
        },
        {
          key: "service_alert_sources",
          label: "Service and alert sources",
          last_updated_on: CityServiceSources::SOURCE_REVIEWED_ON,
          stale_after_days: 180,
          refresh_command: "#{READINESS_COMMAND} service_alert_sources",
          count: -> { CityServiceSources.all.size },
          detail: ->(_count) { CityServiceSources.summary_detail }
        }
      ].freeze

      class << self
        def statuses(organization: nil, source_checks: nil, now: Time.current)
          source_checks ||= CityServiceSourceCheckStore.check
          STATIC_SOURCES.map { |source| static_status(source) } +
            CityServiceSources.status_rows(checks: source_checks, now:) +
            [service_quality_status(organization, now:), *service_review_statuses(organization, now:), local_area_status(organization)]
        end

        private

        def service_quality_status(organization, now:)
          unless organization
            return { key: "service_data_quality", label: "Service data quality", status: "warn", detail: "organization_missing",
                     last_updated_on: nil, refresh_command: "script/mi_city_service_area_prepare" }
          end

          events = review_events(organization, now:)
          unknown = events.where(targeting_level: "unknown").count
          invalid = events.where("ends_at <= starts_at OR starts_at IS NULL OR ends_at IS NULL").count
          { key: "service_data_quality", label: "Service data quality",
            status: "ok", last_updated_on: now.to_date.iso8601,
            refresh_command: "script/mi_city_service_area_prepare",
            detail: "active_unknown_areas=#{unknown} invalid_reviewable_windows=#{invalid} review_path=/admin/bih/city-alerts?tab=review" }
        rescue StandardError => e
          failure_status(key: "service_data_quality", label: "Service data quality",
                         refresh_command: "script/mi_city_service_area_prepare", detail: e.class.name)
        end

        def service_review_statuses(organization, now:)
          return [] unless organization

          review_events(organization, now:).where("targeting_level = ? OR ends_at <= starts_at OR starts_at IS NULL OR ends_at IS NULL", "unknown")
                                          .group(:source_key).count.map do |source_key, count|
            source = CityServiceSources.find(source_key)
            { key: "service_review.#{source_key}", label: source&.fetch(:label) || source_key,
              status: "warn", review_count: count, last_updated_on: now.to_date.iso8601,
              refresh_command: "script/mi_city_service_area_prepare",
              detail: "pending_review=#{count} review_path=/admin/bih/city-alerts?tab=review" }
          end
        end

        def review_events(organization, now:)
          CityServiceEvent.for_organization(organization).pending_review
                          .where.not(lifecycle: %w(cancelled resolved superseded))
                          .where("ends_at IS NULL OR ends_at > ?", now)
        end

        def static_status(source)
          count = source.fetch(:count).call
          status = static_source_status(source, count)

          {
            key: source.fetch(:key),
            label: dataset_label(source.fetch(:key), source.fetch(:label)),
            status:,
            last_updated_on: effective_source_date(source).iso8601,
            refresh_command: source.fetch(:refresh_command),
            detail: source.fetch(:detail).call(count)
          }
        rescue StandardError => e
          failure_status(
            key: source.fetch(:key),
            label: dataset_label(source.fetch(:key), source.fetch(:label)),
            refresh_command: source.fetch(:refresh_command),
            detail: "#{e.class}: #{e.message}"
          )
        end

        def effective_source_date(source)
          source.fetch(:key) == "gazette_index" ? Gazette.index_checked_on : source.fetch(:last_updated_on)
        end

        def static_source_status(source, count)
          return "fail" unless count.to_i.positive?

          effective_source_date(source) < source.fetch(:stale_after_days).days.ago.to_date ? "warn" : "ok"
        end

        def local_area_status(organization)
          return missing_local_area_status unless organization

          scope = Decidim::Bih::LocalArea.where(decidim_organization_id: organization.id)
          count = scope.count
          latest = scope.maximum(:updated_at)
          issue_count = local_area_issue_count(organization)
          completeness = local_area_contact_completeness(scope)
          status = local_area_status_value(count:, latest:, issue_count:, completeness:)

          {
            key: "local_areas",
            label: dataset_label("local_areas", "Local areas"),
            status:,
            last_updated_on: latest&.to_date&.iso8601,
            refresh_command: GEO_REFRESH_COMMAND.sub("HOST", organization.host.to_s),
            detail: local_area_detail(count:, issue_count:, completeness:)
          }
        rescue StandardError => e
          failure_status(
            key: "local_areas",
            label: dataset_label("local_areas", "Local areas"),
            refresh_command: GEO_REFRESH_COMMAND,
            detail: "#{e.class}: #{e.message}"
          )
        end

        def local_area_issue_count(organization)
          Decidim::Bih::Geo::IntegrityCheck.new(organization).call.values.sum(&:size)
        end

        def dataset_label(key, fallback)
          I18n.t("decidim_app.city_data.datasets.#{key}", default: fallback)
        end

        def local_area_contact_completeness(scope)
          mz_scope = scope.mz
          missing_president = mz_scope.where(predsjednik: [nil, ""]).count
          missing_phone = mz_scope.where(telefon: [nil, ""]).count
          missing_both = mz_scope.where(predsjednik: [nil, ""], telefon: [nil, ""]).count

          {
            mz_count: mz_scope.count,
            komsiluk_count: scope.komsiluci.count,
            missing_president:,
            missing_phone:,
            missing_both:
          }
        end

        def local_area_status_value(count:, latest:, issue_count:, completeness:)
          return "fail" unless count.to_i.positive?
          return "warn" if issue_count.positive?
          return "warn" if completeness.fetch(:missing_both).positive?
          return "warn" if latest.nil?
          return "warn" if latest < 365.days.ago

          "ok"
        end

        def local_area_detail(count:, issue_count:, completeness:)
          "areas=#{count} mz=#{completeness.fetch(:mz_count)} " \
            "komsiluk=#{completeness.fetch(:komsiluk_count)} " \
            "missing_president=#{completeness.fetch(:missing_president)} " \
            "missing_phone=#{completeness.fetch(:missing_phone)} " \
            "missing_contact=#{completeness.fetch(:missing_both)} " \
            "integrity_issues=#{issue_count}"
        end

        def missing_local_area_status
          {
            key: "local_areas",
            label: "Local areas",
            status: "warn",
            last_updated_on: nil,
            refresh_command: GEO_REFRESH_COMMAND,
            detail: "organization missing"
          }
        end

        def failure_status(key:, label:, refresh_command:, detail:)
          {
            key:,
            label:,
            status: "fail",
            last_updated_on: nil,
            refresh_command:,
            detail: sanitize(detail)
          }
        end

        def sanitize(value)
          if defined?(Decidim::Bih::SafeErrorMetadata)
            Decidim::Bih::SafeErrorMetadata.sanitize_text(value, max: 240)
          else
            value.to_s.split.join(" ")[0, 240]
          end
        end
      end
    end
  end
end
