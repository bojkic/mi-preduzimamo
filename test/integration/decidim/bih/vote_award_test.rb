# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module Goodwill
      # Proposal votes have no AS notification in 0.31.5, so the award is wired via
      # an after_create_commit override on Decidim::Proposals::ProposalVote.
      class VoteAwardTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        test "voting on a proposal awards the voter the schedule's vote points" do
          organization = create_organization
          author = FactoryBot.create(:user, :confirmed, organization:)
          component = FactoryBot.create(:proposal_component, organization:)
          proposal = FactoryBot.create(:proposal, component:)

          perform_enqueued_jobs do
            FactoryBot.create(:proposal_vote, proposal:, author:)
          end

          assert_equal 2, Decidim::Bih::Goodwill::Ledger.new.account_for(author).contribution_score
        end
      end
    end
  end
end
