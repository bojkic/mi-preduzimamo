# frozen_string_literal: true

# Community-support projects use a native Budget component only as an internal
# storage seam. Keep that component available to the approval workflow while
# removing its empty parent process from citizen-facing participatory-process
# discovery. The dedicated /biceriseno/projekti surface remains public.
class SeparateCommunityProjectsFromParticipatoryBudgeting < ActiveRecord::Migration[7.2]
  BIJELJINA_HOST = "mi.fondacijabijeljina.com"

  def up
    organization = Decidim::Organization.find_by(host: BIJELJINA_HOST)
    return say("Bijeljina organization is not present; community-project storage remains manual") unless organization

    budget = DecidimApp::Bijeljina::CommunityProjectsSetup.call(
      organization:,
      publish: true
    )
    say(
      "Community-support storage separated: " \
      "process_published=#{budget.participatory_space.published?} " \
      "component_published=#{budget.component.published?}"
    )
  end

  def down
    say("Community-project storage remains unpublished; do not recreate the product mix-up automatically")
  end
end
