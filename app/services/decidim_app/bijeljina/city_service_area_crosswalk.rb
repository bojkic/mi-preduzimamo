# frozen_string_literal: true

require "yaml"
require "uri"
require "digest"
require "json"

module DecidimApp
  module Bijeljina
    # Public municipal definitions establish place containment, not a utility
    # circuit footprint. Only the provider's affected-place list is eligible.
    class CityServiceAreaCrosswalk
      CONFIG_PATH = ENV.fetch("MI_SERVICE_CROSSWALKS_PATH", "").freeze

      def self.load_config
        CONFIG_PATH.empty? ? { "places" => [], "sources" => {} } : YAML.safe_load_file(CONFIG_PATH, aliases: false)
      end

      def initialize(organization:, config: nil, matcher: nil, settlement_coverage: nil)
        @config = config || self.class.load_config
        @matcher = matcher || CityServiceAreaMatcher.new(organization:)
        @settlement_coverage = settlement_coverage || (CityServiceSettlementCoverage.new(organization:) if organization)
      end

      def match(event)
        return unless event.content_version.present? && event.extraction_metadata["source_snapshot_complete"] == true
        return unless supported_source?(event)

        clauses = affected_clauses(event.affected_text)
        return if clauses.empty?

        mapped = []
        unresolved = []
        clauses.each do |clause|
          places = resolved_places(clause)
          if places.any?
            mapped.concat(places)
          else
            unresolved << { "kind" => "locality", "evidence" => clause, "reason" => "containment_not_verified" }
          end
        end
        return if mapped.empty?

        { "status" => unresolved.empty? ? "resolved" : "partial", "crosswalk_revision" => revision,
          "source_content_version" => event.content_version, "complete" => unresolved.empty?,
          "scope" => "named_places_only", "affected_places" => mapped.uniq, "unresolved_places" => unresolved,
          "ambiguous_places" => [], "notification_candidates" => [], "komsiluk_status" => komsiluk_status(mapped) }
      end

      def revision
        @revision ||= Digest::SHA256.hexdigest([@config.to_json, @settlement_coverage&.revision].join("|"))
      end

      private

      def resolved_places(clause)
        geographic = @settlement_coverage&.match(clause:) || []
        geographic.any? ? geographic : [resolved_place(clause)].compact
      end

      def komsiluk_status(places)
        places.any? { |place| place["kind"] == "komsiluk" } ? "independent_geometry" : "not_inferred"
      end

      def resolved_place(clause)
        entry = @config.fetch("places").find { |row| row.fetch("aliases").include?(clause) }
        return unless entry
        return unless @matcher.resolve(area_slug: entry.fetch("mz_slug"), place_kind: "mz").status == :ok

        { "slug" => entry.fetch("mz_slug"), "kind" => "mz", "relation" => "part", "evidence" => clause,
          "source" => "municipal_place_containment", "place_kind" => entry.fetch("kind"),
          "citations" => entry.fetch("citations").map { |citation| citation.merge("url" => @config.fetch("sources").fetch(citation.fetch("source"))) } }
      end

      def supported_source?(event)
        uri = URI.parse(event.source_url.to_s)
        event.source_key == "electricity_outages" && safe_provider_url?(uri) &&
          uri.path == "/lt/podrska/iskljucenja/index.php" && URI.decode_www_form(uri.query.to_s).include?(%w(rj 41)) &&
          %w(bijeljina janja).include?(Decidim::Bih::Text.fold(event.extraction_metadata["tj"]))
      rescue URI::InvalidURIError, ArgumentError
        false
      end

      def safe_provider_url?(uri)
        uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? && %w(elektrobijeljina.com www.elektrobijeljina.com).include?(uri.host)
      end

      def affected_clauses(text)
        # Keep list structure before Text.fold removes punctuation. A feeder
        # name or an untyped free-text mention is never eligible for containment.
        normalized = text.to_s.gsub(/[^,;:\n]+/) { |part| Decidim::Bih::Text.fold(part) }
        heading = /\A(?:naseljen[oa]\s+mjest[oa]|naselja)\s*:\s*/
        return [] unless normalized.match?(heading)

        normalized = normalized.sub(heading, "").gsub(/\b(donji|donje) i (gornji|gornje) ([a-z]+)\b/, '\1 \3,\2 \3')
        normalized.split(/[,;\n]|\s+i\s+/).map { |part| part.strip.sub(/\Adio\s+/, "") }.compact_blank
      end
    end
  end
end
