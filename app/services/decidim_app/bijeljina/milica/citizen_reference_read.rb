# frozen_string_literal: true

require_relative "read/base"
require_relative "../citizen_reference_catalog"

module DecidimApp
  module Bijeljina
    module Milica
      # A bounded reference reader. A subject match is not proof of every facet:
      # unknown, revoked and expired claims have no answerable fact payload.
      class CitizenReferenceRead
        include Read::Base

        FACETS = {
          "contact" => /\b(?:kontakt\w*|telefon\w*|broj|email|mejl|adres\w*|gdje|gde)\b/,
          "vacancy_search" => /\b(?:oglas\w*|konkurs\w*|posao|posla|poslov\w*|zaposlen\w*)\b/,
          "hours" => /\b(?:radno vrijeme|radno vreme|radi|rade|radite|otvoren\w*|subot\w*|nedjelj\w*|nedelj\w*)\b/,
          "procedure" => /\b(?:rok\w*|kako|kad\w*|obraz\w*|zahtjev\w*|zahtev\w*|prijav\w*|preuz\w*)\b/,
          "location" => /\b(?:gdje|gde|adres\w*|preuz\w*|obraz\w*)\b/,
          "winter_break" => /\b(?:zimsk\w*|kalendar\w*)\b/,
          "spring_break" => /\b(?:proljec\w*|prolec\w*|kalendar\w*)\b/,
          "event" => /\b(?:kad\w*|termin\w*|predstav\w*|brijuni\w*|brijunima|sezon\w*)\b/
        }.freeze
        # Strong unsupported questions win over broad incidental words such as
        # "gdje", "kada" or the title of an event.
        UNSUPPORTED = /\b(?:
          cijen\w*|cen[aeu]|kost\w*|cena|plat\w*|dokument\w*|imam\ li\ pravo|ispunjavam|
          ulaznic\w*|kart[aeu]|koliko|radno\ mjesto|mjesto\ rada|mesto\ rada|gdje\ cu\ raditi|gde\ cu\ raditi|
          slobodn\w*|rasproda\w*|otkazan\w*|otkaziv\w*|zatvoren\w*|obustav\w*|ne\ radi|
          nema\ nastave|ima\ li\ nastave|ide\ li|polazak\w*|polasci|polazi|stize|dolazak\w*|gradski\w*|autobus\w*
        )\b/x

        def self.handles?(topic:, entities:)
          CitizenReferenceCatalog.default.matching(topic:, entities:).any?
        rescue CitizenReferenceCatalog::ReviewError
          false
        end

        def initialize(organization:, catalog: CitizenReferenceCatalog.default)
          @organization = organization
          @catalog = catalog
        end

        def call(topic:, entities:, context:, locale:)
          return not_authorized_result unless authorized?(context)

          subjects = @catalog.matching(topic:, entities:)
          return result("unavailable", source: nil, warnings: ["reference_subject_not_matched"]) if subjects.empty?

          query = fold(entities["query"])
          subjects = school_level(subjects, query)
          rows = subjects.flat_map { |subject| @catalog.facts_for(subject) }
          matching = requested_facts(rows, query, entities)
          day = local_date(context.now)
          selected = matching.select { |row| @catalog.readiness(row, day:) == "ready" }
          selected = requested_date_scope(selected, entities:, query:, now: context.now)
          status = selected.any? ? "ok" : "unavailable"
          result(status, source: selected.any? ? @catalog.source_for(selected.first) : nil,
                         facts: selected.map { |row| fact(row, locale:) },
                         coverage: coverage(subjects, selected), validity: { "live_status" => false, "as_of_local_date" => day.iso8601 },
                         warnings: warnings(matching, selected, day:))
        rescue CitizenReferenceCatalog::ReviewError, Date::Error
          result("unavailable", source: nil, warnings: ["reference_review_unavailable"])
        end

        private

        # A named service in another city is not this host city's office. The
        # explicit area entity additionally catches places outside this small
        # reviewed vocabulary; omitted place defaults only to the host scope.
        def foreign_scope?(query, entities)
          place = fold(entities["area_query"])
          return true if place.present? && %w(bijeljina semberija).exclude?(place)

          /\b(?:brck\w*|tuzl\w*|sarajev\w*|beograd\w*|novi sad|novom sadu|zagreb\w*|banja luka|banjoj luci|banjaluk\w*)\b/.match?(query)
        end

        def school_level(subjects, query)
          level = if /\bosnovn\w*\b/.match?(query)
                    "primary"
                  elsif /\bsrednj\w*\b/.match?(query)
                    "secondary"
                  end
          return subjects unless level

          subjects.reject { |subject| subject["domain"] == "education" && subject.fetch("id").exclude?(":#{level}:") }
        end

        def requested_facts(rows, query, entities)
          return [] if foreign_scope?(query, entities) || UNSUPPORTED.match?(query)

          years = query.scan(/\b20\d{2}\b/).map(&:to_i)
          rows.select do |row|
            supported_year = row.fetch("period_years").empty? || (years - row.fetch("period_years")).empty?
            supported_year && exact_facet?(row, query)
          end
        end

        def exact_facet?(row, query)
          return false if vacancy_search_not_office_contact?(row, query)
          return false if row["kind"] == "announced_event" && FACETS.fetch("contact").match?(query)

          FACETS.fetch(row.fetch("facet")).match?(query)
        end

        def vacancy_search_not_office_contact?(row, query)
          row["id"] == "employment:biro-contact" && FACETS.fetch("vacancy_search").match?(query) &&
            !/\b(?:kontakt\w*|telefon\w*|broj|email|mejl|adres\w*)\b/.match?(query)
        end

        def requested_date_scope(rows, entities:, query:, now:)
          expression = entities["time_expression"].presence
          expression ||= "danas" if /\b(?:veceras|danas|sada|trenutno)\b/.match?(query)
          expression ||= "sutra" if /\bsutra\b/.match?(query)
          requested = requested_day(entities, now:, expression: fold(expression))
          return rows if requested.kind == :none
          return [] if requested.day.nil?

          rows.select { |row| covers_day?(row, requested.day) }
        end

        def date_bounds(row, keys)
          keys.filter_map { |key| row[key] && Date.iso8601(row.fetch(key)) }
        end

        def covers_day?(row, day)
          lower = date_bounds(row, %w(effective_from occurs_from))
          upper = date_bounds(row, %w(effective_until occurs_until))
          return false if lower.any? { |bound| day < bound } || upper.any? { |bound| day >= bound }

          return true unless row["kind"] == "announced_event"

          day == Time.iso8601(row.fetch("starts_at")).in_time_zone(Read::Base::TIME_ZONE).to_date
        end

        def fact(row, locale:)
          doc = @catalog.document_for(row)
          {
            "id" => row.fetch("id"), "subject_id" => row.fetch("subject_id"), "kind" => row.fetch("kind"),
            "text" => cyrillize("#{row.fetch("text")} #{row.fetch("next_action")}", locale:),
            "facet" => row.fetch("facet"), "source" => @catalog.source_for(row), "source_url" => doc.fetch("url"),
            "source_published_on" => doc["published_on"], "reviewed_on" => row.fetch("reviewed_on"),
            "review_expires_on" => row.fetch("review_expires_on"), "effective_from" => row["effective_from"],
            "effective_until" => row["effective_until"], "starts_at" => row["starts_at"],
            "occurs_from" => row["occurs_from"], "occurs_until" => row["occurs_until"],
            "revision_sha256" => row.fetch("reviewed_sha256")
          }
        end

        def coverage(subjects, selected)
          { "organization_id" => @organization.id, "scope" => "reviewed_citizen_references",
            "subject_ids" => subjects.map { |subject| subject.fetch("id") },
            "geographic_scopes" => subjects.map { |subject| subject.fetch("geographic_scope") },
            "known_facets" => selected.map { |row| row.fetch("facet") }.uniq,
            "unknown_features" => subjects.flat_map { |subject| subject.fetch("unknown_features") }.uniq,
            "status" => selected.any? ? "resolved" : "not_ready" }
        end

        def date_not_covered?(matching, selected, day:)
          selected.empty? && matching.any? { |row| @catalog.readiness(row, day:) == "ready" }
        end

        def warnings(matching, selected, day:)
          codes = ["reviewed_reference_not_live_status"]
          codes << "requested_reference_feature_unknown" if matching.empty?
          codes << "requested_date_not_covered" if date_not_covered?(matching, selected, day:)
          matching.each do |row|
            readiness = @catalog.readiness(row, day:)
            codes << "reference_#{readiness}" unless readiness == "ready"
          end
          codes << "announced_event_not_current_programme" if selected.any? { |row| row["kind"] == "announced_event" }
          codes.uniq
        end
      end
    end
  end
end
