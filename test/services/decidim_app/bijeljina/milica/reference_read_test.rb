# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_public_catalogs"
require_relative "../../../../support/synthetic_gazette_acts"

module DecidimApp
  module Bijeljina
    module Milica
      class ReferenceReadTest < ActiveSupport::TestCase
        include SyntheticPublicCatalogs
        include SyntheticGazetteActs
        setup do
          @organization = create_organization
          @now = Time.utc(2040, 9, 16, 12)
          travel_to @now
          install_synthetic_public_catalogs
          install_synthetic_gazette_acts
        end

        teardown do
          restore_synthetic_gazette_acts
          restore_synthetic_public_catalogs
          travel_back
        end

        test "budget separates the headline from partial planned allocations and rejects another fiscal year" do
          reader = ReferenceRead.new(organization: @organization)
          result = reader.call(topic: "budget", entities: {}, context: context, locale: "sr")
          assert_equal "ok", result[:status]
          assert_equal "budget_total", result[:facts].first.fetch("kind")
          assert_equal false, result[:validity].fetch("executed_spending")
          assert_equal false, result[:validity].fetch("complete_budget")
          assert(result[:facts].drop(1).all? { |fact| fact.fetch("source_pdf_page") == 8 })
          assert_equal "stale", reader.call(topic: "budget", entities: { "date" => "2041-01-01" }, context: context, locale: "sr")[:status]
        end

        test "gazette act answers preserve pages and original effective clause without asserting current law" do
          result = ReferenceRead.new(organization: @organization)
                                .call(topic: "gazette", entities: { "query" => "odluka za Izmišljeni trg" }, context: context, locale: "sr")
          row = result.fetch(:facts).find { |fact| fact["kind"] == "gazette_act" }
          assert_equal "TEST-ACT-2040-A", row.fetch("provider_act_id")
          assert_equal "2040-03-10", row.fetch("effective_from")
          assert_equal "2040-03-09", row.fetch("published_on")
          assert_equal [3], row.fetch("source_pdf_pages")
          assert_equal "not_verified", row.fetch("current_legal_status")
          assert_includes row.fetch("text"), "sadašnje važenje nisu potvrđeni"
          assert_equal false, result[:coverage]["complete_act_coverage"]
        end

        test "a cold donation cache never becomes a zero donation assertion" do
          provider = Object.new
          provider.define_singleton_method(:available_for?) { |organization:| organization.present? }
          provider.define_singleton_method(:totals) { Struct.new(:as_of).new(nil) }
          provider.define_singleton_method(:donate_url) { "https://donations.example.invalid" }
          result = ReferenceRead.new(organization: @organization, donations: provider)
                                .call(topic: "donation", entities: {}, context: context, locale: "sr")
          assert_equal "unavailable", result[:status]
          assert_empty result.fetch(:facts, [])
          assert_includes result[:warnings], "donation_totals_not_prepared"
        end

        test "another tenant cannot read host donation or reference facts" do
          other = create_organization
          result = ReferenceRead.new(organization: other).call(topic: "budget", entities: {}, context: context, locale: "sr")
          assert_equal "not_authorized", result[:status]
          assert_empty result.fetch(:facts, [])
        end

        test "an injected publisher cannot borrow another catalog review date" do
          publisher = synthetic_other_publisher(reviewed: false)
          result = ReferenceRead.new(organization: @organization, gazette: publisher)
                                .call(topic: "gazette", entities: {}, context: context, locale: "sr")
          assert_equal "unavailable", result[:status]
          assert_empty result.fetch(:facts)
          assert_includes result[:warnings], "gazette_index_not_reviewed"
        end

        test "an injected publisher cannot borrow another issue page provenance" do
          publisher = synthetic_other_publisher(reviewed: true)
          result = ReferenceRead.new(organization: @organization, gazette: publisher)
                                .call(topic: "gazette", entities: {}, context: context, locale: "sr")
          assert_equal "ok", result[:status]
          row = result.fetch(:facts).fetch(0)
          assert_equal "gazette_issue", row.fetch("kind")
          assert_empty row.fetch("source_pdf_pages")
          assert_equal "https://other-publisher.example.invalid/issue.pdf", row.fetch("source_url")
          assert_equal "2040-09-15", row.fetch("reviewed_on")
        end

        test "a changed issue revision withholds the previously reviewed act" do
          owner = DecidimApp::Bijeljina::GazetteData
          changed = owner::ENTRIES.map { |row| row.merge(content_hash: "b" * 64).freeze }.freeze
          swap_service_constant(owner, :ENTRIES, changed)
          result = ReferenceRead.new(organization: @organization)
                                .call(topic: "gazette", entities: { "query" => "TEST-ACT-2040-A" }, context: context, locale: "sr")
          assert_equal 0, result.fetch(:coverage).fetch("matched_reviewed_acts")
          assert_equal false, result.fetch(:coverage).fetch("complete_act_coverage")
          assert_equal "not_verified", result.fetch(:validity).fetch("effective_status")
          refute result.fetch(:facts).any? { |row| row["kind"] == "gazette_act" }
        end

        test "missing public read capability refuses every topic before provider access" do
          provider = Object.new
          def provider.method_missing(*) = raise("provider must not be read without capability")
          reader = ReferenceRead.new(organization: @organization, budget: provider, gazette: provider, donations: provider)
          %w(budget gazette donation).each do |topic|
            result = reader.call(topic:, entities: {}, context: context(capabilities: []), locale: "sr")
            assert_equal "not_authorized", result[:status]
            assert_empty result.fetch(:facts, [])
          end
        end

        test "all required locales retain the reviewed act identity and legal limitations" do
          %w(sr sr-Cyrl bs hr).each do |locale|
            result = ReferenceRead.new(organization: @organization)
                                  .call(topic: "gazette", entities: { "query" => "TEST-ACT-2040-A" }, context: context, locale:)
            row = result.fetch(:facts).find { |fact| fact["kind"] == "gazette_act" }
            assert row, locale
            assert_equal "TEST-ACT-2040-A", row.fetch("provider_act_id"), locale
            assert_equal SyntheticGazetteActs::ISSUE_HASH, row.fetch("source_content_hash"), locale
            assert_equal "https://community.example.invalid/authored-issue.pdf#page=3", row.fetch("source_url"), locale
            assert_equal [3], row.fetch("source_pdf_pages"), locale
            assert_equal "2040-03-09", row.fetch("published_on"), locale
            assert_equal "2040-03-10", row.fetch("effective_from"), locale
            assert_equal "not_verified", row.fetch("current_legal_status"), locale
            assert_includes row.fetch("warning_codes"), "decision_supersession_not_verified", locale
            if locale == "sr-Cyrl"
              assert_includes row.fetch("text"), "садашње важење нису потврђени"
            else
              assert_includes row.fetch("text"), "sadašnje važenje nisu potvrđeni"
            end
          end
        end

        test "a parser total is never promoted to a reviewed headline without explicit metadata" do
          ENV.delete("MI_BUDGET_HEADLINE_TOTAL")
          # The real parser still detects 999999; that alone must not make it a
          # reviewed grand total. A table subtotal has the same parser shape.
          assert_equal 999_999, DecidimApp::Bijeljina::Budget.default.total
          result = ReferenceRead.new(organization: @organization)
                                .call(topic: "budget", entities: {}, context: context, locale: "sr")
          assert_equal "ok", result[:status]
          assert result.fetch(:facts).all? { |row| row["kind"] == "budget_allocation" }
          assert_includes result.fetch(:warnings), "budget_headline_not_reviewed"
          assert_equal false, result.fetch(:validity).fetch("complete_budget")
          assert_equal false, result.fetch(:validity).fetch("executed_spending")
        end

        test "unreviewed table pages never inherit a page from another community" do
          ENV.delete("MI_BUDGET_TABLE_PAGE")
          result = ReferenceRead.new(organization: @organization)
                                .call(topic: "budget", entities: {}, context: context, locale: "sr")
          assert_equal "ok", result[:status]
          assert_empty result.fetch(:coverage).fetch("table_pages")
          assert result.fetch(:facts).none? { |row| row.key?("source_pdf_page") }
          assert_includes result.fetch(:warnings), "budget_table_page_not_reviewed"
        end

        test "unconfigured sources do not produce budget facts or raise a citizen error" do
          ENV.delete("MI_BUDGET_SOURCE_URL")
          result = ReferenceRead.new(organization: @organization)
                                .call(topic: "budget", entities: {}, context: context, locale: "sr")
          assert_equal "unavailable", result[:status]
          assert_empty result.fetch(:facts)
          assert_includes result.fetch(:warnings), "budget_source_not_configured"
        end

        test "future budget review dates cannot establish reviewed facts" do
          swap_service_constant(DecidimApp::Bijeljina::Budget, :SOURCE_CAPTURED_ON, Date.new(2040, 9, 17))
          result = ReferenceRead.new(organization: @organization)
                                .call(topic: "budget", entities: {}, context: context, locale: "sr")
          assert_equal "unavailable", result[:status]
          assert_empty result.fetch(:facts)
          assert_includes result.fetch(:warnings), "budget_review_in_future"
        end

        test "a parsed document from another year is withheld despite matching requested metadata" do
          swap_service_constant(DecidimApp::Bijeljina::Budget, :YEAR, 2041)
          result = ReferenceRead.new(organization: @organization)
                                .call(topic: "budget", entities: { "date" => "2041-01-01" }, context: context, locale: "sr")
          assert_equal "unavailable", result[:status]
          assert_empty result.fetch(:facts)
          assert_includes result.fetch(:warnings), "budget_document_not_reviewed_for_year"
        end

        test "future gazette review dates never establish reviewed issue or act facts" do
          swap_service_constant(DecidimApp::Bijeljina::GazetteData, :SOURCE_CAPTURED_ON, Date.new(2040, 9, 17))
          result = ReferenceRead.new(organization: @organization)
                                .call(topic: "gazette", entities: { "query" => "TEST-ACT-2040-A" }, context: context, locale: "sr")
          assert_equal "unavailable", result[:status]
          assert_empty result.fetch(:facts)
          assert_includes result.fetch(:warnings), "gazette_review_in_future"
        end

        private

        def synthetic_other_publisher(reviewed:)
          row = { number: SyntheticGazetteActs::ISSUE_NUMBER, title: "Autorsko izdanje drugog izdavača",
                  url: "https://other-publisher.example.invalid/issue.pdf" }
          index = Decidim::Bih::City::GazetteIndex.new([row])
          publisher = Object.new
          publisher.define_singleton_method(:index) { index }
          publisher.define_singleton_method(:source_url) { "https://other-publisher.example.invalid/archive" }
          publisher.define_singleton_method(:index_checked_on) { Date.new(2040, 9, 15) } if reviewed
          publisher
        end

        def context(capabilities: ["public_reads"])
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "a" * 64, now: @now,
            capabilities:, deadline: Decidim::Bih::Concierge::Dialogue::TurnBudget.new
          )
        end
      end
    end
  end
end
