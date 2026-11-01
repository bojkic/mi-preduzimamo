# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # Adds source-owned public labels, not inferred physical venues or new
      # occurrences. Called only after the catalog's visibility/time/area query.
      module VolunteerActivityFact
        TIME_ZONE = "Europe/Sarajevo"
        MAX_TEXT = 1_000
        ONLINE_LABELS = %w(online onlajn).freeze

        module_function

        def call(fact:, record:, locale:)
          raise ArgumentError, "Expected public volunteer fact" unless record.id.is_a?(Integer) && record.id.positive? && fact["id"] == "volunteer_opportunity:#{record.id}"

          online = ONLINE_LABELS.include?(Decidim::Bih::Text.fold(fact["location"]))
          series = public_series(record)
          long_interval = record.starts_at && record.ends_at ? record.ends_at - record.starts_at > 24.hours : false
          details = public_details(fact, record, locale:, online:, long_interval:)
          fragment = "volunteer-opportunity-#{record.id}"
          fact.merge(
            "text" => bounded_text(fact.fetch("text"), details),
            "destination" => "#{fact.fetch("destination")}##{fragment}", "source_url" => "#{fact.fetch("source_url")}##{fragment}"
          ).merge(
            "activity_location" => { "participation_mode" => online ? "online" : "unspecified", "source_label" => fact["location"],
                                     "physical_area_verified" => false },
            "series" => series,
            "schedule" => fact.fetch("schedule").merge("kind" => schedule_kind(record, fact.fetch("schedule"))),
            "validity" => fact.fetch("validity").merge("starts_at" => local_time(record.starts_at), "ends_at" => local_time(record.ends_at),
                                                       "timezone" => TIME_ZONE, "long_interval" => long_interval),
            "warning_codes" => Array(fact["warning_codes"]) + (long_interval ? ["volunteer_long_interval_requires_confirmation"] : [])
          )
        end

        def public_series(record)
          return unless record.series? && record.series_position.is_a?(Integer) && record.series_total.is_a?(Integer)
          return unless record.series_position.positive? && record.series_position <= record.series_total && record.series_total > 1

          { "position" => record.series_position, "total" => record.series_total }
        end

        # Keep every fact and its evidence identity. Only adjacent facts with
        # the same source-owned series and identical common content share prose;
        # filtered-out shifts are never recreated or described as present.
        def compact_series(facts:, records:, locale:)
          previous = nil
          facts.zip(records).map do |fact, record|
            key = series_content_key(fact, record)
            compact = key && key == previous
            previous = key
            compact ? fact.merge("text" => compact_shift_text(fact, record, locale)) : fact
          end
        end

        def series_content_key(fact, record)
          return unless record && public_series(record) && record.series_key.is_a?(String) && !record.series_key.strip.empty?

          [record.series_key, record.partner_profile_id, record.title, record.description, fact["source_id"], fact["source_label"],
           fact["location"], fact["requirements"], fact["category"],
           fact["opportunity_kind"], fact["coverage"], fact["schedule"], fact["warning_codes"], fact.dig("series", "total")]
        end

        def compact_shift_text(fact, record, locale)
          title = fact.fetch("title")
          title = "#{title[0, 48]}…" if title.length > 48
          series = fact.fetch("series")
          shift = I18n.t("decidim.bih.volunteer.index.series_position", locale:, position: series.fetch("position"), total: series.fetch("total"))
          [title, [shift, fact["location"]].reject { |value| value.to_s.empty? }.join(" · "), public_period(record, locale)].compact.join("\n")[0, MAX_TEXT]
        end

        def schedule_kind(record, schedule)
          return "dated_interval" if record.starts_at || record.ends_at

          %w(day_keys month_keys).all? { |key| schedule[key].is_a?(Array) && schedule[key].any? } ? "recurring_availability" : "unknown"
        end

        def public_details(fact, record, locale:, online:, long_interval:)
          lines = []
          series = public_series(record)
          location = fact["location"].to_s[0, 240]
          lines << I18n.t("decidim_app.milica.activity.location", locale:, location:) unless location.empty?
          lines << I18n.t("decidim.bih.volunteer.index.series_position", locale:, position: series["position"], total: series["total"]) if series
          lines << public_period(record, locale) if record.starts_at && record.ends_at
          lines << I18n.t("decidim_app.milica.activity.online_notice", locale:) if online
          lines << I18n.t("decidim_app.milica.activity.long_interval_notice", locale:) if long_interval
          lines.join("\n")
        end

        def public_period(record, locale)
          return unless record.starts_at && record.ends_at

          I18n.t("decidim_app.milica.activity.period", locale:,
                                                       from: record.starts_at.in_time_zone(TIME_ZONE).strftime("%d.%m.%Y. %H:%M"),
                                                       through: record.ends_at.in_time_zone(TIME_ZONE).strftime("%d.%m.%Y. %H:%M"))
        end

        def bounded_text(body, details)
          return body if details.empty?

          [body[0, [MAX_TEXT - details.length - 1, 0].max], details].reject(&:empty?).join("\n")[0, MAX_TEXT]
        end

        def local_time(time)
          time&.in_time_zone(TIME_ZONE)&.iso8601
        end
      end
    end
  end
end
