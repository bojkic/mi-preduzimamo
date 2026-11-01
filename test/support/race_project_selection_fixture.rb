# frozen_string_literal: true

require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"

module RaceProjectSelectionFixture
  def prepare_race_projects(city_name: "Izmišljeni gradski vrt", rural_name: "Izmišljeno seosko polje", community_name: nil, budget_bam: "1234.50")
    travel_to Time.utc(2026, 9, 27, 10)
    @organization = create_organization(available_authorizations: ["sms"])
    @organization.update!(name: { "sr" => community_name }) if community_name
    %w(mi_hero highlighted_content_banner).each_with_index do |manifest, i|
      Decidim::ContentBlock.create!(organization: @organization, scope_name: "homepage", manifest_name: manifest, weight: i + 1, published_at: Time.current)
    end
    Decidim::Bih::Setting.put(@organization, "race_projects", "project_budget_bam", budget_bam)
    @admin = create(:user, :confirmed, :admin, organization: @organization)
    @citizen = create(:user, :confirmed, organization: @organization)
    @rural_citizen = create(:user, :confirmed, organization: @organization)
    @city = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "synthetic-city", zona: "grad", name: { "sr" => city_name })
    @rural = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "synthetic-rural", zona: "selo", name: { "sr" => rural_name })
    [[@citizen, @city], [@rural_citizen, @rural]].each do |user, area|
      create(:authorization, :granted, user:, name: "sms", granted_at: Time.current)
      Decidim::Bih::CitizenProfile.create!(organization: @organization, user:, komsiluk: area, source: "dropdown", assigned_at: Time.current)
    end
    @report = Decidim::Bih::Report.create!(organization: @organization, author: @citizen, description: "Isolated race fixture",
                                           status: "u_obradi", review_state: "needs_information")
    @review = Decidim::Bih::Race::Review.new(@organization)
    @review.baseline!(actor: @admin, reason: "Fixture baseline")
    travel_to Time.utc(2026, 10, 25, 15)
    @edition = @review.capture!
    @closeout = DecidimApp::Bijeljina::RaceProjectCloseout.new(
      organization: @organization, actor: @admin, reason: "Owner accepts current scoring unchanged; no appeals."
    )
    @preview = @closeout.preview
    @before_rows = @review.preview
    @result = @closeout.apply!(
      expected_snapshot_digest: @preview[:snapshot_digest], expected_rows_digest: @preview[:rows_digest],
      winners: { grad: @city.id, selo: @rural.id }
    )
    @process = @result.fetch(:process)
    @city_component, @rural_component = @result.fetch(:components)
  end

  def activate_project_voting
    @process.steps.where(active: true).each { |step| step.update!(active: false) }
    @process.steps.find_by!(position: 2).update!(active: true)
    @process.reload
    @city_component.reload
    @rural_component.reload
  end

  def project_proposal(component = @city_component)
    create(:proposal, component:, users: [@citizen])
  end
end
