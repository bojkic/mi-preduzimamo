# frozen_string_literal: true

require_relative "waste_schedule"
require_relative "parking_zones"
require_relative "budget"

module DecidimApp
  module Bijeljina
    # Admin-only previews for host-owned city datasets that citizens should
    # reach through MI bot rather than anonymous browse pages.
    module CityDataPreview
      DEFAULT_LIMIT = 12

      class << self
        def previews(organization:, waste_query: nil, parking_query: nil, budget_query: nil, locale: I18n.locale) # rubocop:disable Lint/UnusedMethodArgument
          [
            waste_preview(waste_query),
            parking_preview(parking_query),
            budget_preview(budget_query, locale:)
          ]
        end

        private

        def waste_preview(query)
          schedule = WasteSchedule.default
          query = query.to_s.strip
          areas = Array(schedule.areas)
          rows =
            if query.present?
              days = schedule.collection_days_for(query)
              [{
                label: query,
                value: Array(days).presence&.join(", ") || I18n.t("decidim_app.city_data_preview.not_found",
                                                                  default: "No match")
              }]
            else
              areas.first(DEFAULT_LIMIT).map do |area|
                {
                  label: area,
                  value: Array(schedule.collection_days_for(area)).join(", ").presence ||
                    I18n.t("decidim_app.city_data_preview.waste.unresolved", default: "Schedule unresolved; specify district or street segment")
                }
              end
            end

          {
            key: "waste_schedule",
            label: I18n.t("decidim_app.city_data_preview.waste.label", default: "Waste schedule"),
            query:,
            query_param: "city_waste_query",
            placeholder: I18n.t("decidim_app.city_data_preview.waste.placeholder", default: "Area or street"),
            source_url: WasteSchedule.schedule_url,
            metadata: WasteSchedule.coverage_detail,
            rows:
          }
        rescue StandardError => e
          failure_preview("waste_schedule", "city_waste_query", e)
        end

        def budget_preview(query, locale:)
          budget = Budget.default
          query = query.to_s.strip
          line_items = filter_items(budget.line_items, query)
          rows = localize_items(line_items.first(DEFAULT_LIMIT), locale:).map do |item|
            {
              label: item.fetch(:category),
              value: "#{number(item.fetch(:amount))} KM"
            }
          end

          {
            key: "budget_snapshot",
            label: I18n.t("decidim_app.city_data_preview.budget.label", default: "Budget snapshot"),
            query:,
            query_param: "city_budget_query",
            placeholder: I18n.t("decidim_app.city_data_preview.budget.placeholder", default: "Category"),
            source_url: Budget.source_url,
            metadata: "source_year=#{Budget::YEAR} line_items=#{budget.line_items.size}",
            rows:
          }
        rescue StandardError => e
          failure_preview("budget_snapshot", "city_budget_query", e)
        end

        def parking_preview(query)
          zones = ParkingZones.default
          query = query.to_s.strip
          rows =
            if query.present?
              if (street = zones.lookup(query))
                [{ label: street.fetch(:street_name), value: parking_value(street) }]
              else
                [{
                  label: query,
                  value: I18n.t("decidim_app.city_data_preview.not_found", default: "No match")
                }]
              end
            else
              zones.streets.first(DEFAULT_LIMIT).map do |street|
                { label: street.fetch(:street_name), value: parking_value(street) }
              end
            end

          {
            key: "parking_zones",
            label: I18n.t("decidim_app.city_data_preview.parking.label", default: "Parking zones"),
            query:,
            query_param: "city_parking_query",
            placeholder: I18n.t("decidim_app.city_data_preview.parking.placeholder", default: "Street"),
            source_url: ParkingZones.source_url,
            metadata: ParkingZones.coverage_detail,
            rows:
          }
        rescue StandardError => e
          failure_preview("parking_zones", "city_parking_query", e)
        end

        def failure_preview(key, query_param, error)
          {
            key:,
            label: I18n.t("decidim_app.city_data.datasets.#{key}", default: key.tr("_", " ").capitalize),
            query: "",
            query_param:,
            placeholder: "",
            source_url: nil,
            metadata: "#{error.class}: #{Decidim::Bih::LogRedactor.error_message(error)}",
            rows: []
          }
        end

        def filter_items(items, query)
          return Array(items) if query.blank?

          needle = Decidim::Bih::Text.fold(query)
          return Array(items) if needle.empty?

          Array(items).select { |item| Decidim::Bih::Text.fold(item.fetch(:category)).include?(needle) }
        end

        def localize_items(items, locale:)
          return Array(items) if locale.to_s == "sr-Cyrl"

          Array(items).map do |item|
            item.merge(category: Decidim::Bih::Transliterator.to_latin(item.fetch(:category)))
          end
        end

        def number(value)
          ActiveSupport::NumberHelper.number_to_delimited(value, delimiter: ".", separator: ",")
        end

        def parking_value(street)
          tariff = ParkingZones::TARIFFS.fetch(street.fetch(:zone))
          "zone=#{street.fetch(:zone)}; #{tariff.fetch(:label)}; SMS #{tariff.fetch(:sms)}; #{tariff.fetch(:hourly)}"
        end
      end
    end
  end
end
