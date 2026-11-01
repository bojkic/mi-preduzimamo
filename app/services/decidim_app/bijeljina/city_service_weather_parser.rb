# frozen_string_literal: true

require_relative "weather_region_configuration"

module DecidimApp
  module Bijeljina
    # CAP validates identity, locality and offset-bearing intervals before an
    # event is proposed. Regional warnings always require a human board decision.
    class CityServiceWeatherParser
      SOURCE_KEY = "weather_warnings"
      PARSER_VERSION = "weather-event-community-v1"
      attr_reader :review_identity

      def initialize(organization:, source: CityServiceSources.fetch(SOURCE_KEY))
        @source = source
        @organization = organization
      end

      # Owner decision 23.09.2026: a yellow warning is not worth a board post or
      # an operator's bell. CAP severity carries the colour: Moderate is yellow,
      # Severe orange, Extreme red. Milica's weather answers come from the
      # collector's own check of this feed and still see every level.
      BOARD_SEVERITIES = %w(Severe Extreme).freeze
      # Compatibility constant contains no inherited place or coverage claim.
      # The selected review supplies the label, not a provider's region name.
      AREA_TEXT = "".freeze

      def call(html:, source_url: @source.fetch(:source_url), fetched_at: Time.current, region: nil)
        @review_identity = nil
        day = fetched_at.in_time_zone("Europe/Sarajevo").to_date
        region = WeatherRegionConfiguration.for_source(source_url:, day:) if region.nil?
        WeatherRegionConfiguration.assert_current!(region, source_url:, day:, organization_host: @organization.host)
        unless region.bound_to?(organization_host: @organization.host, source_url:)
          raise CityServiceNoticeCollector::ParserError, "Weather region review does not match this organization", cause: nil
        end
        @review_identity = region.identity
        WeatherCapFeed.call(body: html, url: source_url, now: fetched_at, region:).filter_map do |notice|
          metadata = notice.fetch(:metadata)
          next unless BOARD_SEVERITIES.include?(metadata["provider_severity"])

          title = citizen_title(metadata)
          body = citizen_body(title, metadata)
          fingerprint = Digest::SHA256.hexdigest([metadata["provider_sender"], metadata["provider_identifier"], metadata["provider_event"], region.identity].join("|"))[0, 24]
          ElectricityOutageParser::Event.new(
            source_key: SOURCE_KEY, source_label: @source.fetch(:label), provider: @source.fetch(:provider),
            source_url: notice.fetch(:url), source_fingerprint: fingerprint, source_occurrence_id: fingerprint,
            content_version: Digest::SHA256.hexdigest(notice.to_json), parser_version: PARSER_VERSION,
            source_published_at: Time.iso8601(metadata.fetch("source_published_at")), fetched_at:,
            lifecycle: metadata["temporal_status"] == "upcoming" ? "scheduled" : "ongoing",
            event_type: "severe_weather", severity: metadata["provider_severity"] == "Extreme" ? "emergency" : "safety",
            title: title.truncate(120), summary: body.truncate(500),
            affected_text: region.display_label, targeting_level: "unknown", affected_area_slugs: [],
            recommended_action: metadata["provider_instruction"].presence || "Pratite zvanično upozorenje MeteoAlarm-a.",
            viber_text: body.truncate(500), starts_at: Time.iso8601(metadata.fetch("starts_at")),
            ends_at: Time.iso8601(metadata.fetch("ends_at")), confidence: 0.8,
            classifier_reasons: %w(validated_cap_region human_regional_target_review review_identity_bound),
            extraction_metadata: metadata.merge("service" => "weather", "complete" => true, "requires_human_review" => true,
                                                "provider_headline" => notice.fetch(:title), "source_quotation" => notice.fetch(:body),
                                                "coverage" => { "complete" => false, "reason" => "regional_warning_requires_review" })
          )
        end
      rescue WeatherRegionConfiguration::InvalidConfiguration
        raise CityServiceNoticeCollector::ParserError, "Weather region review is not configured or eligible", cause: nil
      end

      private

      # "Vjetar narandžasto Upozorenje" is the provider's event name, carrying
      # the colour; the provider's headline adds only the region.
      def citizen_title(metadata)
        event = metadata["provider_event"].to_s.sub(/\bUpozorenje\z/, "upozorenje")
        "#{event} – #{metadata.fetch('reviewed_region_label')} (#{metadata.fetch('relevant_city')})"
      end

      def citizen_body(title, metadata)
        zone = Time.find_zone!("Europe/Sarajevo")
        from = zone.parse(metadata.fetch("starts_at"))
        to = zone.parse(metadata.fetch("ends_at"))
        window = "Od #{from.strftime("%d.%m. u %H:%M")} do #{to.strftime("%d.%m. u %H:%M")}."
        [title, metadata["provider_description"], window, metadata["provider_instruction"]]
          .map { |part| ElectricityOutageParser.sentence(part) if part.present? }.compact.join(" ")
      end
    end
  end
end
