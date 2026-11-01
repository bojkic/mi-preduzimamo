# frozen_string_literal: true

require "digest"
require "json"
require "uri"

module DecidimApp
  module Bijeljina
    module Milica
      # Only public reader projections enter here. Never serializes model/AR
      # objects. Source absence and partial coverage survive the adaptation.
      module PublicToolEvidence
        Dialogue = Decidim::Bih::Concierge::Dialogue

        module_function

        def definition(name, description, properties, required, handler)
          { "name" => name, "description" => description,
            "parameters" => { "type" => "object", "properties" => properties, "required" => required, "additionalProperties" => false }, "handler" => handler }
        end

        def string(limit = 200, choices = nil)
          { "type" => "string", "maxLength" => limit }.tap { |schema| schema["enum"] = choices if choices }
        end

        def envelope(values, organization_id:, registry_epoch:, operation:, arguments:)
          data = values.respond_to?(:to_h) ? values.to_h : values
          data = data.transform_keys(&:to_sym)
          status = public_status(data.fetch(:status))
          warnings = Array(data[:warnings]).map(&:to_s).grep(/\A[a-z][a-z0-9_]{0,79}\z/).uniq
          # Empty is represented by unsupported in the engine contract. Only
          # the owning material catalogue's raw empty status can establish this
          # narrower signal; an unavailable source cannot supply it itself.
          warnings.delete("public_catalog_material_needs_empty")
          if operation == "read_catalog" && arguments["topic"] == "community" &&
             arguments["view"] == "material_needs" && data.fetch(:status).to_s == "empty"
            warnings << "public_catalog_material_needs_empty"
          end
          # Preserve the existing reader's explicit conflict representation;
          # ordinary unreviewed sources remain unreviewed and assert no facts.
          if status == "unreviewed" && warnings.include?("conflicting_current_facts") && Array(data[:facts]).any?
            status = "conflicting"
          end
          facts = %w(ok conflicting).include?(status) ? Array(data[:facts]) : []
          records = facts.first(8).map { |fact| record(fact, data) }
          candidates = Array(data[:candidates]).first(20).map { |item| candidate(item, operation) }
          if operation == "read_service_events" && data.dig(:coverage, "location_scope") == "boundary_best_guess"
            # The engine's query scope is closed. Candidate labels are its
            # supported public display channel for an approximate area choice.
            Array(data.dig(:coverage, "assumed_area_labels")).first(3).each do |label|
              candidates << candidate({ "label" => label }, operation) if label.is_a?(String)
            end
          end
          scope = { "operation" => operation, "subject_ids" => ["query:#{digest(arguments)}"], "source_ids" => records.map { |row| row.fetch("document_id") }.uniq }
          scope["date"] = arguments["date"] if arguments["date"]
          Dialogue::EvidenceEnvelope.new(organization_id:, registry_epoch:, status:, evidence: records, candidates:, warnings:,
                                         coverage_complete: false, query_scope: scope)
        end

        def public_status(value)
          status = { "stale" => "expired", "empty" => "unsupported" }.fetch(value.to_s, value.to_s)
          raise Dialogue::Contracts::Invalid, "Unknown public source status" unless Dialogue::EvidenceEnvelope::STATUSES.include?(status)

          status
        end

        def candidate(item, operation)
          row = json(item)
          { "id" => "candidate:#{digest([operation, row])}",
            "document_id" => "public:#{operation}", "revision" => digest(row),
            "label" => (row["label"] || row["text"] || row["name"] || row["id"]).to_s[0, 160] }.tap do |value|
            # Only an owning reader may supply this key. Never derive a tool
            # input from the opaque citation ID or an arbitrary display label.
            value["selection_key"] = row.fetch("selection_key") if row.key?("selection_key")
          end
        end

        def source_identity(value, source)
          value["source_id"] || value.dig("source", "id") || source["id"] || value["id"]
        end

        def record(fact, data)
          value = json(fact)
          source = json(data[:source] || {})
          identity = source_identity(value, source)
          body = { "source_fact" => value, "validity" => json(data[:validity] || {}),
                   "interpretation" => { "subject_scope" => "Only the named service, subject and source-covered area",
                                         "time_scope" => "Publication, source capture and review times do not establish observation time",
                                         "authority_scope" => "A contact or permission for one action does not establish authority for another action" } }
          if value["kind"] == "city_service_event"
            # A search for MZ Centar can return a wider contextual notice. The
            # reader's outer coverage describes the search, while the notice's
            # own coverage says whether that MZ is actually affected.
            source_coverage = value.fetch("coverage", {})
            relation = source_coverage["requested_relation"]
            confirmed = %w(whole part).include?(relation) && Array(source_coverage["requested_areas"]).any? &&
                        !Array(value["warning_codes"]).include?("geographic_scope_unconfirmed")
            body["query_scope"] = json(data[:coverage] || {})
            body["applicability_to_requested_area"] = {
              "status" => confirmed ? "confirmed" : "unconfirmed",
              "relation" => relation || "unknown",
              "requested_areas" => source_coverage.fetch("requested_areas", []),
              "confirmed_affected_areas" => source_coverage.fetch("affected_areas", [])
            }
            body["interpretation"]["geography_scope"] = "The query's area is a search filter, not evidence that a returned notice affects it. Only the notice's confirmed affected-area relation supports that claim."
          else
            body["coverage"] = json(data[:coverage] || {})
          end
          limitations = (Array(data[:warnings]) + Array(value["warning_codes"])).map(&:to_s).uniq
          record = { "id" => "r_#{digest([body, limitations])[0, 24]}", "document_id" => identity.to_s[0, 160], "revision" => digest(body),
                     "text" => event_text(value, body), "facts" => body,
                     "limitations" => limitations }
          url = value["source_url"] || value.dig("source", "url") || source["url"]
          record["source_url"] = url if https?(url)
          record
        end

        def event_text(value, body)
          text = value.fetch("text", "Public structured source fact")
          return text unless value["kind"] == "city_service_event"
          return text unless body.dig("applicability_to_requested_area", "status") == "unconfirmed"

          requested = Array(body.dig("applicability_to_requested_area", "requested_areas")).filter_map { |area| area["name"] }.first(3)
          return text if requested.empty?

          confirmed = Array(body.dig("applicability_to_requested_area", "confirmed_affected_areas"))
          scope_note = confirmed.empty? ? "U ovom čitanju nijedna MZ nije potvrđena kao zahvaćena." : "Potvrđena pogođena područja su navedena odvojeno u obuhvatu samog obavještenja."
          "Za traženo područje #{requested.join(', ')} nije potvrđeno da ga ova obavijest obuhvata. Naziv objekta i mjesta koja on sugeriše nisu dokaz prekida za to mjesto. #{scope_note} #{text}"
        end

        def https?(url)
          uri = URI.parse(url.to_s)
          uri.scheme == "https" && uri.host && !uri.userinfo
        rescue URI::InvalidURIError
          false
        end

        def digest(value) = Digest::SHA256.hexdigest(JSON.generate(json(value)))

        def json(value)
          case value
          when Hash then value.transform_keys(&:to_s).sort.to_h.transform_values { |item| json(item) }
          when Array then value.map { |item| json(item) }
          when Time, Date then value.iso8601
          when Symbol then value.to_s
          when String, Integer, Float, NilClass, TrueClass, FalseClass then value
          else raise Dialogue::Contracts::Invalid, "Public projection contains unsupported #{value.class.name}"
          end
        end
      end
    end
  end
end
