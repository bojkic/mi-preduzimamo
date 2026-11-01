# frozen_string_literal: true

require "test_helper"
require_relative "../support/synthetic_public_catalogs"

class MilicaBudgetSnapshotToolsTest < ActiveSupport::TestCase
  include SyntheticPublicCatalogs
  Host = DecidimApp::Bijeljina
  Dialogue = Decidim::Bih::Concierge::Dialogue

  setup do
    install_synthetic_public_catalogs
    @organization = create_organization
    @now = Time.utc(2040, 9, 16, 6)
    # A budget request must never fall back to legacy question filtering.
    reader = Object.new
    reader.define_singleton_method(:public_capability) { |**| raise "Unexpected legacy dispatch" }
    @bundle = Host::Milica::ConversationTools.new(organization: @organization, read_port: reader, clock: -> { @now })
    @context = Dialogue::Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "b" * 64,
                                                       capabilities: ["public_reads"], now: @now, deadline: Dialogue::TurnBudget.new)
  end

  teardown { restore_synthetic_public_catalogs }

  test "one evidence record preserves all allocations and the distinct headline" do
    result = read("query" => "budžet za građane 2040 Izmišljeni centar", "fiscal_year" => 2040)
    assert_equal "ok", result.status
    assert_equal 1, result.evidence.size
    fact = source_fact(result)
    assert_equal 5, fact.fetch("allocations").size
    rows = fact.fetch("allocations").index_by { |row| row.fetch("category") }
    assert_equal 12_345, rows.fetch("Измишљени центар").fetch("amount")
    assert_equal 45_678, rows.fetch("Измишљена заштита").fetch("amount")
    assert_equal 999_999, fact.fetch("headline_total")
    assert_equal(172_835, fact.fetch("allocations").sum { |row| row.fetch("amount") })
    assert_equal "BAM", fact.fetch("currency")
    assert_equal 2040, fact.fetch("fiscal_year")
    assert_equal "2040-09-14", fact.fetch("source_captured_on")
    assert_equal true, fact.fetch("partial_table")
    assert_equal true, fact.fetch("planned_not_paid")
    assert_equal true, fact.fetch("allocations_do_not_balance_headline")
    assert(fact.fetch("allocations").all? { |row| row.fetch("source_pdf_page") == 8 })
    assert_equal false, result.coverage_complete
    assert result.for_prompt(context: @context, eligibility: @bundle.eligibility)
  end

  test "query phrasing and reply script never filter the prepared table" do
    first = read("query" => "budžet za građane 2040")
    second = read("query" => "Колико је планирано за Измишљени центар?")
    assert_equal first.evidence, second.evidence
    assert_equal 5, source_fact(second).fetch("allocations").size
    assert_not_equal first.query_scope, second.query_scope
  end

  test "unavailable fiscal year is unsupported without old figures or a zero" do
    result = read("fiscal_year" => 2041)
    assert_equal "unsupported", result.status
    assert_empty result.evidence
    assert_includes result.warnings, "budget_year_not_available"
    assert result.for_prompt(context: @context, eligibility: @bundle.eligibility)
  end

  test "current year default and explicit historical year are separate" do
    @now = Time.utc(2041, 1, 1, 12)
    @context = @context.with(now: @now)
    assert_equal "unsupported", read.status
    explicit = read("fiscal_year" => 2040)
    assert_equal "ok", explicit.status
    assert_equal "2040-09-14", source_fact(explicit).fetch("source_captured_on")
  end

  test "capture cannot become reviewed evidence before its actual date" do
    @now = Time.utc(2040, 9, 13, 12)
    @context = @context.with(now: @now)
    result = read("fiscal_year" => 2040)
    assert_equal "unreviewed", result.status
    assert_empty result.evidence
    assert_includes result.warnings, "budget_capture_after_requested_time"
  end

  test "source change invalidates earlier evidence at prompt and send recheck" do
    result = read
    original = File.read(Host::Budget::BUNDLED_TEXT_PATH)
    changed = original.sub("12.345,00", "12.346,00")
    native_read = File.method(:read)
    File.stub(:read, ->(path, *args) { path == Host::Budget::BUNDLED_TEXT_PATH ? changed : native_read.call(path, *args) }) do
      assert_raises(Dialogue::Contracts::Invalid) { result.for_prompt(context: @context, eligibility: @bundle.eligibility) }
      fresh = read
      assert_not_equal result.evidence.first.fetch("revision"), fresh.evidence.first.fetch("revision")
    end
  end

  test "budget cannot bypass public authority or use untyped years" do
    assert_raises(Dialogue::Contracts::Invalid) { read("fiscal_year" => "2040") }
    assert_raises(Dialogue::Contracts::Invalid) { read("fiscal_year" => 2200) }
    @context = @context.with(organization_id: @organization.id + 1)
    assert_raises(Dialogue::Contracts::Invalid) { read }
    result = Host::Milica::BudgetSnapshotRead.new(organization: @organization).call(context: @context, fiscal_year: 2040)
    assert_equal "not_authorized", result.fetch(:status)
    assert_empty result.fetch(:facts, [])
  end

  test "fiscal year cannot silently leak into a nonbudget reader" do
    assert_raises(Dialogue::Contracts::Invalid) do
      @bundle.registry.call(name: "read_reference", arguments: { "topic" => "gazette", "fiscal_year" => 2040 },
                            context: @context, eligibility: @bundle.eligibility)
    end
  end

  test "catalog metadata lists actual policy subjects and distinguishes document search" do
    declarations = @bundle.registry.declarations.index_by { |row| row.fetch("name") }
    policy = declarations.fetch("read_platform_guidance")
    assert_equal Host::Milica::PlatformGuidanceTools::READ_SUBJECTS, policy.dig("parameters", "properties", "subject", "enum")
    assert_includes policy.fetch("description"), "Public policy, not private state"
    search = declarations.fetch("search_public_knowledge").fetch("description")
    assert_includes declarations.fetch("read_reference").dig("parameters", "properties", "topic", "enum"), "budget"
    assert_includes search, "use their named readers"
    assert_includes search, "Empty means no eligible matches in this partial search"
    assert_includes search, "Never infer other readers lack facts"
  end

  test "missing headline metadata never promotes the partial parser total to the whole budget" do
    ENV.delete("MI_BUDGET_HEADLINE_TOTAL")
    result = read
    assert_equal "ok", result.status
    fact = source_fact(result)
    assert_equal 5, fact.fetch("allocations").size
    assert_equal false, fact.fetch("headline_reviewed")
    assert_not fact.key?("headline_total")
    assert_not fact.key?("allocations_do_not_balance_headline")
    assert_includes result.warnings, "budget_headline_not_reviewed"
  end

  test "missing reviewed page never inherits a page from another community" do
    ENV.delete("MI_BUDGET_TABLE_PAGE")
    result = read
    assert_equal "ok", result.status
    assert source_fact(result).fetch("allocations").all? { |row| !row.key?("source_pdf_page") }
    assert_includes result.warnings, "budget_table_page_not_reviewed"
  end

  test "document year mismatch and unavailable source cannot yield reviewed allocations" do
    path = Host::Budget::BUNDLED_TEXT_PATH
    File.write(path, File.read(path).sub("2040", "2041"))
    result = read
    assert_equal "unreviewed", result.status
    assert_empty result.evidence
    assert_includes result.warnings, "budget_document_not_reviewed_for_year"
    File.unlink(path) # Task-owned authored fixture; no runtime/source data.
    result = read
    assert_equal "unavailable", result.status
    assert_empty result.evidence
    assert_includes result.warnings, "budget_source_not_configured"
  end

  test "invalid UTF-8 and oversized snapshots are unavailable before parsing" do
    ["\xFF".b, "x" * (Host::Milica::BudgetSnapshotRead::MAX_BYTES + 1)].each do |bytes|
      File.binwrite(Host::Budget::BUNDLED_TEXT_PATH, bytes)
      result = read
      assert_equal "unavailable", result.status
      assert_empty result.evidence
      assert_includes result.warnings, "budget_snapshot_invalid"
    end
  end

  private

  def read(arguments = {})
    @bundle.registry.call(name: "read_reference", arguments: { "topic" => "budget" }.merge(arguments),
                          context: @context, eligibility: @bundle.eligibility)
  end

  def source_fact(result)
    result.evidence.first.fetch("facts").fetch("source_fact")
  end
end
