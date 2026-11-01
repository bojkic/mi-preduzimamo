# frozen_string_literal: true

require "date"
require "pathname"

require_relative "city_service_sources"
require_relative "parking_zones"

module DecidimApp
  module Bijeljina
    # Source-specific, read-only checklist for refreshing checked-in city data.
    #
    # The refresh warm-up wrapper proves current snapshots still parse. This
    # plan is the operator gate before changing those snapshots: it names the
    # source file, source URL, metadata date, parser count, and exact tests for
    # each dataset without fetching upstream data or writing files.
    module CityDataRefreshPlan
      APP_ROOT = Rails.root.to_s

      DATASETS = [
        {
          key: "waste_schedule",
          label: "Waste schedule",
          source_file: -> { WasteSchedule::BUNDLED_TEXT_PATH },
          source_url: -> { WasteSchedule.schedule_url },
          metadata_date: -> { WasteSchedule::SOURCE_CAPTURED_ON },
          count: ->(_organization) { WasteSchedule.default.areas.size },
          detail: ->(_count) { WasteSchedule.coverage_detail },
          validation_tests: %w(
            test/services/decidim_app/bijeljina/waste_schedule_test.rb
            test/services/decidim/bih/city/waste_schedule_test.rb
            test/services/decidim_app/bijeljina/city_data_freshness_test.rb
          ),
          checklist: [
            "Preuzmite svoj pregledani raspored i sačuvajte izvor i datum provjere.",
            "Ažurirajte SOURCE_CAPTURED_ON i DATA_YEAR zajedno.",
            "Provjerite latinične i ćirilične nazive i jedan nepoznat rezultat."
          ]
        },
        {
          key: "parking_zones",
          label: "Parking zones",
          source_file: -> { Rails.root.join("app/services/decidim_app/bijeljina/parking_zones.rb").to_s },
          source_url: -> { ParkingZones.source_url },
          metadata_date: -> { ParkingZones::SOURCE_CAPTURED_ON },
          count: ->(_organization) { ParkingZones.street_count },
          detail: ->(_count) { ParkingZones.coverage_detail },
          validation_tests: %w(
            test/services/decidim_app/bijeljina/parking_zones_test.rb
            test/services/decidim_app/bijeljina/live_service_answers_test.rb
            test/services/decidim_app/bijeljina/city_data_freshness_test.rb
          ),
          checklist: [
            "Pregledajte sopstvenu zvaničnu tarifu, zone i mapu parkinga.",
            "Ažurirajte SOURCE_CAPTURED_ON poslije provjere.",
            "Provjerite dvije poznate ulice i jednu nepoznatu; ne pretpostavljajte zonu iz koordinata."
          ]
        },
        {
          key: "budget_snapshot",
          label: "Budget snapshot",
          source_file: -> { Budget::BUNDLED_TEXT_PATH },
          source_url: -> { Budget.source_url },
          metadata_date: -> { Budget::SOURCE_CAPTURED_ON },
          count: ->(_organization) { Budget.default.line_items.size },
          detail: ->(count) { "source_year=#{Budget::YEAR} line_items=#{count}" },
          validation_tests: %w(
            test/services/decidim_app/bijeljina/budget_test.rb
            test/services/decidim/bih/city/budget_test.rb
            test/services/decidim_app/bijeljina/city_data_freshness_test.rb
          ),
          checklist: [
            "Prepišite samo pregledane budžetske tabele; ne izmišljajte ukupne iznose.",
            "Ažurirajte SOURCE_CAPTURED_ON i YEAR zajedno.",
            "Provjerite napomenu uz ukupni iznos i jednu poznatu kategoriju."
          ]
        },
        {
          key: "gazette_index",
          label: "Gazette index",
          source_file: -> { Rails.root.join("app/services/decidim_app/bijeljina/gazette_data.rb").to_s },
          source_url: -> { Gazette.source_url },
          metadata_date: -> { GazetteData::SOURCE_CAPTURED_ON },
          count: ->(_organization) { Gazette.index.all.size },
          detail: ->(count) { "captured_issues=#{count}" },
          validation_tests: %w(
            test/services/decidim_app/bijeljina/gazette_test.rb
            test/services/decidim/bih/city/gazette_index_test.rb
            test/services/decidim_app/bijeljina/city_data_freshness_test.rb
          ),
          checklist: [
            "Zabilježite stvarni naslov, broj, datum i PDF URL svog zvaničnog glasnika.",
            "Ostavite summary praznim ako nije izveden iz pregledanog PDF-a.",
            "Ažurirajte SOURCE_CAPTURED_ON poslije provjere arhive."
          ]
        },
        {
          key: "service_directory",
          label: "Service directory",
          source_file: -> { Rails.root.join("app/services/decidim_app/bijeljina/city_services_data.rb").to_s },
          source_url: -> {},
          metadata_date: -> { CityServicesData::SOURCE_VERIFIED_ON },
          count: ->(_organization) { CityDirectory.all.size },
          detail: ->(count) { CityServicesData.coverage_detail(count) },
          validation_tests: %w(
            test/services/decidim_app/bijeljina/city_directory_test.rb
            test/services/decidim/bih/city/service_directory_test.rb
            test/services/decidim_app/bijeljina/city_data_freshness_test.rb
          ),
          checklist: [
            "Provjerite svaki odgovor prema njegovom navedenom javnom izvoru.",
            "Čuvajte kratke odgovore i citate bez privatnih operaterskih bilješki.",
            "Ažurirajte SOURCE_VERIFIED_ON poslije provjere kontakata."
          ]
        },
        {
          key: "service_alert_sources",
          label: "Service and alert sources",
          source_file: -> { Rails.root.join("app/services/decidim_app/bijeljina/city_service_sources.rb").to_s },
          source_url: -> {},
          metadata_date: -> { CityServiceSources::SOURCE_REVIEWED_ON },
          count: ->(_organization) { CityServiceSources.all.size },
          detail: ->(_count) { CityServiceSources.summary_detail },
          validation_tests: %w(
            test/services/decidim_app/bijeljina/city_service_sources_test.rb
            test/services/decidim_app/bijeljina/city_service_source_probe_test.rb
            test/services/decidim_app/bijeljina/city_data_freshness_test.rb
            test/services/decidim_app/bijeljina/city_data_refresh_plan_test.rb
          ),
          checklist: [
            "Rutinske informacije ostaju na upit dok izvor nije izričito odobren za obavještenja.",
            "Za ciljanu dostavu provjerite oblast ili postojeće posebno pravilo za hitnu objavu.",
            "Pregledajte konfiguraciju komandom script/mi_city_service_viber_readiness_smoke; to nije dokaz dostupnosti izvora ili dostave.",
            "Dostupnost svojih izvora provjerite zasebno; kanale uključite poslije provjera parsera, duplikata, ograničenja i pregleda objava."
          ]
        },
        {
          key: "local_areas",
          label: "Local areas",
          source_file: -> { Rails.root.join("docs/INSTALACIJA.md").to_s },
          source_url: -> {},
          metadata_date: -> {},
          count: lambda { |organization|
            next nil unless organization

            Decidim::Bih::LocalArea.where(decidim_organization_id: organization.id).count
          },
          detail: ->(count) { "current_areas=#{count || "unknown"}" },
          validation_tests: %w(
            test/services/decidim/bih/geo/integrity_check_test.rb
            test/services/decidim/bih/geo/relations_computer_test.rb
            test/tasks/synthetic_community_import_test.rb
            test/tasks/komsiluk_import_flat_test.rb
            test/services/decidim_app/bijeljina/city_data_freshness_test.rb
          ),
          checklist: [
            "Prije uvoza provjerite svoj GeoJSON prema docs/INSTALACIJA.md.",
            "Sačuvajte odvojene identitete i veze MZ/komšiluka.",
            "Poslije uvoza provjerite administraciju i pregled u browseru."
          ]
        }
      ].freeze

      class << self
        def rows(organization: nil)
          DATASETS.map { |dataset| build_row(dataset, organization:) }
        end

        def validation_command(row)
          "bin/rails test #{row.fetch(:validation_tests).join(" ")}"
        end

        private

        def build_row(dataset, organization:)
          source_file = value_for(dataset.fetch(:source_file), organization)
          metadata_date = value_for(dataset.fetch(:metadata_date), organization)
          count = value_for(dataset.fetch(:count), organization)
          status = status_for(source_file:, metadata_date:, count:, requires_organization: dataset.fetch(:key) == "local_areas", organization:)

          {
            key: dataset.fetch(:key),
            label: dataset_label(dataset),
            status:,
            source_file: relative_path(source_file),
            source_file_present: source_file.present? && File.exist?(source_file),
            source_url: value_for(dataset.fetch(:source_url), organization),
            metadata_date: metadata_date&.iso8601,
            count:,
            detail: dataset.fetch(:detail).call(count),
            validation_tests: dataset.fetch(:validation_tests),
            checklist: dataset.fetch(:checklist)
          }
        rescue StandardError => e
          {
            key: dataset.fetch(:key),
            label: dataset_label(dataset),
            status: "fail",
            source_file: nil,
            source_file_present: false,
            source_url: nil,
            metadata_date: nil,
            count: nil,
            detail: sanitize("#{e.class}: #{e.message}"),
            validation_tests: dataset.fetch(:validation_tests),
            checklist: dataset.fetch(:checklist)
          }
        end

        def status_for(source_file:, metadata_date:, count:, requires_organization:, organization:)
          return "warn" if requires_organization && organization.blank?
          return "fail" if source_file.blank? || !File.exist?(source_file)
          return "warn" if metadata_date.blank? && !requires_organization
          return "warn" if count.nil?
          return "fail" unless count.to_i.positive?

          "ok"
        end

        def dataset_label(dataset)
          I18n.t("decidim_app.city_data.datasets.#{dataset.fetch(:key)}", default: dataset.fetch(:label))
        end

        def value_for(value, organization)
          value.respond_to?(:call) ? value.call(organization) : value
        rescue ArgumentError
          value.call
        end

        def relative_path(path)
          path = path.to_s
          return path if path.blank?

          Pathname.new(path).relative_path_from(Pathname.new(APP_ROOT)).to_s
        rescue ArgumentError
          path
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
