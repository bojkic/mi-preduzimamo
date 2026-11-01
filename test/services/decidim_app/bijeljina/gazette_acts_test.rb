# frozen_string_literal: true

require "minitest/autorun"
require "active_support/core_ext/hash/keys"
require_relative "../../../../app/services/decidim_app/bijeljina/gazette_acts"
require_relative "../../../support/synthetic_gazette_acts"

module DecidimApp
  module Bijeljina
    class GazetteActsTest < Minitest::Test
      include SyntheticGazetteActs
      def setup = install_synthetic_gazette_acts
      def teardown = restore_synthetic_gazette_acts
      def test_reviewed_acts_are_bound_to_exact_issue_and_revision
        act = GazetteActs.all.fetch(0)
        # This authored issue contains two acts sharing one exact PDF revision.
        assert_equal synthetic_gazette_acts, GazetteActs.for_issue(number: act[:issue_number], content_hash: act[:issue_content_hash])
        assert_empty GazetteActs.for_issue(number: act[:issue_number], content_hash: "changed_pdf")
        assert_empty GazetteActs.for_issue(number: "09/2040", content_hash: act[:issue_content_hash])
        assert_empty GazetteActs.for_issue(number: act[:issue_number], content_hash: nil)
      end

      def test_act_identifiers_pages_and_publication_are_distinct_from_adoption
        act = GazetteActs.all.fetch(0)
        assert_equal "TEST-ACT-2040-A", act[:provider_act_id]
        assert_equal [3], act[:source_pdf_pages]
        assert_equal "2040-03-10", act[:effective_from]
        assert_equal "2040-03-09", act[:published_on]
        assert_equal "not_verified", act[:current_legal_status]
        assert_match(/#page=3\z/, act[:source_url])
      end

      def test_unknown_revision_never_matches_even_a_broken_record_with_the_same_missing_hash
        original = synthetic_gazette_acts.first
        [nil, "", "not-a-revision", "a" * 63, 123].each do |hash|
          GazetteActs.instance_variable_set(:@all, [original.merge(issue_content_hash: hash)].freeze)
          assert_empty GazetteActs.for_issue(number: original.fetch(:issue_number), content_hash: hash)
        end
      end

      def test_unconfigured_act_catalogue_does_not_inherit_reviewed_local_records
        owner = GazetteActs
        prior_path = owner::PATH
        owner.send(:remove_const, :PATH)
        owner.const_set(:PATH, "")
        owner.remove_instance_variable(:@all) if owner.instance_variable_defined?(:@all)
        assert_empty owner.all
        assert_empty owner.for_issue(number: SyntheticGazetteActs::ISSUE_NUMBER, content_hash: SyntheticGazetteActs::ISSUE_HASH)
      ensure
        owner.send(:remove_const, :PATH)
        owner.const_set(:PATH, prior_path)
      end

      def test_amendment_target_does_not_invent_an_act_identifier_or_current_law
        act = GazetteActs.all.fetch(-1)
        relation = act[:amends].first
        assert_nil relation[:provider_act_id]
        assert_equal false, relation[:target_identity_verified]
        assert_equal "amends", relation[:relationship]
        assert_equal "not_verified", act[:current_legal_status]
      end
    end
  end
end
