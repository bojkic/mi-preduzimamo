# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Bijeljina-specific wiring of the generic civic-service directory machinery
    # (Decidim::Bih::City::ServiceDirectory) over Lokalna fondacija Bijeljina's
    # service data (CityServicesData::ENTRIES).
    #
    # Use the memoized directory:
    #
    #   DecidimApp::Bijeljina::CityDirectory.directory.search("parking")
    #
    # Operator overrides (admin content editor pilot): an APPROVED
    # CityServiceEntry row shadows the shipped entry with the same key. The
    # module-level readers (`all`, `find`, `search`, `metadata_for`) and
    # `CityDirectory.for(organization)` consult those rows on every call, so a
    # fresh approval or rollback is visible on the next chat turn with no
    # restart. Drafts, rolled-back rows and approved rows edited afterwards are
    # ignored (CityServiceEntry#live?). `directory` itself stays the raw shipped
    # ServiceDirectory. Everything degrades to the shipped constants when
    # ActiveRecord or the model is not loaded (the standalone contract tests) or
    # the database cannot be reached.
    module CityDirectory
      # A ServiceDirectory-compatible view (all/find/search plus the host's
      # metadata_for/procedure_for) bound to one organization's overrides.
      class Overlay
        def initialize(base, organization:)
          @base = base
          @organization = organization
        end

        def all
          overrides = CityDirectory.approved_overrides(organization: @organization)
          @base.all.map { |entry| overrides.fetch(entry.fetch(:key), entry) }
        end

        def find(key)
          shipped = @base.find(key)
          return unless shipped

          CityDirectory.approved_overrides(organization: @organization).fetch(shipped.fetch(:key), shipped)
        end

        def search(query, limit: Decidim::Bih::City::ServiceDirectory::DEFAULT_LIMIT)
          hits = @base.search(query, limit: limit)
          return hits if hits.empty?

          overrides = CityDirectory.approved_overrides(organization: @organization)
          hits.map { |entry| overrides.fetch(entry.fetch(:key), entry) }
        end

        def procedure_for(key)
          CityDirectory.procedure_for(key)
        end

        def metadata_for(key)
          CityDirectory.metadata_for(key, organization: @organization)
        end
      end

      class << self
        # Memoized directory over the reviewed Bijeljina civic-service entries
        # exactly as shipped; overrides are layered by the readers below.
        def directory
          @directory ||=
            Decidim::Bih::City::ServiceDirectory.new(CityServicesData::ENTRIES)
        end

        # Override-aware view for one organization.
        def for(organization)
          Overlay.new(directory, organization:)
        end

        def procedure_for(key)
          ServiceProcedures.find(key)
        end

        def metadata_for(key, organization: nil)
          entry = find(key, organization:)
          return unless entry

          metadata = entry.slice(:source_checked_on, :record_kind, :location_scope, :verification_scope, :effective_from, :effective_until, :facts)
          return metadata unless ServiceProcedures.find(key)

          row = CityServiceSourceCheckStore.new.snapshot(source_key: "reference:procedure:#{key}")
          metadata.merge(refresh_status: row&.check_payload&.fetch("status", nil),
                         content_changed: row&.check_payload&.fetch("error_code", nil) == "procedure_content_changed",
                         last_checked_at: row&.attempted_at&.iso8601)
        rescue ActiveRecord::ActiveRecordError
          metadata.merge(refresh_status: "unavailable")
        end

        # Convenience delegators so callers can use the module directly. With no
        # organization the concierge's organization is used (single tenant).
        def all(organization: nil)
          overlay(organization).all
        end

        def find(key, organization: nil)
          overlay(organization).find(key)
        end

        def search(query, limit: Decidim::Bih::City::ServiceDirectory::DEFAULT_LIMIT, organization: nil)
          overlay(organization).search(query, limit: limit)
        end

        # The shipped entry merged with reviewed operator content. Pure: the
        # admin preview renders a DRAFT through exactly this merge, so what the
        # operator sees is what the chat will say once approved. Sectioned
        # answers (parking, transport) lose their section maps on purpose — an
        # operator-written body is rendered whole, never sliced by the shipped
        # section regexes.
        def override_entry(base, title:, answer:, source_url:, source_checked_on: nil)
          checked_on = source_checked_on.to_s.empty? ? Date.iso8601(base.fetch(:source_checked_on)) : Date.iso8601(source_checked_on.to_s)
          merged = base.except(:answer_sections, :answer_sources, :facts).merge(
            title: title.to_s, answer: answer.to_s, source_url: source_url.to_s,
            source_checked_on: checked_on.iso8601, content_origin: "admin_override"
          )
          merged.merge(facts: CityServicesData.entry_facts(merged, checked_on:)).freeze
        end

        # { key(Symbol) => merged entry } for the organization's live overrides.
        def approved_overrides(organization: nil)
          return {} unless overrides_available?

          organization ||= default_organization
          return {} unless organization

          rows = DecidimApp::Bijeljina::CityServiceEntry.for_organization(organization).approved.to_a
          rows.each_with_object({}) do |row, overrides|
            next unless row.live?

            base = directory.find(row.key)
            next unless base

            overrides[base.fetch(:key)] = override_entry(base, **row.override_attributes)
          end
        rescue StandardError => e
          log_warning("[CityDirectory] overrides unavailable, using shipped entries: #{e.class}")
          {}
        end

        private

        def overlay(organization)
          Overlay.new(directory, organization:)
        end

        # False in the standalone contract tests (no Rails, no ActiveRecord)
        # and before the pilot's migration has run.
        def overrides_available?
          defined?(ActiveRecord::Base) &&
            defined?(DecidimApp::Bijeljina::CityServiceEntry) &&
            DecidimApp::Bijeljina::CityServiceEntry.table_exists?
        rescue StandardError
          false
        end

        def default_organization
          DecidimApp::Bijeljina::Concierge.organization
        rescue StandardError
          nil
        end

        def log_warning(message)
          return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

          Rails.logger.warn(message)
        end
      end
    end
  end
end
