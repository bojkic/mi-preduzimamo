# frozen_string_literal: true

require "yaml"
require "json"
require "digest"
require "date"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/hash/except"
require_relative "../citizen_reference_catalog"
require_relative "knowledge_manifest"

module DecidimApp
  module Bijeljina
    module Milica
      # Fixed public source allowlist. Does not boot Rails, scan arbitrary paths,
      # query a database, evaluate source files or contact a source/provider.
      class PublicFilesystemKnowledge
        CONFIG = "config/bijeljina"
        DATA = "app/services/decidim_app/bijeljina/data"
        FILES = ["#{CONFIG}/citizen_reference_facts.yml", "#{CONFIG}/directory_service_facts.yml",
                 *%w(billing heating recycling).map { |name| "#{CONFIG}/#{name}_reviewed_facts.yml" },
                 "#{DATA}/service_procedures.json"].freeze
        DOMAINS = %w(account agriculture air_quality animals billing budget bulky_waste city_service civil_protection community culture
                     directory donation education electricity facilities gazette goodwill health heating launch neighborhood parking participation
                     permits platform police privacy public_calls recycling report rewards roads social_welfare transport volunteer waste water water_levels weather).freeze
        DB_DOMAINS = %w(air_quality civil_protection directory donation electricity facilities gazette heating neighborhood
                        participation public_calls rewards roads social_welfare volunteer water water_levels weather).freeze

        def initialize(root: File.expand_path("../../../../..", __dir__))
          @root = File.realpath(root)
        end

        def call(organization_id:, as_of:)
          @organization_id = organization_id
          @as_of = as_of
          @inventory = []
          @records = []
          @files = {}
          FILES.each { |path| load_file(path) }
          reference_records
          civic_records
          directory_records
          procedure_records
          inventory_gaps
          { records: @records, inventory: @inventory, files: @files.values.map { |item| item.except("data") } }
        end

        private

        def load_file(relative)
          candidate = File.join(@root, relative)
          return unless File.exist?(candidate) || File.symlink?(candidate)

          path = File.realpath(candidate)
          raise KnowledgeManifest::Invalid, "source escapes public repository root" unless path.start_with?("#{@root}/")

          bytes = File.binread(path)
          raise KnowledgeManifest::Invalid, "oversized public source" if bytes.bytesize > 2_000_000

          text = bytes.force_encoding(Encoding::UTF_8)
          raise KnowledgeManifest::Invalid, "invalid source encoding" unless text.valid_encoding?

          data = relative.end_with?(".json") ? JSON.parse(text) : YAML.safe_load(text, aliases: false)
          @files[relative] = { "path" => relative, "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize,
                               "raw_words" => text.split.size, "data" => data }
        end

        def file(path) = @files.fetch(path)

        def data(path) = file(path).fetch("data")

        def base(path:, id:, domain:, source_id:, url:, title:, body:, reviewed:, status:, authority:, revision:, basis:) # rubocop:disable Metrics/ParameterLists -- explicit reviewed provenance
          {
            "document_id" => "bijeljina:#{id}", "organization_id" => @organization_id, "domain" => domain,
            "public" => true, "source_id" => source_id, "source_url" => url, "title" => title, "language" => "sr",
            "body" => body, "review_status" => status, "reviewed_at" => reviewed, "review_expires_at" => nil,
            "authority_kind" => authority, "source_locator" => "app:#{path}##{id}",
            "coverage" => { "kind" => "reviewed_filesystem_snapshot", "repository_file_sha256" => file(path).fetch("sha256") },
            "limitations" => %w(filesystem_inventory_only_live_registry_not_checked not_live_status),
            "published_at" => nil, "observed_at" => nil, "effective_from" => nil, "effective_until" => nil,
            "source_revision" => revision, "approval_basis" => basis
          }
        end

        def reference_records
          path = "#{CONFIG}/citizen_reference_facts.yml"
          return unless @files.has_key?(path)

          catalogue = CitizenReferenceCatalog.new(data: data(path))
          catalogue.subjects.each_value do |subject|
            catalogue.facts_for(subject).each do |fact|
              source = catalogue.source_for(fact)
              document = catalogue.document_for(fact)
              row = base(path:, id: fact.fetch("id"), domain: subject.fetch("domain"), source_id: source.fetch("id"),
                         url: source.fetch("url"), title: subject.fetch("id"), body: [fact.fetch("text"), fact.fetch("next_action")].join("\n\n"),
                         reviewed: fact.fetch("reviewed_on"), status: fact.fetch("review_status"), authority: source.fetch("authority"),
                         revision: source.fetch("document_revision_sha256"), basis: "CitizenReferenceCatalog reviewed hash chain")
              row.merge!("subject_id" => subject.fetch("id"), "review_expires_at" => fact.fetch("review_expires_on"),
                         "eligibility" => catalogue.readiness(fact, day: @as_of), "review_proof" => fact.fetch("reviewed_sha256"),
                         "published_at" => document["published_on"])
              %w(effective_from effective_until occurs_from occurs_until).each { |key| row[key] = fact[key] }
              row["coverage"].merge!("geography" => subject.fetch("geographic_scope"), "facet" => fact.fetch("facet"),
                                     "publisher_document_id" => document.fetch("id"))
              row["limitations"] += Array(subject["unknown_features"]) + Array(fact["warning_codes"])
              row["eligibility"] = "current_announcement_requires_live_reader" if fact["kind"] == "announced_event"
              @records << row
            end
          end
        end

        def civic_records
          %w(billing heating recycling).each do |domain|
            path = "#{CONFIG}/#{domain}_reviewed_facts.yml"
            next unless @files.has_key?(path)

            pack = data(path)
            groups = domain == "billing" ? pack.fetch("billers") : [pack]
            groups.each do |group|
              Array(group["facts"]).each do |fact|
                row = base(path:, id: fact.fetch("id"), domain:, source_id: fact.fetch("source_url"), url: fact.fetch("source_url"),
                           title: fact["source_label"] || fact.fetch("id"), body: fact.fetch("text"),
                           reviewed: fact.fetch("reviewed_on"), status: fact["publishable"] == true ? "reviewed" : "unreviewed",
                           authority: "reviewed_service_source", revision: pack.fetch("revision"), basis: "explicit publishable:true in reviewed civic fact pack")
                row["public"] = fact["publishable"] == true
                row["coverage"].merge!("source_on" => fact.fetch("source_on"), "only_for" => fact["only_for"], "biller_id" => group["id"])
                row["limitations"] += Array(fact["warning_codes"]) + ["review_expiry_not_defined_in_source"]
                # Limits accompany every fact; unavailable facts are not exported
                # separately with an invented official citation or approval.
                row["coverage"]["domain_limitations"] = Array(pack["blockers"]).map { |item| item.slice("id", "question", "text", "unblock") }
                if domain == "billing"
                  row["coverage"]["personal_bill_boundary"] = pack.fetch("personal_bill_boundary").fetch("text")
                  row["coverage"]["complaint_route"] = group["complaint_route"]
                end
                @records << row
              end
            end
          end
        end

        def directory_records
          path = "#{CONFIG}/directory_service_facts.yml"
          return unless @files.has_key?(path)

          data(path).each do |key, facts|
            facts.each do |fact|
              row = base(path:, id: fact.fetch("logical_id"), domain: "directory", source_id: fact.fetch("publisher_id"),
                         url: fact.fetch("source_url"), title: fact.fetch("subject_id"), body: fact.fetch("text"),
                         reviewed: fact.fetch("source_checked_on"), status: fact.fetch("review_state"), authority: "reviewed_public_office",
                         revision: fact.fetch("fact_revision"), basis: "review_state from reviewed atomic public directory file")
              row.merge!("subject_id" => fact.fetch("subject_id"), "published_at" => fact["source_published_at"],
                         "effective_from" => fact["effective_from"], "effective_until" => fact["effective_until"], "end_exclusive" => false)
              row["coverage"].merge!("topic_key" => key, "predicate" => fact.fetch("predicate"),
                                     "document_id" => fact.fetch("document_id"), "source_locator" => fact.fetch("source_locator"),
                                     "source_document_sha256" => fact.fetch("source_document_sha256"))
              row["limitations"] += %w(approved_database_directory_override_not_checked review_expiry_not_defined_in_source)
              @records << row
            end
          end
        end

        def procedure_records
          path = "#{DATA}/service_procedures.json"
          return unless @files.has_key?(path)

          data(path).fetch("procedures").each do |card|
            # Keep fee values, currencies, unknowns and conditions together.
            body = JSON.pretty_generate(card.slice("title", "owner", "eligibility", "steps", "required_documents", "fee", "processing_time", "privacy", "current_legal_status"))
            row = base(path:, id: "procedure:#{card.fetch("key")}", domain: "permits", source_id: card.fetch("owner"),
                       url: card.fetch("source_url"), title: card.fetch("title"), body:, reviewed: card.fetch("source_checked_on"),
                       status: card.fetch("review_status"), authority: "reviewed_public_procedure", revision: card.fetch("reviewed_content_hash"),
                       basis: "review_status from bundled ServiceProcedures record")
            row["coverage"].merge!("geography" => card.fetch("location_scope"), "source_fragment" => card.fetch("source_fragment"))
            row.merge!("effective_from" => card["effective_from"], "effective_until" => card["effective_until"])
            row["limitations"] += %w(source_refresh_content_change_status_not_checked review_expiry_not_defined_in_source)
            @records << row
          end
        end

        def inventory_gaps
          DOMAINS.each do |domain|
            projected = @records.any? { |row| row["domain"] == domain }
            @inventory << { "domain" => domain, "status" => projected ? "local_projection_available" : "no_local_prose_projection",
                            "complete" => false }
            if DB_DOMAINS.include?(domain)
              @inventory << { "domain" => domain, "status" => "database_inventory_not_performed", "count" => nil,
                              "reason" => "authorized_public_projection_and_current_registry_check_required" }
            end
          end
          {
            "transport" => "timetable_matrices_stops_connections_remain_authoritative_tools",
            "waste" => "street_schedule_calendar_remains_authoritative_tool",
            "budget" => "bundled_budget_table_requires_numeric_tool_and_reviewed_prose_projection",
            "gazette" => "bundled_issue_metadata_and_selected_acts_need_reviewed_prose_projection_not_full_archive",
            "platform" => "locale_and_code_rules_need_explicit_public_reviewed_projection_not_wholesale_source_export",
            "parking" => "prices_and_zone_maps_remain_authoritative_tools"
          }.each { |domain, reason| @inventory << { "domain" => domain, "status" => "typed_tool_or_projection_required", "reason" => reason } }
          %w(account report neighborhood goodwill).each do |domain|
            @inventory << { "domain" => domain, "status" => "private_records_excluded_by_policy",
                            "reason" => "private_state_is_only_available_through_authorized_live_tools" }
          end
          @inventory << { "domain" => "directory", "status" => "partial_filesystem_projection", "reason" => "atomic_facts_only_Ruby_directory_cards_not_evaluated_or_exported" }
        end
      end
    end
  end
end
