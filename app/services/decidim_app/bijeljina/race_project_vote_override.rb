# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module RaceProjectVoteOverride
      def self.prepended(base)
        base.validate :validate_race_project_vote, on: :create
      end

      private

      def validate_race_project_vote
        return unless proposal && RaceProjectSelection.component?(proposal.component)

        unless RaceProjectSelection.vote_allowed?(author, proposal.component)
          errors.add(:proposal, I18n.t("mi_race_projects.vote_ineligible"))
          return
        end
        votes = Decidim::Proposals::ProposalVote.where(
          author:, proposal: Decidim::Proposals::Proposal.where(component: proposal.component)
        )
        errors.add(:proposal, I18n.t("mi_race_projects.one_vote")) if votes.exists?
      end
    end

    # Decidim checks its vote limit before writing. Serialize this campaign's
    # commands per voter so concurrent votes for different proposals cannot
    # consume the same one-vote allowance twice.
    module RaceProjectVoteCommand
      def call
        return super unless @current_user && RaceProjectSelection.component?(@proposal&.component)

        @current_user.with_lock { super }
      end
    end
  end
end
