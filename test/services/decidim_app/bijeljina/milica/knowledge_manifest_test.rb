# frozen_string_literal: true

# rubocop:disable Rails/RefuteMethods -- standalone Minitest, no Rails assertions

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", ">= 5.1", "< 6"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../../../support/synthetic_public_knowledge"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/public_filesystem_knowledge"

class KnowledgeManifestTest < Minitest::Test
  Manifest = DecidimApp::Bijeljina::Milica::KnowledgeManifest
  Filesystem = DecidimApp::Bijeljina::Milica::PublicFilesystemKnowledge
  ROOT = File.expand_path("../../../../..", __dir__)
  DAY = Date.new(2040, 4, 9)

  def setup
    @fixture_root = Dir.mktmpdir("synthetic-knowledge-manifest-")
    SyntheticPublicKnowledge.write(root: @fixture_root, day: DAY)
    @projection = Filesystem.new(root: @fixture_root).call(organization_id: 1, as_of: DAY)
    @record = Marshal.load(Marshal.dump(@projection.fetch(:records).find { |item| item["eligibility"] == "ready" }))
  end

  def teardown
    FileUtils.remove_entry(@fixture_root) if @fixture_root && File.directory?(@fixture_root)
  end

  def build(records = [@record], **)
    Manifest.new(organization_id: 1, as_of: DAY, **).build(records:, inventory: @projection.fetch(:inventory))
  end

  def test_synthetic_reviewed_sources_preserve_provenance_and_exclude_unpublishable_and_live_event
    output = build(@projection.fetch(:records))
    assert_operator output.fetch("documents").size, :>, 30
    assert_equal false, output["complete"]
    assert_equal "unknown", output.dig("token_measurement", "status")
    assert_nil output.dig("totals", "body_tokens")
    assert_nil output.dig("totals", "prompt_tokens")
    assert output["runtime_eligibility_recheck_required"]
    reasons = output["excluded"].map { |row| row["reason"] }
    assert_includes reasons, "not_public"
    assert_includes reasons, "current_announcement_requires_live_reader"
    refute_includes JSON.generate(output["documents"]), "synthetic_private_technician"
    assert(output.dig("domains", "volunteer", "inventory").any? { |item| item["status"] == "database_inventory_not_performed" && item["count"].nil? })
    assert(output.dig("domains", "transport", "inventory").any? { |item| item["reason"].to_s.include?("authoritative_tools") })
    heating = output["documents"].find { |row| row["domain"] == "heating" }
    refute_empty heating.dig("coverage", "domain_limitations")
    refute_empty heating["source_locator"]
    assert_match(/\A[0-9a-f]{64}\z/, heating["revision"])
    assert_match(/\A[0-9a-f]{64}\z/, heating.dig("coverage", "repository_file_sha256"))
  end

  def test_tenant_privacy_review_and_expiry_are_enforced_before_text_enters_manifest
    variants = [{ "public" => false }, { "organization_id" => 2 }, { "review_status" => "revoked" },
                { "review_status" => "draft" }, { "review_expires_at" => DAY.iso8601 },
                { "reviewed_at" => (DAY + 1).iso8601 }, { "published_at" => (DAY + 1).iso8601 }]
    variants.each do |changes|
      record = @record.merge(changes).merge("body" => "DO NOT EXPORT THIS TEXT")
      result = build([record])
      assert_empty result["documents"], changes.inspect
      refute_includes JSON.generate(result), "DO NOT EXPORT THIS TEXT"
      assert_equal 1, result["excluded"].size
    end
  end

  def test_malformed_source_url_is_excluded_without_exporting_prose
    result = build([@record.merge("source_url" => "https://invalid host/", "body" => "INVALID SOURCE PROSE")])
    assert_empty result["documents"]
    assert_equal "invalid_source_metadata", result["excluded"].first["reason"]
    refute_includes JSON.generate(result), "INVALID SOURCE PROSE"
  end

  def test_effective_end_semantics_and_future_occurrence_are_distinct_from_freshness
    assert_empty build([@record.merge("effective_until" => DAY.iso8601)])["documents"]
    assert_equal 1, build([@record.merge("effective_until" => DAY.iso8601, "end_exclusive" => false)])["documents"].size
    assert_equal 1, build([@record.merge("occurs_from" => (DAY + 60).iso8601)])["documents"].size
    assert_empty build([@record.merge("effective_from" => (DAY + 1).iso8601)])["documents"]
  end

  def test_duplicate_revision_is_collapsed_but_different_citations_survive
    result = build([@record, @record.dup])
    assert_equal 1, result["documents"].size
    assert_equal 1, result["duplicate_revisions_removed"]
    other = @record.merge("document_id" => "another-source", "source_id" => "second-publisher", "source_url" => "https://example.org/public")
    result = build([@record, other])
    assert_equal 2, result["documents"].size
    assert_operator result.dig("totals", "body_words"), :>, result.dig("totals", "deduplicated_prose_words")
    assert_empty build([@record, @record.merge("body" => "A contradictory revision")])["documents"]
    assert_equal "conflicting_document_revisions", build([@record, @record.merge("body" => "changed")])["excluded"].first["reason"]
  end

  def test_release_identity_covers_qualifiers_and_is_order_independent_and_immutable
    other = @record.merge("document_id" => "other")
    assert_equal build([@record, other])["release_id"], build([other, @record])["release_id"]
    refute_equal build["release_id"], build([@record.merge("limitations" => ["Not valid on Sunday"])])["release_id"]
    result = build
    assert_raises(FrozenError) { result["documents"].first["body"].replace("changed") }
    refute @record["body"].frozen?
    @record["body"].replace("caller can still mutate its input")
    refute_equal @record["body"], result["documents"].first["body"]
  end

  def test_exact_injected_tokenizer_counts_full_prompt_and_bodies_separately
    tokenizer = { "model" => "test-only-character-model", "tokenizer" => "unicode-codepoints", "version" => "1" }
    # Synthetic exact tokenizer verifies the protocol, never a Gemini estimate.
    output = build(tokenizer:, token_counter: ->(text) { text.codepoints.size })
    assert_equal "exact", output.dig("token_measurement", "status")
    assert_equal @record["body"].codepoints.size, output.dig("totals", "body_tokens")
    assert_operator output.dig("totals", "prompt_tokens"), :>, output.dig("totals", "body_tokens")
    assert_equal output.dig("totals", "prompt_tokens") - output.dig("totals", "body_tokens"), output.dig("totals", "prompt_overhead_tokens")
    assert_raises(Manifest::Invalid) { build(token_counter: ->(_) { 1 }) }
    assert_raises(Manifest::Invalid) { build(tokenizer:, token_counter: ->(_) { 1.5 }) }
  end

  def test_tampered_review_chain_never_becomes_public_evidence
    with_files do |root|
      path = File.join(root, "config/bijeljina/citizen_reference_facts.yml")
      data = YAML.safe_load_file(path)
      data.fetch("facts").first["text"] = "TAMPERED SOURCE CLAIM"
      File.write(path, YAML.dump(data))
      input = Filesystem.new(root:).call(organization_id: 1, as_of: DAY)
      result = build(input.fetch(:records))
      refute_includes JSON.generate(result), "TAMPERED SOURCE CLAIM"
      assert(result["excluded"].any? { |row| row["reason"] == "unreviewed" })
    end
  end

  def test_filesystem_allowlist_does_not_scan_private_files_and_rejects_escape
    with_files do |root|
      File.write(File.join(root, ".env"), "PRIVATE_SENTINEL")
      input = Filesystem.new(root:).call(organization_id: 1, as_of: DAY)
      refute_includes JSON.generate(input), "PRIVATE_SENTINEL"
      relative = Filesystem::FILES.first
      File.unlink(File.join(root, relative))
      Dir.mktmpdir("outside-synthetic-knowledge-") do |outside|
        target = File.join(outside, "outside.yml")
        File.write(target, "version: 1")
        File.symlink(target, File.join(root, relative))
        assert_raises(Manifest::Invalid) { Filesystem.new(root:).call(organization_id: 1, as_of: DAY) }
      end
    end
  end

  def test_procedure_fee_unknowns_and_conditions_are_kept_as_one_document
    output = build(@projection.fetch(:records))
    record = output["documents"].find { |item| item["document_id"] == "bijeljina:procedure:synthetic-permit" }
    body = JSON.parse(record.fetch("body"))
    assert_equal 0, body.dig("fee", "administrative_fee_bam")
    assert_nil body.dig("fee", "postage_amount_bam")
    assert_equal "postage", body.dig("fee", "delivery_cost")
    assert_nil body["processing_time"]
    assert body["steps"].any?
  end

  def test_absent_optional_sources_do_not_invent_records_or_complete_inventory
    Dir.mktmpdir("empty-public-knowledge-") do |root|
      projection = Filesystem.new(root:).call(organization_id: 1, as_of: DAY)
      assert_empty projection.fetch(:records)
      assert_empty projection.fetch(:files)
      assert projection.fetch(:inventory).none? { |row| row["status"] == "local_projection_available" }
      output = build(projection.fetch(:records))
      assert_empty output.fetch("documents")
      assert_equal false, output.fetch("complete")
    end
  end

  def test_present_malformed_or_oversized_sources_are_rejected
    with_files do |root|
      path = File.join(root, Filesystem::FILES.first)
      File.write(path, "version: [invalid")
      assert_raises(Psych::SyntaxError) { Filesystem.new(root:).call(organization_id: 1, as_of: DAY) }
      File.write(path, "x" * 2_000_001)
      assert_raises(Manifest::Invalid) { Filesystem.new(root:).call(organization_id: 1, as_of: DAY) }
    end
  end

  private

  def with_files
    Dir.mktmpdir("knowledge-manifest-test") do |root|
      SyntheticPublicKnowledge.write(root:, day: DAY)
      yield root
    end
  end
end

# rubocop:enable Rails/RefuteMethods
