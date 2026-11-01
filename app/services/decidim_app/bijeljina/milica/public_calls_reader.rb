# frozen_string_literal: true

require "date"
require "time"
require "uri"
require_relative "../public_calls_preparation"
require_relative "read/base"

module DecidimApp
  module Bijeljina
    module Milica
      # Snapshot-only reader: neither missing preparation nor a stale/error
      # result can trigger HTTP or PDF fetching during a citizen turn.
      class PublicCallsReader
        include Read::Base

        MAX_FACTS = 8

        def initialize(organization:, source_checker: nil, area_matcher: nil)
          @organization = organization
          @store = source_checker || CityServiceSourceCheckStore.new
          @matcher = area_matcher || CityServiceAreaMatcher.new(organization:)
        end

        # Keep tenant, version, freshness and eligibility guards visible in source-read order.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def call(entities:, context:, locale:, location: nil, view: "active")
          return result("not_authorized", warnings: ["public_reads_not_allowed"]) unless authorized?(context)
          return result("unavailable", warnings: ["public_calls_source_not_configured"]) unless CityServiceSources.enabled?(PublicCallsPreparation::PARENT_SOURCE_KEY)

          return result("unavailable", warnings: ["unsupported_public_call_view"]) unless %w(active reviewed_timing).include?(view)

          entities = entities.transform_keys(&:to_s)
          if view == "reviewed_timing" && %w(date time_expression).any? { |field| entities[field].present? }
            return result("ambiguous", warnings: ["reviewed_call_timing_uses_trusted_today"])
          end
          resolution = @matcher.resolve(area_slug: entities["area_slug"], area_query: entities["area_query"], location:)
          return result(resolution.status == :ambiguous ? "ambiguous" : "empty", warnings: [resolution.warning]) unless resolution.status == :ok

          day = requested_public_call_day(entities, context.now)
          row = @store.snapshot(source_key: PublicCallsPreparation.snapshot_key(@organization))
          return result("unavailable", warnings: ["public_calls_not_prepared"]) unless row
          return result("unavailable", warnings: ["public_calls_source_version_changed"]) unless row.source_version == PublicCallsPreparation.version_for(store: @store)

          payload = row.check_payload
          return result("unavailable", warnings: ["public_calls_tenant_mismatch"]) unless payload["organization_id"].to_s == @organization.id.to_s
          return result("unreviewed", warnings: [payload["error_code"] || "public_calls_preparation_incomplete"]) unless %w(ok empty).include?(payload["status"])

          checked_at = Time.iso8601(payload.fetch("checked_at"))
          cadence = CityServiceSources.fetch(PublicCallsPreparation::PARENT_SOURCE_KEY).fetch(:scrape_cadence)
          max_age = CityServiceSources::HEALTH_MAX_AGES.fetch(cadence)
          return result("stale", checked_at:, warnings: ["public_calls_preparation_stale"]) unless checked_at <= context.now && checked_at >= context.now - max_age

          items = Array(payload["items"])
          scoped = items.select { |item| relevant_to_area?(item, resolution.areas) }
          unknown = scoped.count { |item| item["temporal_status"] == "unknown" || item["source_published_on"].blank? }
          eligible = scoped.select do |item|
            view == "reviewed_timing" ? reviewed_timing_relevant?(item, context.now) : temporally_relevant?(item, day, context.now)
          end
          eligible = filter_subject(eligible, entities)
          facts = eligible.sort_by { |item| [item.fetch("closes_on"), item.fetch("id")] }.first(MAX_FACTS).map do |item|
            value = fact(item, locale)
            view == "reviewed_timing" ? value.merge("active_status" => reviewed_timing_phase(item, context.now)) : value
          end
          warnings = %w(selected_calls_not_complete_inventory eligibility_must_be_checked_in_official_call)
          warnings << "reviewed_application_timing_not_live_status" if view == "reviewed_timing"
          warnings << "public_calls_with_unknown_dates_excluded" if unknown.positive?
          status = unknown.positive? ? "unreviewed" : "empty"
          status = "ok" if facts.any?
          result(status, facts:, checked_at:,
                         coverage: payload.fetch("coverage", {}).merge("organization_id" => @organization.id,
                                                                       "returned_items" => facts.size, "unknown_dates_excluded" => unknown),
                         validity: { "requested_date" => day.iso8601, "precision" => "date", "timezone" => TIME_ZONE }, warnings:)
        rescue Date::Error
          result("ambiguous", warnings: ["invalid_public_call_date"])
        rescue ArgumentError => e
          return result("ambiguous", warnings: ["unsupported_public_call_time"]) if e.message == "unsupported_public_call_time"

          result("unreviewed", warnings: ["public_call_snapshot_malformed"])
        rescue KeyError, TypeError
          result("unreviewed", warnings: ["public_call_snapshot_malformed"])
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        private

        # Snapshot policy over the shared day vocabulary: no expression means
        # today; anything beyond today, tomorrow or an ISO date is unsupported.
        def requested_public_call_day(entities, now)
          parsed = requested_day(entities, now:)
          return parsed.day if [:explicit, :today, :tomorrow].include?(parsed.kind)
          return local_date(now) if parsed.kind == :none

          raise ArgumentError, "unsupported_public_call_time"
        end

        # Publication, opening, closing date and closing clock are distinct evidence checks.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def temporally_relevant?(item, day, now)
          return false unless %w(bounded_window deadline_only).include?(item["temporal_status"])
          return false if item["source_published_on"].blank? || item["closes_on"].blank?

          published = Date.iso8601(item.fetch("source_published_on"))
          closing = Date.iso8601(item.fetch("closes_on"))
          opening = Date.iso8601(item["opens_on"]) if item["opens_on"].present?
          local_now = now.in_time_zone(TIME_ZONE)
          if item["closes_at"].present?
            clock = Time.iso8601(item["closes_at"])
            reference = day == local_now.to_date ? now : local_day_bounds(day).first
            return false unless clock > reference
          end
          published <= local_now.to_date && closing >= day && (!opening || opening <= day)
        rescue ArgumentError
          false
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # The fixed agricultural timing bridge may describe published future
        # or closed windows. It retains the same tenant/source-version/freshness
        # checks; cancelled, unknown and unpublished records stay withheld.
        # Default active-call selection above is unchanged.
        def reviewed_timing_relevant?(item, now)
          return false unless %w(bounded_window deadline_only).include?(item["temporal_status"])
          return false if item["source_published_on"].blank? || item["closes_on"].blank?

          published = Date.iso8601(item.fetch("source_published_on"))
          finish = Date.iso8601(item.fetch("closes_on"))
          start = Date.iso8601(item.fetch("opens_on")) if item["opens_on"].present?
          clock = Time.iso8601(item.fetch("closes_at")) if item["closes_at"].present?
          return false if clock && local_date(clock) != finish

          published <= local_date(now) && (!start || start <= finish)
        rescue ArgumentError
          false
        end

        def reviewed_timing_phase(item, now)
          day = local_date(now)
          return "not_yet_open" if item["opens_on"].present? && Date.iso8601(item.fetch("opens_on")) > day
          return "closed" if Date.iso8601(item.fetch("closes_on")) < day ||
                             (item["closes_at"].present? && Time.iso8601(item.fetch("closes_at")) <= now)

          item["opens_on"].present? ? "within_explicit_application_window" : "unknown_opening_date"
        end

        def relevant_to_area?(item, areas)
          return true if areas.empty?
          return true if item.dig("coverage", "geographic_scope") == "citywide_eligibility"

          Array(item.dig("coverage", "area_slugs")).intersect?(areas.map(&:slug))
        end

        def filter_subject(items, entities)
          query = fold([entities["query"], entities["category"]].compact.join(" "))
          subject = %w(stipend sport poljoprivred zaposlj subvenc konsultacij rasprav udruzenj).find { |word| query.include?(word) }
          return items unless subject

          items.select { |item| fold(item["title"]).include?(subject) }
        end

        def fact(item, locale)
          text = item.fetch("title")
          text += ": #{item["deadline_evidence"]}" if item["deadline_evidence"].present?
          text = localize(text, locale:)[0, 1_000]
          {
            "id" => item.fetch("id"), "kind" => item.fetch("kind"), "text" => text,
            "source_id" => PublicCallsPreparation::PARENT_SOURCE_KEY, "source_label" => CityServiceSources.fetch(PublicCallsPreparation::PARENT_SOURCE_KEY).fetch(:label),
            "source_url" => item.fetch("source_url"), "source_published_on" => item["source_published_on"],
            "coverage" => item.fetch("coverage"),
            "validity" => { "opens_on" => item["opens_on"], "closes_on" => item["closes_on"], "closes_at" => item["closes_at"],
                            "precision" => item["closes_at"] ? "datetime" : "date", "timezone" => TIME_ZONE },
            "active_status" => item["temporal_status"] == "bounded_window" ? "within_explicit_application_window" : "unknown_opening_date",
            "eligibility_evidence" => item["eligibility_evidence"], "eligibility_complete" => false,
            "provider_document_id" => item["provider_document_id"], "notice_type" => item["notice_type"],
            "assessment_period" => { "opens_on" => item["assessment_opens_on"], "closes_on" => item["assessment_closes_on"],
                                     "evidence" => item["assessment_period_evidence"] },
            "issuer" => item["issuer"], "document_role" => item["document_role"], "related_source_urls" => item["related_source_urls"],
            "required_documents_evidence" => item["required_documents_evidence"], "required_documents_complete" => false,
            "application_evidence" => item["application_evidence"], "application_url" => item["application_url"],
            "attachments" => item["attachments"], "warning_codes" => item.fetch("warnings", [])
          }
        end

        # A missing/disabled/malformed source is never replaced by a reference
        # municipality or a link containing credentials. Preparation separately
        # enforces article origin; this guards the optional listing metadata.
        def public_source_reference(source)
          value = source.fetch(:source_url).to_s
          uri = URI.parse(value)
          return unless value.length <= 2_000 && uri.scheme == "https" && uri.userinfo.nil? && uri.port == 443 && uri.host.present?

          { "id" => PublicCallsPreparation::PARENT_SOURCE_KEY, "label" => source.fetch(:label), "url" => value }
        rescue URI::InvalidURIError
          nil
        end

        # The shared read-port envelope with this reader's fixed parent source.
        def result(status, **values)
          source = CityServiceSources.find(PublicCallsPreparation::PARENT_SOURCE_KEY)
          reference = source && public_source_reference(source)
          super(status, source: reference, **values)
        end
      end
    end
  end
end
