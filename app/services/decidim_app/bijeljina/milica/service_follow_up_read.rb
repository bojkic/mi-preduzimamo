# frozen_string_literal: true

require "date"

module DecidimApp
  module Bijeljina
    module Milica
      # Reread the public directory by stable identity. These service entries
      # have reviewed official pages. Optional explicit role facts remain
      # separately scoped/cited; never extract contacts or payment shortcodes
      # from free prose, tariffs or an unrelated directory subject.
      class ServiceFollowUpRead
        SOURCE_ID = /\Acity_services:([a-z][a-z0-9_]{0,79})\z/
        DETAIL_FIELDS = %w(phone email address hours form).freeze
        DETAIL_SUBJECTS = {
          "gradjevinske_dozvole_legalizacija" => "building_permit_office",
          "socijalna_zastita" => "social_work_office",
          "otpad" => "waste_service",
          "vodovod_servis" => "water_service"
        }.freeze

        def initialize(directory:, allowed_keys:, organization_id:, source_url_validator:)
          @directory = directory
          @allowed_keys = allowed_keys.map(&:to_s).freeze
          @organization_id = organization_id
          @source_url_validator = source_url_validator
        end

        def call(source_id:, focus:, now:, locale:, details: [])
          match = source_id.is_a?(String) && SOURCE_ID.match(source_id)
          return unavailable("unsupported_service_follow_up") unless %w(contact website).include?(focus) && match && @allowed_keys.include?(match[1])

          unless details.is_a?(Array) && details.size <= DETAIL_FIELDS.size && details.all? { |field| DETAIL_FIELDS.include?(field) }
            return unavailable("unsupported_service_details")
          end
          details = details.uniq

          entry = @directory.find(match[1])
          return unavailable("reviewed_service_not_found") unless reviewed_entry?(entry, match[1], now)

          url = @source_url_validator.call(entry.fetch(:source_url))
          return unavailable("reviewed_service_page_unavailable") unless url

          coverage = { "organization_id" => @organization_id, "scope" => "reviewed_static_directory", "focus" => focus, "contact_available" => false }
          warnings = ["snapshot_not_live_status"]
          warnings << "reviewed_service_contact_unavailable" if focus == "contact"
          fact = directory_fact(entry, source_id:, url:, focus:, locale:, coverage:, warnings:)
          extra = detail_facts(entry, fields: details, source_id:, now:, locale:)
          if details.any?
            coverage["requested_detail_fields"] = details
            coverage["available_detail_fields"] = extra.map { |row| row.fetch("detail_field") }.uniq
            coverage["unavailable_detail_fields"] = details - coverage.fetch("available_detail_fields")
          end
          { status: "ok", facts: [fact, *extra], source: { "id" => source_id, "label" => fact.fetch("source_label"), "url" => url }, coverage:,
            validity: { "reviewed_on" => entry.fetch(:source_checked_on), "live_status" => false }, warnings: }
        end

        private

        def detail_facts(entry, fields:, source_id:, now:, locale:)
          subject_id = DETAIL_SUBJECTS[entry.fetch(:key).to_s]
          return [] if fields.empty? || !subject_id

          groups = fields.map do |field|
            DirectoryServiceFacts.for_subject(entry:, subject_id:, predicate: field, now:).filter_map do |row|
              url = @source_url_validator.call(row.fetch(:source_url))
              next unless url == row.fetch(:source_url)

              text = Decidim::Bih::Transliterator.localize(row.fetch(:text).to_s, locale:)[0, 1_000]
              next if text.strip.empty?

              { "id" => row.fetch(:id), "kind" => "service_directory", "text" => text,
                "detail_field" => field, "subject_id" => subject_id, "source_id" => source_id,
                "source_url" => url, "observed_at" => row.fetch(:source_checked_on),
                "coverage" => { "organization_id" => @organization_id, "scope" => "reviewed_static_directory" },
                "warning_codes" => ["snapshot_not_live_status"],
                "provenance" => [row.slice(:logical_id, :fact_revision, :document_id, :publisher_id,
                                           :source_document_sha256, :source_locator).transform_keys(&:to_s)] }
            end
          end
          groups.each_with_object([]) do |group, collected|
            unique = group.uniq { |row| row.fetch("id") }
            next if collected.size + unique.size > 7

            collected.concat(unique)
          end
        end

        def reviewed_entry?(entry, key, now)
          return false unless entry.is_a?(Hash) && entry[:key].to_s == key
          return false unless entry.values_at(:record_kind, :verification_scope) == %w(service_guidance source_guidance)
          return false unless entry[:source_checked_on].is_a?(String) && /\A\d{4}-\d{2}-\d{2}\z/.match?(entry[:source_checked_on])

          Date.iso8601(entry.fetch(:source_checked_on)) <= now.to_date
        rescue Date::Error
          false
        end

        # rubocop:disable Metrics/ParameterLists
        def directory_fact(entry, source_id:, url:, focus:, locale:, coverage:, warnings:)
          copy = focus == "contact" ? "service_contact_unavailable" : "service_official_page"
          text = I18n.t("decidim.bih.dialogue.#{copy}", title: entry.fetch(:title), locale:, raise: true)
          { "id" => "service:#{entry.fetch(:key)}", "kind" => "service_directory",
            "text" => Decidim::Bih::Transliterator.localize(text, locale:),
            "source_id" => source_id, "source_label" => entry.fetch(:title), "source_url" => url,
            "observed_at" => entry.fetch(:source_checked_on), "coverage" => coverage, "warning_codes" => warnings,
            "provenance" => Array(entry[:facts]).first(8).map { |fact| fact.slice(:id, :kind, :source_checked_on, :source_url).transform_keys(&:to_s) } }
        end
        # rubocop:enable Metrics/ParameterLists

        def unavailable(warning)
          { status: "unavailable", warnings: [warning] }
        end
      end
    end
  end
end
