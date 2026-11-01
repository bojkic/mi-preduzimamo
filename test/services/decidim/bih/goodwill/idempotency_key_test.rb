# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Characterization test for Decidim::Bih::Goodwill::IdempotencyKey.
      #
      # These keys are a DURABLE contract — they are persisted on existing
      # transactions and compared on every award. The exact strings asserted
      # below are the historical literals that previously lived inline at each
      # award site (event_subscriptions, proposal/budget vote overrides); they
      # MUST stay byte-identical or the dedup guard breaks and citizens get
      # double-awarded. Any failure here is a behaviour change, not a flake.
      class IdempotencyKeyTest < ActiveSupport::TestCase
        test "comment key matches the historical literal" do
          assert_equal "comment:42", IdempotencyKey.comment(42)
        end

        test "proposal key matches the historical literal" do
          assert_equal "proposal:7:author:3", IdempotencyKey.proposal(7, 3)
        end

        test "like key matches the historical literal with a gid" do
          gid = "gid://decidim/Decidim::Proposals::Proposal/9"
          assert_equal "like:#{gid}:liker:5", IdempotencyKey.like(gid, 5)
        end

        test "like key tolerates a nil resource gid (interpolates empty)" do
          # The original literal was "like:#{resource&.to_gid}:liker:#{liker.id}",
          # so a nil resource produced "like::liker:5" — preserve that exactly.
          assert_equal "like::liker:5", IdempotencyKey.like(nil, 5)
        end

        test "debate key matches the historical literal" do
          assert_equal "debate:11:author:4", IdempotencyKey.debate(11, 4)
        end

        test "proposal_vote key matches the historical literal" do
          assert_equal "proposal_vote:8:voter:2", IdempotencyKey.proposal_vote(8, 2)
        end

        test "budget_vote key matches the historical literal" do
          assert_equal "budget_vote:6:voter:1", IdempotencyKey.budget_vote(6, 1)
        end
      end
    end
  end
end
