# frozen_string_literal: true

require "digest"
require_relative "read/base"

module DecidimApp
  module Bijeljina
    module Milica
      # Locally prepared public references. Publication/capture dates are never
      # promoted to effective dates, and a missing donation cache is not zero.
      class ReferenceRead
        include Read::Base

        TOPICS = %w(budget gazette donation).freeze
        MAX_FACTS = 8

        def initialize(organization:, budget: Budget, gazette: Gazette, donations: Donations)
          @organization = organization
          @budget = budget
          @gazette = gazette
          @donations = donations
        end

        def call(topic:, entities:, context:, locale:)
          return not_authorized_result unless authorized?(context)

          values = case topic
                   when "budget" then budget_read(entities, context)
                   when "gazette" then gazette_read(entities, context)
                   when "donation" then donation_read(context)
                   else { status: "unavailable", warnings: ["unsupported_reference_topic"] }
                   end
          values.fetch(:facts, []).each do |fact|
            fact["text"] = cyrillize(clean_text(fact.fetch("text"), limit: 1_000), locale:)
          end
          values
        end

        private

        def budget_read(entities, context)
          unless @budget.configured?
            return { status: "unavailable", facts: [], warnings: ["budget_source_not_configured"] }
          end
          if @budget::SOURCE_CAPTURED_ON > local_date(context.now)
            return { status: "unavailable", facts: [], warnings: ["budget_review_in_future"] }
          end

          year = @budget::YEAR
          query = entities["query"].to_s
          requested_year = [entities["date"], entities["time_expression"], query].compact.join(" ")[/\b(?:19|20)\d{2}\b/]&.to_i
          validity = { "fiscal_year" => year, "executed_spending" => false, "complete_budget" => false }
          source = { "id" => "citizen_budget:#{year}", "label" => "Budžet za građane #{year}", "url" => @budget.source_url }
          warnings = %w(planned_allocations_not_spending partial_budget_tables)
          page = @budget.table_page
          headline = @budget.headline_total
          warnings << "budget_table_page_not_reviewed" unless page
          warnings << "budget_headline_not_reviewed" unless headline
          if requested_year ? requested_year != year : local_date(context.now).year != year
            return { status: "stale", source:, validity:, warnings: warnings + ["budget_year_not_available"] }
          end

          needle = fold(query).gsub(/\b(?:koliko|je|za|budzet\w*|grada|bijeljin\w*|izdvojeno|novca|sredstva|planirano|u|od|20\d{2})\b/, " ").split.join(" ")
          rows = @budget.default.line_items
          rows = rows.select { |row| needle.split.all? { |word| fold(row.fetch(:category)).split.include?(word) } } if needle.present?
          facts = rows.first(MAX_FACTS).map do |row|
            fact(source:, key: row.fetch(:category), kind: "budget_allocation",
                 text: "#{row.fetch(:category)}: #{money(row.fetch(:amount))} KM, plan za #{year}. Ovo nije podatak o izvršenoj potrošnji.",
                 checked_on: @budget::SOURCE_CAPTURED_ON, warnings:).merge("amount" => row.fetch(:amount).to_f, "currency" => "BAM", "fiscal_year" => year)
                 .merge(page ? { "source_pdf_page" => page } : {})
          end
          if needle.blank? && headline
            facts = [fact(source:, key: "headline", kind: "budget_total",
                          text: "Ukupno planirana sredstva budžeta za #{year}: #{money(headline)} KM. " \
                                "Izdvojene tabele korisnika ne predstavljaju zbir svih budžetskih stavki.",
                          checked_on: @budget::SOURCE_CAPTURED_ON, warnings:)] + facts.first(MAX_FACTS - 1)
          end
          { status: facts.any? ? "ok" : "empty", facts:, source:, validity:, warnings:,
            coverage: { "scope" => "city_budget", "organization_id" => @organization.id, "table_pages" => Array(page), "matched_rows" => rows.size } }
        rescue Decidim::Bih::City::BudgetError
          { status: "unavailable", facts: [], warnings: ["budget_document_not_reviewed_for_year"] }
        end

        def gazette_read(entities, context)
          query = entities["query"].to_s
          index = @gazette.index
          needle = fold(query).gsub(/\b(?:sluzbeni|glasni\w*|grada|bijeljin\w*|najnoviji|posljednji|poslednji|odluk\w*)\b/, " ").split.join(" ")
          rows = needle.blank? ? index.recent(limit: MAX_FACTS) : index.search(needle, limit: MAX_FACTS)
          source = { "id" => "gazette_index", "label" => "Službeni glasnik zajednice", "url" => (@gazette.respond_to?(:current_source_url) ? @gazette.current_source_url : @gazette.source_url) }
          warnings = %w(partial_archive_coverage publication_not_effective_date decision_supersession_not_verified)
          index_checked_on = @gazette.respond_to?(:index_checked_on) ? @gazette.index_checked_on : nil
          unless index_checked_on
            return { status: "unavailable", facts: [], source:, warnings: warnings + ["gazette_index_not_reviewed"] }
          end
          if index_checked_on > local_date(context.now)
            return { status: "unavailable", facts: [], source:, warnings: warnings + ["gazette_review_in_future"] }
          end
          acts = matching_gazette_acts(query, context)
          facts = acts.map { |act| gazette_act_fact(act, source, warnings) }
          facts += rows.map { |row| gazette_fact(row, source, warnings) }
          facts = facts.first(MAX_FACTS)
          stale = index_checked_on < local_date(context.now) - 45
          warnings << "gazette_index_stale" if stale
          status = facts.any? ? "ok" : "empty"
          status = "stale" if stale
          { status:, facts: stale ? [] : facts, source:, warnings:,
            coverage: { "scope" => "published_gazette_index", "organization_id" => @organization.id, "complete_archive" => false,
                        "matched_reviewed_acts" => acts.size, "complete_act_coverage" => false },
            validity: { "effective_status" => "not_verified", "index_captured_on" => index_checked_on.iso8601 } }
        end

        def matching_gazette_acts(query, context)
          return [] unless @gazette.respond_to?(:acts) && query.present?

          needle = fold(query)
          @gazette.acts.select do |act|
            next false if Date.iso8601(act.fetch(:source_checked_on)) > local_date(context.now)

            terms = [act.fetch(:provider_act_id), *act.fetch(:keywords)]
            terms.any? { |term| needle.include?(fold(term)) }
          end.first(MAX_FACTS)
        end

        def gazette_act_fact(act, source, warnings)
          text = "#{act.fetch(:title)} (#{act.fetch(:provider_act_id)}). #{act.fetch(:summary)} " \
                 "Donesena #{act.fetch(:adopted_on)}, objavljena #{act.fetch(:published_on)}. " \
                 "Prema izvornoj odredbi, stupanje na snagu: #{act.fetch(:effective_from)}. " \
                 "Naknadne izmjene i sadašnje važenje nisu potvrđeni."
          fact(source: source.merge("url" => act.fetch(:source_url)), key: act.fetch(:id), kind: "gazette_act", text:,
               checked_on: Date.iso8601(act.fetch(:source_checked_on)), warnings:)
            .merge("provider_act_id" => act.fetch(:provider_act_id), "issue_number" => act.fetch(:issue_number),
                   "source_pdf_pages" => act.fetch(:source_pdf_pages), "source_content_hash" => act.fetch(:issue_content_hash),
                   "adopted_on" => act.fetch(:adopted_on), "published_on" => act.fetch(:published_on),
                   "effective_from" => act.fetch(:effective_from), "effective_basis" => act.fetch(:effective_basis),
                   "legal_basis" => act.fetch(:legal_basis), "amends" => act.fetch(:amends), "current_legal_status" => "not_verified")
        end

        def gazette_fact(row, source, warnings)
          original = if @gazette.respond_to?(:catalog_entries)
                       @gazette.catalog_entries.find { |entry| entry.fetch(:number) == row.fetch(:number) } || row
                     else
                       row
                     end
          metadata = (@gazette.metadata_for(row.fetch(:number)) if @gazette.respond_to?(:metadata_for)) || {}
          captured = metadata&.[](:source_checked_on) || metadata&.[]("source_checked_on") || (@gazette.index_checked_on if @gazette.respond_to?(:index_checked_on))
          captured = Date.iso8601(captured) if captured.is_a?(String)
          text = ["#{row.fetch(:title)} #{row.fetch(:number)}", row[:date], row[:summary]].compact.join(". ")
          text += ". Prikazan je indeks izdanja; važenje pojedinačnih odluka provjerite u dokumentu."
          fact(source: source.merge("url" => row.fetch(:url)), key: row.fetch(:number), kind: "gazette_issue", text:, checked_on: captured, warnings:)
            .merge("published_date_text" => row[:date].to_s, "summary_verified" => row[:summary].present?,
                   "source_pdf_pages" => Array(metadata[:source_pdf_pages] || metadata["source_pdf_pages"] || original[:source_pdf_pages]).first(8))
        end

        def donation_read(context)
          return { status: "unavailable", warnings: ["donation_provider_not_available_for_tenant"] } unless @donations.available_for?(organization: @organization)

          # Reading this cache can enqueue a deduplicated background refresh;
          # it never calls Odoo within the citizen request.
          totals = @donations.totals
          source = { "id" => "donations:#{@organization.id}", "label" => "Donacije zajednice", "url" => @donations.donate_url }
          return { status: "unavailable", source:, warnings: ["donation_totals_not_prepared"] } unless totals.as_of

          unless totals.as_of <= context.now && totals.as_of >= context.now - 2.hours
            return { status: "stale", source:, checked_at: totals.as_of.iso8601,
                     warnings: ["donation_totals_stale"] }
          end

          warnings = ["public_aggregate_not_donor_records"]
          observed = totals.as_of.in_time_zone(TIME_ZONE).strftime("%d.%m.%Y. %H:%M")
          row = fact(source:, key: "total", kind: "donation_total", checked_on: totals.as_of, warnings:,
                     text: "Ukupno prikupljene donacije prema posljednjoj evidenciji: #{money(totals.total)} #{@donations.currency_label}. Stanje: #{observed}.")
          row.delete("reviewed_on")
          row.merge!("observed_at" => totals.as_of.iso8601, "amount" => totals.total.to_f, "currency" => totals.currency.to_s, "as_of" => totals.as_of.iso8601)
          { status: "ok", facts: [row], source:, checked_at: totals.as_of.iso8601, warnings:,
            coverage: { "organization_id" => @organization.id, "scope" => "public_donation_aggregate" }, validity: { "as_of" => totals.as_of.iso8601 } }
        end

        # This shared envelope keeps source, date and warning fields explicit at every call site.
        def fact(source:, key:, kind:, text:, checked_on:, warnings:) # rubocop:disable Metrics/ParameterLists
          { "id" => "#{source.fetch("id")}:#{Digest::SHA256.hexdigest(key)[0, 16]}", "kind" => kind, "text" => text,
            "source_id" => source.fetch("id"), "source_label" => source.fetch("label"), "source_url" => source.fetch("url"),
            "reviewed_on" => checked_on.iso8601, "warning_codes" => warnings }
        end

        def money(value)
          ActionController::Base.helpers.number_with_delimiter(format("%.2f", value), delimiter: ".", separator: ",")
        end
      end
    end
  end
end
