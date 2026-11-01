# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "nokogiri"
require_relative "weather_region_configuration"

module DecidimApp
  module Bijeljina
    # MeteoAlarm's country CAP JSON. A validated empty list describes this feed,
    # never the absence of hazards. Atom remains a compatibility parser, but its
    # empty legacy response cannot establish the country's warning coverage.
    module WeatherCapFeed
      VERSION = "community-region-v1"
      URL = "https://feeds.meteoalarm.org/api/v1/warnings/feeds-bosnia-herzegovina"
      CITATION_URL = "https://www.meteoalarm.org/en/live/region/BA"
      LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
      LANGUAGES = %w(sr sr-RS sr-Latn bs hr en).freeze
      MAX_ALERTS = 1000
      MAX_INFO = 30

      module_function

      def call(body:, url:, now:, region: nil)
        day = now.in_time_zone("Europe/Sarajevo").to_date
        region = WeatherRegionConfiguration.for_source(source_url: url, day:) if region.nil?
        unless region.is_a?(WeatherRegionConfiguration) && region.valid_on?(day) &&
               region.bound_to?(organization_host: region.organization_host, source_url: url)
          invalid!("Weather region review is not configured or eligible")
        end
        alerts = feed_rows(body).filter_map { |row| validated_alert(row, now:) }.uniq { |alert| identity(alert) }
        replaced = alerts.flat_map { |alert| replaced_identities(alert, now:) }
        active = alerts.reject { |alert| replaced.include?(identity(alert)) }
        active.select { |alert| %w(Alert Update).include?(alert["msgType"]) }.flat_map do |alert|
          local_information(alert, region:).filter_map { |info| notice(alert, info, url:, now:, region:) }
        end
      rescue WeatherRegionConfiguration::InvalidConfiguration
        raise CityServiceNoticeCollector::ParserError, "Weather region review is not configured or eligible", cause: nil
      end

      def feed_rows(body)
        payload = JSON.parse(body)
        rows = payload.is_a?(Hash) && payload["warnings"]
        invalid!("unrecognized CAP feed") unless rows.is_a?(Array) && rows.size <= MAX_ALERTS
        rows
      rescue JSON::ParserError
        invalid!("invalid CAP JSON")
      end

      def validated_alert(row, now:)
        alert = row.is_a?(Hash) && row["alert"]
        invalid!("missing CAP alert") unless alert.is_a?(Hash)
        invalid!("missing CAP status or scope") unless %w(status scope).all? { |key| alert[key].is_a?(String) }
        return unless alert["status"] == "Actual" && alert["scope"] == "Public"

        validate_identity!(alert, now:)
        validate_information!(alert["info"]) if %w(Alert Update).include?(alert["msgType"])
        alert
      end

      def validate_identity!(alert, now:)
        invalid!("missing CAP identity") unless %w(sender identifier).all? { |key| alert[key].is_a?(String) && !alert[key].strip.empty? }
        invalid!("future CAP publication") if timestamp(alert["sent"]) > now
        invalid!("unrecognized CAP message type") unless %w(Alert Update Cancel Ack Error).include?(alert["msgType"])
      end

      def validate_information!(info)
        invalid!("missing CAP information") unless info.is_a?(Array) && info.any? && info.size <= MAX_INFO && info.all? { |item| item.is_a?(Hash) }
      end

      # CAP references identify the exact sender, identifier and sent instant.
      # A cancellation may have no info block. A future-effective update cannot
      # withdraw a warning that still applies before that update takes effect.
      def replaced_identities(alert, now:)
        return [] unless %w(Update Cancel).include?(alert["msgType"])
        return [] if future_update?(alert, now:)

        references = alert["references"]
        return [] if references.nil? || references == ""

        invalid!("invalid CAP references") unless references.is_a?(String)
        references.split.map { |reference| reference_identity(reference) }
      end

      def reference_identity(reference)
        sender, identifier, sent, extra = reference.split(",", -1)
        invalid!("invalid CAP reference identity") if sender.to_s.empty? || identifier.to_s.empty? || extra
        [sender, identifier, timestamp(sent).iso8601]
      end

      def future_update?(alert, now:)
        alert["msgType"] == "Update" && alert["info"].all? { |info| timestamp(info["effective"] || alert["sent"]) > now }
      end

      def identity(alert)
        [alert.fetch("sender"), alert.fetch("identifier"), timestamp(alert.fetch("sent")).iso8601]
      end

      # Prefer one supplied local language, without counting translations as
      # independent alerts. Multiple hazards in that language remain separate.
      def local_information(alert, region:)
        info = alert.fetch("info").select { |item| local_area(item, region:) }
        language = info.map { |item| item["language"] || "en-US" }.min_by { |value| language_priority(value) }
        info.select { |item| (item["language"] || "en-US") == language }
            .uniq { |item| item.values_at("event", "onset", "expires", "severity") }
      end

      def language_priority(value)
        invalid!("invalid CAP language") unless value.is_a?(String)
        [LANGUAGES.index(value) || LANGUAGES.index(value.split("-").first) || LANGUAGES.length, value]
      end

      def local_area(info, region:)
        areas = info["area"]
        invalid!("missing CAP area") unless areas.is_a?(Array) && areas.all? { |area| area.is_a?(Hash) }
        areas.find { |area| local_geocode?(area["geocode"], region:) }
      end

      def local_geocode?(codes, region:)
        return false if codes.nil?

        invalid!("invalid CAP geocode") unless codes.is_a?(Array) && codes.all? { |code| code.is_a?(Hash) }
        codes.any? { |code| code["valueName"] == "EMMA_ID" && code["value"] == region.provider_area_code }
      end

      def notice(alert, info, url:, now:, region:)
        window = warning_window(alert, info)
        return if window[:expires] <= now || window[:effective] > now

        area = local_area(info, region:)
        metadata = CityServiceEvidenceParser.base_metadata("official_warning", published: window[:published], area: area["areaDesc"], geographic: "source_declared_region")
        metadata.merge!(warning_metadata(alert, info, window:, now:, region:))
        title = clean(info["headline"] || info["event"])
        invalid!("missing CAP event") if title.empty? || clean(info["event"]).empty?
        body = warning_body(info, area:, window:)
        token = Digest::SHA256.hexdigest([*identity(alert), info["event"], window[:onset].iso8601, window[:expires].iso8601].join("|"))[0, 24]
        { title:, body:, url: "#{url}#cap-#{token}", metadata: metadata.merge("acquisition_url" => url) }
      end

      def warning_window(alert, info)
        published = timestamp(alert.fetch("sent"))
        effective = timestamp(info["effective"] || alert.fetch("sent"))
        onset = timestamp(info["onset"] || info["effective"] || alert.fetch("sent"))
        expires = timestamp(info["expires"])
        invalid!("invalid CAP interval") unless expires > onset && expires > effective
        { published:, effective:, onset:, expires: }
      end

      def warning_body(info, area:, window:)
        values = [info["event"], area["areaDesc"], "#{window[:onset].iso8601} – #{window[:expires].iso8601}", info["description"], info["instruction"]]
        values.map { |value| clean(value) }.reject(&:empty?).join("; ")
      end

      def warning_metadata(alert, info, window:, now:, region:)
        {
          "starts_at" => window[:onset].iso8601, "ends_at" => window[:expires].iso8601, "effective_at" => window[:effective].iso8601,
          "temporal_status" => window[:onset] > now ? "upcoming" : "active", "provider_identifier" => alert["identifier"],
          "provider_sender" => alert["sender"], "provider_severity" => info["severity"], "provider_event" => clean(info["event"]),
          "provider_language" => info["language"] || "en-US", "provider_message_type" => alert["msgType"],
          "provider_description" => clean(info["description"]),
          "provider_instruction" => clean(info["instruction"]),
          "source_format" => "meteoalarm_cap_json", "cap_parser_version" => VERSION,
          "provider_url" => CITATION_URL, "license_url" => LICENSE_URL, "attribution" => "MeteoAlarm / #{clean(info["senderName"] || alert["sender"])}",
          "transformation" => "Selected language and region; source text normalized; source validity and attribution retained"
        }.merge(region.metadata)
      end

      # Explicit offsets are mandatory; server time must never fill an unknown
      # provider clock. CAP effective/onset default to sent/effective per CAP.
      def timestamp(value)
        invalid!("missing CAP timestamp offset") unless value.is_a?(String) && value.match?(/T.*(?:Z|[+-]\d{2}:\d{2})\z/)
        Time.iso8601(value).utc
      rescue ArgumentError
        invalid!("invalid CAP timestamp")
      end

      def clean(value)
        Nokogiri::HTML.fragment(value.to_s).text.gsub(/[[:space:]\u00a0]+/, " ").strip
      end

      def invalid!(message)
        raise CityServiceNoticeCollector::ParserError, message
      end
    end
  end
end
