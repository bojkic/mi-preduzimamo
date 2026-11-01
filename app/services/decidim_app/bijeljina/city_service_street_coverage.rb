# frozen_string_literal: true

require "digest"
require "json"
require "uri"
require "yaml"

module DecidimApp
  module Bijeljina
    # An unspecified street segment is relevant to every area traversed by the
    # verified full named street. Neither area kind is inferred from the other.
    class CityServiceStreetCoverage
      DATA_PATH = ENV.fetch("MI_STREET_COVERAGE_PATH", "").freeze
      VERSION = "2026-09-10.1"

      def initialize(organization:, data: nil, areas: nil, municipal_data: nil)
        @organization = organization
        @data = data || (DATA_PATH.empty? ? { "features" => [] } : JSON.parse(File.read(DATA_PATH)))
        @areas = areas
        @municipal_data = municipal_data || CityServiceAreaCrosswalk.load_config
        @intersection = CityServiceStreetIntersection.new
        @resolved = {}
        @local_registry = LocalStreetRegistry.new(organization:, areas:)
      end

      def match(event)
        return unless event.content_version.present? && event.extraction_metadata["source_snapshot_complete"] == true && supported_source?(event)

        queries = street_queries(event)
        return if queries.empty?

        places, unresolved = collected_places(queries, water: event.source_key == "water_service")
        return if places.empty?

        { "status" => unresolved.empty? ? "resolved" : "partial", "complete" => unresolved.empty?,
          "source_content_version" => event.content_version, "street_coverage_revision" => revision,
          "scope" => unresolved.empty? ? "whole_named_street_when_segment_unspecified" : "mapped_street_parts",
          "scope_precision" => "unspecified_street_segment",
          "affected_places" => places.uniq, "unresolved_places" => unresolved, "ambiguous_places" => [], "notification_candidates" => [] }
      end

      def revision
        @revision ||= Digest::SHA256.hexdigest([VERSION, @data.to_json, @municipal_data.to_json, LocalStreetRegistry.dataset.to_json,
                                                areas.sort_by(&:slug).map { |area| [area.slug, area.boundary] }.to_json].join("|"))
      end

      private

      def collected_places(queries, water: false)
        places = []
        unresolved = []
        queries.each do |name, settlement|
          # "Balatun (Balatun)" is a source-named place, not proof of a
          # homonymous street. Mixed lists must retain this unresolved clause.
          matched = water && name == settlement ? [] : resolve_street(name, settlement)
          if matched.any?
            places.concat(matched)
            if matched.any? { |place| place["geometry_complete"] == false }
              unresolved << { "kind" => "street", "evidence" => "#{name}, #{settlement}", "reason" => "street_geometry_partial" }
            end
          else
            unresolved << { "kind" => "street", "evidence" => "#{name}, #{settlement}", "reason" => "full_street_geometry_not_verified" }
          end
        end
        [places, unresolved]
      end

      def supported_source?(event)
        uri = URI.parse(event.source_url.to_s)
        return false unless uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil?

        if event.source_key == "electricity_outages"
          electricity_source?(event, uri)
        else
          event.source_key == "water_service" && %w(bnvodovod.com www.bnvodovod.com).include?(uri.host) && uri.path.start_with?("/v2/")
        end
      rescue URI::InvalidURIError, ArgumentError
        false
      end

      def electricity_source?(event, uri)
        %w(elektrobijeljina.com www.elektrobijeljina.com).include?(uri.host) && uri.path == "/lt/podrska/iskljucenja/index.php" &&
          URI.decode_www_form(uri.query.to_s).include?(%w(rj 41)) && Decidim::Bih::Text.fold(event.extraction_metadata["tj"]) == "bijeljina"
      end

      def street_queries(event)
        if event.source_key == "water_service"
          return event.affected_text.to_s.split(/;|\n/).map do |part|
            match = part.strip.match(/\A([^()]+)\s*\(([^()]+)\)\z/)
            match ? [normalize_street(match[1]), Decidim::Bih::Text.fold(match[2])] : [normalize_street(part), nil]
          end
        end
        text = Decidim::Bih::Text.fold(event.affected_text)
        text = text.sub(/\A(?:\d+|svi)\s+nn\s+izlaz[ai]?\s+/, "")
        return [] unless text.match?(/\A(?:dio\s+)?ulic[aeiu]\s+/) || text != Decidim::Bih::Text.fold(event.affected_text)

        text.split(/\s+i\s+(?:dio\s+)?(?=ulic[aeiu]\s)/).map { |name| [normalize_street(name), "bijeljina"] }
      end

      def normalize_street(text)
        Decidim::Bih::Text.fold(text).sub(/\A(?:dio\s+)?(?:ulic[aeiu]\s+)?/, "")
      end

      def resolve_street(name, settlement)
        @resolved[[name, settlement]] ||= begin
          matches = @data.fetch("features").select do |feature|
            properties = feature.fetch("properties")
            names = [properties.fetch("name"), *Array(properties["aliases"])].map { |value| normalize_street(value) }
            properties["geometry_complete"] == true && Decidim::Bih::Text.fold(properties.fetch("settlement")) == settlement && names.include?(name)
          end
          # One feature contains ALL components of this named street. Multiple
          # competing records do not silently choose the first available way.
          if matches.one?
            merge_place_sources(area_places(matches.first, name, settlement) + @local_registry.coverage(name:, settlement:))
          elsif matches.empty?
            merge_place_sources(@local_registry.coverage(name:, settlement:))
          else
            []
          end
        end
      end

      def merge_place_sources(places)
        places.group_by { |place| [place.fetch("slug"), place.fetch("kind")] }.values.map do |sources|
          sources.first.merge("geometry_complete" => sources.none? { |source| source["geometry_complete"] == false },
                              "sources" => sources.uniq)
        end
      end

      def area_places(feature, name, settlement)
        geometry = feature.fetch("geometry")
        properties = feature.fetch("properties")
        geometry_places = areas.select { |area| area.boundary.present? && @intersection.intersects?(geometry, area.boundary) }.map do |area|
          { "slug" => area.slug, "kind" => area.kind, "relation" => "possible_overlap", "evidence" => "#{name}, #{settlement}",
            "source" => "full_named_street_geometry", "source_url" => properties.fetch("source_url"),
            "source_object_ids" => properties.fetch("source_object_ids"), "source_object_urls" => Array(properties["source_object_urls"]), "geometry_sha256" => Digest::SHA256.hexdigest(geometry.to_json),
            "boundary_sha256" => Digest::SHA256.hexdigest(area.boundary.to_json), "retrieved_at" => properties.fetch("retrieved_at") }
        end
        geometry_places + municipal_places(name, settlement)
      end

      def municipal_places(name, settlement)
        Array(@municipal_data["street_sides"]).filter_map do |row|
          next unless row.fetch("name") == name && row.fetch("settlement") == settlement
          next unless areas.any? { |area| area.kind == "mz" && area.slug == row.fetch("mz_slug") }

          citations = row.fetch("citations").map { |citation| citation.merge("url" => @municipal_data.fetch("sources").fetch(citation.fetch("source"))) }
          { "slug" => row.fetch("mz_slug"), "kind" => "mz", "relation" => "possible_overlap", "evidence" => "#{name}, #{settlement}",
            "source" => "municipal_street_side", "side" => row.fetch("side"), "citations" => citations }
        end
      end

      def areas
        @areas ||= Decidim::Bih::LocalArea.where(organization: @organization, kind: %w(mz komsiluk)).to_a
      end
    end
  end
end
