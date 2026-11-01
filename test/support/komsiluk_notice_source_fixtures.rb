# frozen_string_literal: true

require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module KomsilukNoticeSourceFixtures
  def setup_notice_sources
    @organization = create_organization
    @admin = create(:user, :confirmed, :admin, organization: @organization)
    @area = Decidim::Bih::LocalArea.create!(
      organization: @organization, kind: "komsiluk", slug: "notice-source-area", name: { "sr" => "Provjereni komšiluk" },
      boundary: { type: "Polygon", coordinates: [[[19.0, 44.0], [20.0, 44.0], [20.0, 45.0], [19.0, 45.0], [19.0, 44.0]]] }
    )
    DecidimApp::Bijeljina::KomsilukSourceProjectionRefresh.install!
  end

  def reviewed_report(**attributes)
    Decidim::Bih::Report.create!(
      organization: @organization, description: "PRIVATE_REPORT_DESCRIPTION", ai_summary: "PRIVATE_AI_SUMMARY",
      internal_note: "PRIVATE_STAFF_NOTE", reporter_email: "private@example.invalid", reporter_phone: "+38765000000",
      category: Decidim::Bih::ReportTaxonomy::CATEGORIES.first.to_s,
      review_state: "validated", reviewed_at: Time.current, reviewed_by: @admin, **attributes
    )
  end

  def public_activity(**attributes)
    Decidim::Bih::VolunteerOpportunity.create!(
      organization: @organization, title: "Javna aktivnost", description: "Opis odobrene aktivnosti",
      active: true, review_status: "approved", reviewed_at: Time.current, reviewer: @admin,
      komsiluk: @area, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours,
      **attributes
    )
  end

  def public_partner
    Decidim::Bih::PartnerProfile.create!(
      organization: @organization, display_name: "Javni partner", slug: "notice-source-partner",
      kind: "association", verification_status: "verified", verified_at: Time.current,
      private_contact_email: "private-partner@example.invalid"
    )
  end

  def public_project
    @budget = DecidimApp::Bijeljina::CommunityProjectsSetup.call(organization: @organization, publish: true)
    @project = create(:project, budget: @budget, title: { "sr" => "Javni projekat" },
                                description: { "sr" => "<p>Isključivo javni opis projekta.</p>" }, budget_amount: 1000)
    @profile = public_partner
    @submission = Decidim::Bih::PartnerProjectSubmission.new(
      organization: @organization, project: @project, partner_profile: @profile,
      representative: @admin, reviewer: @admin, review_status: "approved", reviewed_at: Time.current,
      title: "PRIVATE_PROPOSAL_TITLE", description: "PRIVATE_PROPOSAL_DESCRIPTION", address: "PRIVATE_PROPOSAL_ADDRESS",
      budget_amount: 1000
    )
    @submission.save!(validate: false)
    @project_link = Decidim::Bih::ProjectDonationLink.create!(
      organization: @organization, project: @project, campaign_key: "source-project-#{@project.id}", active: true
    )
    @project
  end

  def source(kind, record, actor: @admin, organization: @organization)
    DecidimApp::Bijeljina::KomsilukNoticeSources.call(organization:, actor:, kind:, id: record.id)
  end

  def linked_post(kind, record, organization: @organization, **attributes)
    data = source(kind, record, organization:)
    Decidim::Bih::KomsilukPost.create!(
      organization:, komsiluk: @area, author: @admin, origin: "staff", category: "general",
      title: "Operator-approved wording", body: "Preserve this operator-approved body.",
      publication_key: SecureRandom.uuid, published_at: Time.current, expires_at: 7.days.from_now,
      details: data.fetch(:details), **attributes
    )
  end
end
