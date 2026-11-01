# frozen_string_literal: true

require_relative "public_tool_evidence"
require_relative "public_filesystem_knowledge"

module DecidimApp
  module Bijeljina
    module Milica
      # Retrieval over the existing reviewed public filesystem projections.
      # Every call reconstructs review/hash/expiry gates. Dynamic DB catalogs
      # remain separate typed tools; absence here proves no civic-world absence.
      class PublicKnowledgeTools
        SEARCH_DOMAINS = %w(agriculture billing culture directory education employment health heating intercity_travel permits recycling).freeze
        DEFAULT_LIMIT = 3
        MAX_LIMIT = 8

        def initialize(organization:, registry_epoch:, source_checker:, projection: PublicFilesystemKnowledge.new, directory: nil)
          @organization = organization
          @epoch = registry_epoch
          @source_checker = source_checker
          @projection = projection
          @directory = directory || CityDirectory.for(organization)
        end

        def definitions
          [PublicToolEvidence.definition("search_public_knowledge", "Partial filesystem reference facts only: agriculture/fuel forms, education, health, culture, employment/intercity travel, " \
                                                                    "billing/recycling/heating, directory atoms and permits. Not platform rules, budgets, gazette, catalogs or current notices: use their named readers. " \
                                                                    "Return whole facts, default3; refine query/domain or pass a returned selection_key as document_id; or raise limit to8. Empty means no eligible matches in this partial search; unsupported/unreviewed is not absence. Never infer other readers lack facts.",
                                         { "query" => PublicToolEvidence.string(500), "domain" => PublicToolEvidence.string(80, SEARCH_DOMAINS),
                                           "document_id" => PublicToolEvidence.string(160),
                                           "limit" => { "type" => "integer", "minimum" => 1, "maximum" => MAX_LIMIT } }, [], method(:search))]
        end

        def search(arguments:, context:)
          raise PublicToolEvidence::Dialogue::Contracts::Invalid, "Public tenant mismatch" unless context.organization_id == @organization.id && context.allows?("public_reads")

          day = context.now.in_time_zone("Europe/Sarajevo").to_date
          projection = @projection.call(organization_id: @organization.id, as_of: day)
          manifest = KnowledgeManifest.new(organization_id: @organization.id, as_of: day).build(**projection.slice(:records, :inventory))
          documents = selected_documents(manifest.fetch("documents"), arguments, context)
          terms = Decidim::Bih::Text.fold(arguments["query"].to_s).split.uniq
          ranked = rank(documents, terms)
          limit = arguments.fetch("limit", DEFAULT_LIMIT)
          selected = ranked.sort_by { |row, score| [-score, row.fetch("document_id")] }.first(limit).map(&:first)
          facts = selected.map { |row| document_fact(row) }
          warnings = %w(partial_reviewed_knowledge_not_complete_inventory lexical_retrieval_not_semantic_proof other_public_readers_not_searched)
          warnings << "more_matching_documents_refine_query_or_increase_limit" if ranked.size > facts.size
          values = { status: facts.empty? ? "empty" : "ok", facts:, warnings:,
                     coverage: { "eligible_document_count" => documents.size, "matched_count" => ranked.size, "returned_count" => facts.size, "complete_inventory" => false,
                                 "inventory_scope" => "reviewed filesystem documents only", "available_domains" => SEARCH_DOMAINS,
                                 "more_matches_available" => ranked.size > facts.size, "refinement" => "Narrow query/domain/document_id or raise limit up to8; full fact bodies are never truncated.",
                                 "empty_meaning" => "No eligible matches for this search in the partial filesystem projection; not proof a procedure, event or public rule does not exist.",
                                 "other_sources" => { "platform policy and report recovery" => "read_platform_guidance", "budget and gazette" => "read_reference",
                                                      "live catalogs" => "read_catalog", "notices" => "read_service_events", "procedures" => "read_procedure", "contacts" => "read_directory" } } }
          PublicToolEvidence.envelope(values, organization_id: @organization.id, registry_epoch: @epoch, operation: "search_public_knowledge", arguments:)
        end

        private

        def selected_documents(documents, arguments, context)
          documents.select do |row|
            live_eligible?(row, context) && (arguments["domain"].blank? || row["domain"] == arguments["domain"]) &&
              (arguments["document_id"].blank? || row["document_id"] == arguments["document_id"])
          end
        end

        def document_fact(row)
          checked = %w(filesystem_inventory_only_live_registry_not_checked source_refresh_content_change_status_not_checked
                       approved_database_directory_override_not_checked)
          { "selection_key" => row.fetch("document_id"), "id" => row.fetch("document_id"), "source_id" => row.fetch("document_id"), "source_url" => row.fetch("source_url"),
            "text" => row.fetch("body"), "revision" => row.fetch("revision"), "domain" => row.fetch("domain"),
            "coverage" => row.fetch("coverage"), "reviewed_at" => row.fetch("reviewed_at"), "review_expires_at" => row["review_expires_at"],
            "published_at" => row["published_at"], "observed_at" => row["observed_at"],
            "effective_from" => row["effective_from"], "effective_until" => row["effective_until"], "source_locator" => row.fetch("source_locator"),
            "warning_codes" => row.fetch("limitations") - checked }
        end

        def rank(documents, terms)
          documents.map { |row| [row, score(row, terms)] }.select { |_, score| terms.empty? || score.positive? }
        end

        def score(row, terms)
          title = Decidim::Bih::Text.fold([row["title"], row["domain"], row["subject_id"]].join(" "))
          body = Decidim::Bih::Text.fold(row.fetch("body"))
          terms.sum { |term| (title.include?(term) ? 3 : 0) + (body.include?(term) ? 1 : 0) }
        end

        def live_eligible?(row, context)
          if row.fetch("document_id").start_with?("bijeljina:procedure:")
            card = ServiceProcedures.find(row.fetch("document_id").delete_prefix("bijeljina:procedure:"))
            return card && ProcedureRead.new(source_store: @source_checker).call(card:, locale: "sr", now: context.now)[:status] == "ok"
          end
          if row["domain"] == "directory"
            entry = @directory.find(row.dig("coverage", "topic_key"))
            return false unless entry && entry[:content_origin] != "admin_override"
          end
          true
        end
      end
    end
  end
end
