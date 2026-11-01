# frozen_string_literal: true

Rails.application.config.to_prepare do
  {
    Decidim::Proposals::Permissions => DecidimApp::Bijeljina::RaceProjectPermissions,
    Decidim::Proposals::ProposalVote => DecidimApp::Bijeljina::RaceProjectVoteOverride,
    Decidim::Proposals::VoteProposal => DecidimApp::Bijeljina::RaceProjectVoteCommand,
    Decidim::Bih::ContentBlocks::MiHeroCell => DecidimApp::Bijeljina::RaceProjectHeroOverride
  }.each do |base, extension|
    base.prepend(extension) unless base < extension
  end
end
