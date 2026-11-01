# frozen_string_literal: true

# Installs the one long-lived community-project catalog for the existing
# Bijeljina tenant and moves the five established Odoo campaign mappings into
# the canonical database-backed link table. Both setup services are idempotent;
# the migration therefore remains safe if an operator prepared the catalog
# before deploying this release.
class BootstrapBijeljinaCommunityProjects < ActiveRecord::Migration[7.2]
  BIJELJINA_HOST = "mi.fondacijabijeljina.com"

  def up
    organization = Decidim::Organization.find_by(host: BIJELJINA_HOST)
    return say("Bijeljina organization is not present; first-run setup remains manual") unless organization

    DecidimApp::Bijeljina::CommunityProjectsSetup.call(organization:, publish: true)
    links = DecidimApp::Bijeljina::ProjectDonationLinksSetup.call(organization:)
    say("Community project catalog installed with #{links.size} legacy donation links")
  end

  # The migration creates durable public content and mappings. Rolling the
  # schema back must not silently delete them; operators can unpublish the
  # process or deactivate individual links through an intentional data change.
  def down
    say("Community project catalog data retained")
  end
end
