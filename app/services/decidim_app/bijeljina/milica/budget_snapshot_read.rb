# frozen_string_literal: true

require "digest"
require "bigdecimal"
require_relative "read/base"

module DecidimApp
  module Bijeljina
    module Milica
      # The model selects rows from this small prepared table. Query prose never
      # filters it. Capture date is historical source provenance, not a fresh check.
      class BudgetSnapshotRead
        include Read::Base

        MAX_BYTES = 1_000_000
        WARNINGS = %w(planned_allocations_not_spending partial_budget_tables).freeze

        def initialize(organization:, budget: Budget)
          @organization = organization
          @budget = budget
        end

        def call(context:, fiscal_year: nil)
          return not_authorized_result unless authorized?(context)

          return { status: "unavailable", warnings: WARNINGS + ["budget_source_not_configured"] } unless @budget.configured?

          year = fiscal_year || local_date(context.now).year
          return { status: "unsupported", warnings: WARNINGS + ["budget_year_not_available"] } unless year == @budget::YEAR
          return { status: "unreviewed", warnings: ["budget_capture_after_requested_time"] } if local_date(context.now) < @budget::SOURCE_CAPTURED_ON

          # Re-read the checked-in projection so prompt/send eligibility detects
          # changed source content instead of reusing Budget.default's memoization.
          contents = File.read(@budget::BUNDLED_TEXT_PATH, MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
          unless contents.bytesize <= MAX_BYTES && contents.valid_encoding?
            return { status: "unavailable", warnings: WARNINGS + ["budget_snapshot_invalid"] }
          end
          snapshot = Decidim::Bih::City::Budget.from_text(contents)
          unless snapshot.year == @budget::YEAR
            return { status: "unreviewed", warnings: WARNINGS + ["budget_document_not_reviewed_for_year"] }
          end
          page = @budget.table_page
          headline = @budget.headline_total
          warnings = WARNINGS.dup
          warnings << "budget_table_page_not_reviewed" unless page
          warnings << "budget_headline_not_reviewed" unless headline
          { status: "ok", facts: [snapshot_fact(snapshot, contents, page:, headline:, warnings:)], warnings:,
            validity: { "fiscal_year" => year, "executed_spending" => false, "complete_budget" => false },
            coverage: { "organization_id" => @organization.id, "scope" => "city_budget", "table_pages" => Array(page),
                        "allocation_count" => snapshot.line_items.size, "complete_budget" => false } }
        rescue SystemCallError, EncodingError, Decidim::Bih::City::BudgetError
          { status: "unavailable", warnings: WARNINGS + ["budget_snapshot_unavailable"] }
        end

        private

        def snapshot_fact(snapshot, contents, page:, headline:, warnings:)
          { "id" => "citizen_budget:#{@budget::YEAR}:snapshot", "source_id" => "citizen_budget:#{@budget::YEAR}",
            "kind" => "budget_snapshot", "text" => "Prepared citizen budget: headline and partial planned allocation tables.",
            "source_url" => @budget.source_url, "source_content_sha256" => Digest::SHA256.hexdigest(contents),
            "source_captured_on" => @budget::SOURCE_CAPTURED_ON.iso8601, "fiscal_year" => @budget::YEAR, "currency" => "BAM",
            "allocations" => allocations(snapshot, page:), "headline_reviewed" => !headline.nil?,
            "partial_table" => true, "planned_not_paid" => true,
            "warning_codes" => warnings }.tap do |fact|
            if headline
              total = snapshot.line_items.sum(BigDecimal("0")) { |row| BigDecimal(row.fetch(:amount).to_s) }
              fact["headline_total"] = headline.to_f
              fact["allocations_do_not_balance_headline"] = total != headline
            end
          end
        end

        def allocations(snapshot, page:)
          snapshot.line_items.map do |row|
            { "category" => row.fetch(:category), "amount" => row.fetch(:amount).to_f }.merge(page ? { "source_pdf_page" => page } : {})
          end
        end
      end
    end
  end
end
