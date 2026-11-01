# frozen_string_literal: true

# Decidim already requires SMS authorization for campaign proposal creation and
# voting. This action authorizer adds the dynamic own-Komšiluk check after the
# standard SMS check succeeds.
Rails.application.config.after_initialize do
  sms_workflow = Decidim::Verifications.find_workflow_manifest(:sms)
  if sms_workflow
    sms_workflow.action_authorizer =
      "DecidimApp::Bijeljina::KomsilukNamingActionAuthorizer"
  end
end

Rails.application.config.to_prepare do
  require_dependency "decidim_app/bijeljina/komsiluk_naming_proposal_form_override"
  require_dependency "decidim_app/bijeljina/komsiluk_naming_proposal_vote_override"

  form_override = DecidimApp::Bijeljina::KomsilukNamingProposalFormOverride
  vote_override = DecidimApp::Bijeljina::KomsilukNamingProposalVoteOverride

  Decidim::Proposals::ProposalForm.prepend(form_override) unless form_override > Decidim::Proposals::ProposalForm
  Decidim::Proposals::ProposalVote.prepend(vote_override) unless vote_override > Decidim::Proposals::ProposalVote
end
