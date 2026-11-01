# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Code support is separate from source readiness and channel activation.
    # No capability row certifies delivery credentials or publishes an alert.
    module CityServiceCapabilities
      CHANNELS = %w(web viber_bot viber_business whatsapp messenger instagram).freeze
      EVENT_TOPICS = { "electricity_outages" => "electricity", "water_service" => "water",
                       "heating_service" => "heating", "city_official_notices" => "neighborhood" }.freeze
      STATIC_TOPICS = { "waste_schedule" => "waste", "public_transport" => "transport" }.freeze
      LEGACY_READERS = %w(water_levels air_quality air_quality_realtime public_transport sistem48_public_archive police_service_information).freeze
      # Reader families that are neither a scraped source nor a directory
      # card: the parking zone map, the neighbourhood read, the public-calls
      # reader and the directory keyword search behind the generic bucket.
      READER_TOPICS = %w(parking neighborhood public_calls city_service).freeze

      module_function

      # Dialogue topics Milica can answer from a typed reader, a reviewed
      # service-event feed, a reviewed source family, a catalogue family or a
      # directory card. The engine's Procedures::CityService asks this BEFORE
      # collecting any detail: a topic outside the set is refused with a next
      # step, never asked for a day or a place.
      def supported?(topic)
        supported_topics.include?(topic.to_s)
      end

      def supported_topics
        (EVENT_TOPICS.values + STATIC_TOPICS.values + CityServiceSources::TOPIC_SOURCE_KEYS.keys +
          Milica::ReferenceRead::TOPICS + Milica::FoundationRead::TOPICS + Milica::PlatformCatalogRead::TOPICS +
          READER_TOPICS + directory_topics).uniq.sort.freeze
      end

      # Topics with a reviewed directory card: the read port's topic-keyed
      # entries plus every card that names its topic(s). A contact card added
      # for a new topic must carry +topic:+ (or +topics:+) to count here —
      # keyword matching alone cannot tell the gate the topic is covered.
      def directory_topics(entries: CityServicesData::ENTRIES)
        marked = entries.flat_map { |entry| Array(entry[:topics] || entry[:topic]) }.map(&:to_s)
        (Milica::ReadPort::DIRECTORY_TOPIC_KEYS.keys + marked).uniq
      end

      # The next step offered with an unsupported-topic reply. Reviewed
      # contacts live in the directory, and a card there makes its topic
      # supported, so whatever is still unsupported is pointed at the guide.
      def next_step_for(_topic)
        Decidim::Bih.public_path("vodic")
      end

      def rows(checks: [])
        checks = Array(checks).index_by(&:source_key)
        CityServiceSources.all.map { |source| source_row(source, check: checks[source.fetch(:key)]) }
      end

      def source_row(source, check:)
        key = source.fetch(:key)
        topic = topic_for(key)
        {
          source_key: key, provider: source.fetch(:provider), source_url: source.fetch(:source_url),
          refresh_owner: "Bijeljina city-data operator", scrape_cadence: source.fetch(:scrape_cadence),
          typed_topic: topic, typed_reader: reader_for(key), read_contracts: read_contracts(key, topic),
          legacy_reader: LEGACY_READERS.include?(key) ? "LiveServiceAnswers" : "source_specific_guidance_requires_route_verification",
          source_status: check&.status&.to_s || "not_checked", checked_at: check&.checked_at&.iso8601,
          prepared_notice_count: check ? Array(check.notices).size : nil,
          notice_count_scope: "supplied_check_only_not_published_events",
          semantic_profile: CityServiceSourceProfiles.fetch(key),
          evidence_health: CityServiceSourceHealth.call(source_key: key, check:),
          channels: CHANNELS.index_with { |channel| channel_support(channel) },
          publication_required: EVENT_TOPICS.has_key?(key), automatic_outbound: false
        }
      end

      def topic_for(key)
        EVENT_TOPICS[key] || STATIC_TOPICS[key] || CityServiceSources::TOPIC_SOURCE_KEYS.find { |_name, keys| keys.include?(key) }&.first
      end

      def read_contracts(key, topic)
        contracts = [{ topic:, reader: reader_for(key), publication_required: EVENT_TOPICS.has_key?(key) }]
        contracts << { topic: "public_calls", reader: "prepared_public_calls", publication_required: false } if key == "city_official_notices"
        contracts
      end

      def reader_for(key)
        return "reviewed_event_feed" if EVENT_TOPICS.has_key?(key)
        return "prepared_transport" if key == "public_transport"
        return "reviewed_waste_reference" if key == "waste_schedule"

        "prepared_source_observation"
      end

      def channel_support(channel)
        # All channels retain their existing dispatch wiring. The public v1
        # reader is supported where trusted Dialogue context is constructed;
        # legacy fallback is still a separate path, not a promise of parity.
        { "typed_support" => channel == "web" ? "public_v1_with_trusted_context" : "not_wired_by_current_adapter", "legacy_path" => "present",
          "activation" => "verify_channel_configuration_and_live_evidence", "channel" => channel }
      end
    end
  end
end
