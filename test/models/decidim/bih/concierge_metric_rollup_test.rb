# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Database-backed contract of the rollup row: bounded vocabularies, the
    # latency-bucket/kind rule, and a unique index that treats NULL latency
    # buckets as equal so the nightly upsert cannot stack duplicate answer rows.
    class ConciergeMetricRollupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @day = Date.new(2026, 9, 12)
      end

      def build(**attributes)
        ConciergeMetricRollup.new(
          { organization: @organization, day: @day, kind: "answer", topic: "water", label: "answered", count: 3 }.merge(attributes)
        )
      end

      test "answer, read and stage rows validate against their own vocabularies" do
        assert_predicate build, :valid?
        assert_predicate build(kind: "answer_detail", facet: "fee", traffic_kind: "synthetic"), :valid?
        assert_not_predicate build(facet: "private question"), :valid?
        assert_not_predicate build(traffic_kind: "citizen"), :valid?
        assert_predicate build(kind: "read", label: "ok", latency_bucket: "250"), :valid?
        assert_predicate build(kind: "stage", topic: "understanding", label: "completed", latency_bucket: "overflow"), :valid?

        assert_not_predicate build(kind: "conversation"), :valid?
        assert_not_predicate build(topic: "Private street"), :valid?
        assert_not_predicate build(label: "Private reply"), :valid?
        assert_not_predicate build(kind: "read", label: "answered", latency_bucket: "250"), :valid?
        assert_not_predicate build(kind: "stage", topic: "water", label: "completed", latency_bucket: "10"), :valid?
        assert_not_predicate build(count: -1), :valid?
        assert_not_predicate build(count: 1.5), :valid?
      end

      test "latency buckets belong to histograms only and come from the fixed list" do
        assert_not_predicate build(latency_bucket: "250"), :valid?
        assert_not_predicate build(kind: "read", label: "ok"), :valid?
        assert_not_predicate build(kind: "read", label: "ok", latency_bucket: "251"), :valid?
      end

      test "release sha is a full commit id or nil and prompt version is a positive integer or nil" do
        assert_predicate build(release_sha: "a" * 40, prompt_version: 1), :valid?
        assert_predicate build(release_sha: nil, prompt_version: nil), :valid?
        assert_not_predicate build(release_sha: "abc123"), :valid?
        assert_not_predicate build(release_sha: "g" * 40), :valid?
        assert_not_predicate build(prompt_version: 0), :valid?
      end

      test "the unique index treats a null latency bucket as a value" do
        build.save!

        assert_raises(ActiveRecord::RecordNotUnique) { build(count: 9).save! }
        assert_predicate build(label: "fallback"), :valid?
        assert_nothing_raised { build(label: "fallback").save! }
      end

      test "detail uniqueness includes facet provenance and capture release while legacy uniqueness is unchanged" do
        build(kind: "answer_detail", facet: "status", release_sha: "a" * 40).save!
        build(kind: "answer_detail", facet: "status", release_sha: "b" * 40).save!
        build(kind: "answer_detail", facet: "fee", release_sha: "a" * 40).save!
        build(kind: "answer_detail", facet: "status", traffic_kind: "synthetic", release_sha: "a" * 40).save!
        assert_raises(ActiveRecord::RecordNotUnique) { build(kind: "answer_detail", facet: "status", release_sha: "a" * 40).save! }
        build(release_sha: "a" * 40).save!
        assert_raises(ActiveRecord::RecordNotUnique) { build(release_sha: "b" * 40).save! }
      end

      test "the database refuses a negative count even without validations" do
        row = build
        row.save!

        assert_raises(ActiveRecord::StatementInvalid) { row.update_column(:count, -1) } # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end
end
