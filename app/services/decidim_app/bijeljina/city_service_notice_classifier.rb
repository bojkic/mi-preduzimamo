# frozen_string_literal: true

require_relative "city_service_sources"

module DecidimApp
  module Bijeljina
    # Gemini JSON-mode classifier for collected city-service notices.
    #
    # The model recommends classification, targeting and urgency; deterministic
    # policy code still validates the source, event, severity, target and Viber
    # delivery gate before anything is sent.
    class CityServiceNoticeClassifier
      EVENT_TYPES = (
        # Vocabulary stays stable even when every outbound adapter is disabled.
        CityServiceSources::REFERENCE_SOURCES.filter_map { |source| source[:viber] }.flat_map { |viber| viber.fetch(:event_types) } +
        %w(not_relevant routine_service_info bulky_waste_collection)
      ).uniq.freeze

      SEVERITIES = %w(routine info service_outage safety emergency).freeze
      DELIVERY_RECOMMENDATIONS = %w(no_publish board_only viber_alert operator_review).freeze
      TARGETING_LEVELS = %w(komsiluk mz citywide unknown).freeze
      SUMMARY_LIMIT = 500
      TITLE_LIMIT = 120
      VIBER_LIMIT = 500

      Result = Struct.new(
        :source_key,
        :publish,
        :event_type,
        :severity,
        :targeting_level,
        :target_area_slugs,
        :title,
        :body,
        :viber_text,
        :delivery_recommendation,
        :confidence,
        :starts_at,
        :ends_at,
        :fingerprint,
        :needs_review,
        :reasons,
        keyword_init: true
      ) do
        def publish?
          publish == true
        end

        def viber_requested?
          delivery_recommendation == "viber_alert"
        end

        def board_category
          %w(service_outage safety emergency).include?(severity.to_s) ? "safety" : "general"
        end
      end

      def initialize(client: Decidim::Bih::Ai::GeminiClient.new)
        @client = client
      end

      def call(source_key:, title:, body:, **options)
        source = CityServiceSources.find(source_key)
        return fallback(source_key:, title:, reason: "unknown_source") unless source
        return fallback(source_key:, title:, reason: "gemini_unconfigured") unless @client.configured?

        parsed = @client.generate_content(
          contents: contents_for(source:, title:, body:, options: classifier_options(options)),
          response_schema: RESPONSE_SCHEMA
        )

        build_result(parsed, source_key: source.fetch(:key), title:)
      rescue StandardError => e
        Rails.logger.warn("[CityServiceNoticeClassifier] Gemini failed: #{safe_error(e)}")
        fallback(source_key:, title:, reason: "gemini_failed")
      end

      private

      def build_result(parsed, source_key:, title:)
        raise Decidim::Bih::Ai::Error, "expected a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

        publish = boolean(parsed["publish"])
        event_type = enum_value(parsed["event_type"], EVENT_TYPES, "not_relevant")
        severity = enum_value(parsed["severity"], SEVERITIES, "info")
        delivery = enum_value(parsed["delivery_recommendation"], DELIVERY_RECOMMENDATIONS, "no_publish")

        delivery = "no_publish" unless publish

        Result.new(
          source_key:,
          publish:,
          event_type:,
          severity:,
          targeting_level: enum_value(parsed["targeting_level"], TARGETING_LEVELS, "unknown"),
          target_area_slugs: normalized_slugs(parsed["target_area_slugs"]),
          title: truncate(clean_text(parsed["title"]).presence || clean_text(title), TITLE_LIMIT),
          body: truncate(clean_text(parsed["body"]).presence || clean_text(title), SUMMARY_LIMIT),
          viber_text: truncate(clean_text(parsed["viber_text"]), VIBER_LIMIT),
          delivery_recommendation: delivery,
          confidence: bounded_confidence(parsed["confidence"]),
          starts_at: clean_text(parsed["starts_at"]),
          ends_at: clean_text(parsed["ends_at"]),
          fingerprint: clean_text(parsed["fingerprint"]),
          needs_review: boolean(parsed["needs_review"]),
          reasons: Array(parsed["reasons"]).map { |reason| truncate(clean_text(reason), 140) }.compact_blank
        )
      end

      def fallback(source_key:, title:, reason:)
        Result.new(
          source_key: source_key.to_s,
          publish: false,
          event_type: "not_relevant",
          severity: "info",
          targeting_level: "unknown",
          target_area_slugs: [],
          title: truncate(clean_text(title), TITLE_LIMIT),
          body: "",
          viber_text: "",
          delivery_recommendation: "no_publish",
          confidence: 0.0,
          starts_at: "",
          ends_at: "",
          fingerprint: "",
          needs_review: true,
          reasons: [reason]
        )
      end

      def classifier_options(options)
        {
          url: options.fetch(:url, nil),
          known_areas: options.fetch(:known_areas, []),
          locale: options.fetch(:locale, "sr-Latn")
        }
      end

      def contents_for(source:, title:, body:, options:)
        [{ role: "user", parts: [{ text: prompt(source:, title:, body:, options:) }] }]
      end

      INSTRUCTIONS = [
        "You classify official city-service notices for Bijeljina residents.",
        "Return only JSON matching the schema. Do not add markdown or prose.",
        "Use only the fixed enum values. If the notice is unclear, stale, promotional, political, or not about a citizen service, set publish=false.",
        "Never invent Komsiluk or MZ slugs. Use only slugs from the known area list. If you cannot map the location, use targeting_level=unknown and target_area_slugs=[].",
        "This is a second opinion on a complete official article, not authority to select a board or send a message. Safety, emergency, citywide and uncertain notices always require operator review.",
        "Recommend viber_alert only for actionable emergency or unusual service information: flood, storm, fire, evacuation, " \
        "public-health warning, road closure/hazard, planned or unplanned electricity outage, planned or unplanned water " \
        "interruption, heating interruption, or a restoration update that changes what citizens should do.",
        "A planned electricity outage is service_outage and should be viber_alert when the affected Komšiluk or MZ is known.",
        "Never recommend viber_alert for routine waste pickup, ordinary schedules, generic news, ads, public-report archives, duplicate/stale notices, or unclear target areas.",
        "Use citywide targeting only for official emergency/weather/civil-protection warnings or notices that explicitly affect all Bijeljina residents.",
        "Write title, body and viber_text in Serbian Latin script. Keep viber_text short, actionable, and free of raw HTML."
      ].freeze

      def prompt(source:, title:, body:, options:)
        [
          *INSTRUCTIONS,
          "",
          "Locale: #{options.fetch(:locale)}",
          "Source policy:",
          source_policy(source),
          "",
          "Known target areas:",
          known_area_lines(options.fetch(:known_areas)),
          "",
          "Notice title:",
          title.to_s,
          "",
          "Notice body:",
          body.to_s,
          "",
          "Notice URL:",
          options.fetch(:url).to_s
        ].join("\n")
      end

      def source_policy(source)
        viber = source.fetch(:viber)
        [
          "key=#{source.fetch(:key)}",
          "label=#{source.fetch(:label)}",
          "provider=#{source.fetch(:provider)}",
          "viber_eligible=#{viber.fetch(:eligible)}",
          "allowed_event_types=#{viber.fetch(:event_types).join(",")}",
          "allowed_severities=#{viber.fetch(:severities).join(",")}",
          "target_rule=#{viber.fetch(:target)}",
          "area_mapping=#{source.fetch(:area_mapping)}"
        ].join("\n")
      end

      def known_area_lines(known_areas)
        lines = Array(known_areas).filter_map do |area|
          kind = area_value(area, :kind)
          slug = area_value(area, :slug)
          name = area_value(area, :name)
          next if kind.blank? || slug.blank?

          "- kind=#{kind} slug=#{slug} name=#{name}"
        end

        lines.presence&.join("\n") || "- none"
      end

      def area_value(area, key)
        if area.respond_to?(key)
          area.public_send(key)
        elsif area.respond_to?(:[])
          area[key] || area[key.to_s]
        end
      end

      def enum_value(value, allowed, fallback)
        candidate = value.to_s.strip
        allowed.include?(candidate) ? candidate : fallback
      end

      def normalized_slugs(value)
        Array(value).map { |slug| slug.to_s.strip }.compact_blank.uniq.sort
      end

      def boolean(value)
        ActiveModel::Type::Boolean.new.cast(value) == true
      end

      def bounded_confidence(value)
        number = Float(value)
        number.clamp(0.0, 1.0)
      rescue ArgumentError, TypeError
        0.0
      end

      def clean_text(value)
        ActionController::Base.helpers.strip_tags(value.to_s).gsub(/\s+/, " ").strip
      end

      def truncate(value, limit)
        text = value.to_s
        return text if text.length <= limit

        text[0, limit].rstrip
      end

      def safe_error(error)
        if defined?(Decidim::Bih::LogRedactor)
          "#{error.class}: #{Decidim::Bih::LogRedactor.error_message(error)}"
        else
          "#{error.class}: #{error.message.to_s.split.join(" ")[0, 240]}"
        end
      end

      RESPONSE_SCHEMA = {
        type: "object",
        properties: {
          publish: { type: "boolean" },
          event_type: { type: "string", enum: EVENT_TYPES },
          severity: { type: "string", enum: SEVERITIES },
          targeting_level: { type: "string", enum: TARGETING_LEVELS },
          target_area_slugs: { type: "array", items: { type: "string" } },
          title: { type: "string" },
          body: { type: "string" },
          viber_text: { type: "string" },
          delivery_recommendation: { type: "string", enum: DELIVERY_RECOMMENDATIONS },
          confidence: { type: "number" },
          starts_at: { type: "string" },
          ends_at: { type: "string" },
          fingerprint: { type: "string" },
          needs_review: { type: "boolean" },
          reasons: { type: "array", items: { type: "string" } }
        },
        required: %w(
          publish event_type severity targeting_level target_area_slugs title body
          viber_text delivery_recommendation confidence needs_review reasons
        )
      }.freeze
    end
  end
end
