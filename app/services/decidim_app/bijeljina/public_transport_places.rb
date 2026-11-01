# frozen_string_literal: true

require "yaml"
require "decidim/bih/transliterator"

module DecidimApp
  module Bijeljina
    # Bijeljina-specific place labels and explicitly chosen timetable defaults.
    # A place ID refers to the selected printed stop across its physical sides;
    # route planning keeps those sides distinct.
    module PublicTransportPlaces
      DATA_PATH = ENV.fetch("MI_TRANSPORT_PLACES_PATH", "").freeze

      module_function

      def entries
        return [] if DATA_PATH.empty?

        YAML.safe_load(File.read(DATA_PATH), permitted_classes: [], aliases: false).fetch("places")
      end

      def resolver(catalog, stop_id:, route_code: nil)
        place_entries = entries
        stop_aliases = inflected_stop_aliases(place_entries)
        stops = catalog.fetch(:rows).map do |row|
          { id: stop_id.call(row), label: row.label, aliases: stop_aliases.fetch(row.label, []) + acronym_aliases(row.label) }
        end.uniq { |row| row.fetch(:id) }
        by_label = stops.group_by { |stop| stop.fetch(:label) }
        places = place_entries.filter_map do |entry|
          members = entry.fetch("member_labels").flat_map { |label| Array(by_label[label]).map { |stop| stop.fetch(:id) } }.uniq
          selected_label = selection_label(entry, catalog, route_code)
          defaults = Array(by_label[selected_label]).map { |stop| stop.fetch(:id) }
          next if defaults.empty? || (defaults - members).any?

          { id: entry.fetch("id"), name: entry.fetch("name"), aliases: entry.fetch("aliases"),
            member_stop_ids: members, default_stop_ids: defaults, default_label: selected_label,
            assumption_reason: selected_label == entry.fetch("default_label") ? entry.fetch("assumption_reason") : "route_supported_member" }
        end
        Decidim::Bih::Transport::StopResolver.new(stops:, places:)
      end

      # Published stop suffixes remain exact; only a reviewed inflection of
      # that stop's settlement name may be substituted. Collisions stay
      # ambiguous in StopResolver instead of choosing by fuzzy similarity.
      def inflected_stop_aliases(place_entries)
        place_entries.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |entry, result|
          name = entry.fetch("name")
          stem = Decidim::Bih::Transliterator.to_latin(name).downcase[0, 3]
          aliases = entry.fetch("aliases").select do |item|
            item.split.size == name.split.size && Decidim::Bih::Transliterator.to_latin(item).downcase.start_with?(stem)
          end
          entry.fetch("member_labels").each do |label|
            next unless label.start_with?("#{name} (")

            suffix = label.delete_prefix(name)
            result[label].concat(aliases.map { |item| "#{item}#{suffix}" })
          end
        end.transform_values(&:uniq)
      end

      # Printed all-capitals stop names often take a grammatical suffix in a
      # citizen's sentence. Generate only these bounded forms from reviewed
      # labels; the resolver still preserves collisions across physical sides.
      def acronym_aliases(label)
        return [] unless label.match?(/\A[A-ZČĆŠŽĐ0-9]{2,6}\z/)

        %w(a u om).map { |ending| "#{label}-#{ending}" }
      end

      def selection_stop_ids(catalog, id, stop_id:, route_code: nil)
        entry = entries.find { |place| place.fetch("id") == id }
        return [id] unless entry

        label = selection_label(entry, catalog, route_code)
        catalog.fetch(:rows).filter_map do |row|
          stop_id.call(row) if row.label == label
        end.uniq
      end

      def assumption(catalog, id, stop_id:, route_code: nil)
        entry = entries.find { |place| place.fetch("id") == id }
        return unless entry

        available = catalog.fetch(:rows).map(&:label).uniq
        label = selection_label(entry, catalog, route_code)
        return unless available.include?(label)

        { "place_id" => id, "selected_stop" => label,
          "reason" => label == entry.fetch("default_label") ? entry.fetch("assumption_reason") : "route_supported_member",
          "alternative_stops" => (entry.fetch("member_labels") & available).reject { |item| item == label }.first(6) }
      end

      def selection_label(entry, catalog, route_code)
        return entry.fetch("default_label") unless route_code

        route_labels = catalog.fetch(:routes).select { |route| route.code == route_code }
                              .flat_map { |route| route.directions.flat_map { |direction| direction.stops.map(&:label) } }.uniq
        return entry.fetch("default_label") if route_labels.include?(entry.fetch("default_label"))

        entry.fetch("member_labels").find { |label| route_labels.include?(label) } || entry.fetch("default_label")
      end
    end
  end
end
