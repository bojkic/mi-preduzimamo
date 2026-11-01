# frozen_string_literal: true

require "test_helper"
require "capybara"
require_relative "../../support/race_project_selection_fixture"

class RaceProjectSelectionIntegrationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RaceProjectSelectionFixture

  setup do
    prepare_race_projects
    host! @organization.host
  end
  teardown { travel_back }

  test "published process exposes both neighbourhoods and its archive" do
    get DecidimApp::Bijeljina::RaceProjectSelection.process_path
    assert_response :success
    assert_select "link[href^='/mi/project-choice.css']", count: 1
    [@city_component, @rural_component, @result[:archive]].each do |component|
      assert_select "a[href=?]", Decidim::EngineRouter.main_proxy(component).root_path
    end
    get Decidim::EngineRouter.main_proxy(@result[:archive]).root_path
    assert_response :success
    assert_select "a[href='/trka']"
    get "/trka"
    assert_response :success
    assert_select "[data-race-project-selection] a", minimum: 2
    assert_select ".mi-trka a[href='/registracija?izvor=trka']", count: 0
    get "/"
    assert_response :success
    assert_select "footer a[href='/trka']", count: 0
    assert_select ".mi-mobile-more-sheet a[href='/trka']", count: 0
    assert_select "nav a[href='/trka']", count: 0
    assert_select ".mi-hero-stats a[href=?]", DecidimApp::Bijeljina::RaceProjectSelection.process_path
  end

  test "each native submission route opens for a verified citizen" do
    sign_in @citizen
    [@city_component, @rural_component].each do |component|
      get Decidim::EngineRouter.main_proxy(component).root_path
      assert_response :success
      get Decidim::EngineRouter.main_proxy(component).new_proposal_path
      assert_response :success
      assert_select "form"
    end
  end

  test "a citizen submits and publishes separate proposals using the native wizard endpoints" do
    sign_in @citizen
    [@city_component, @rural_component].each do |component|
      router = Decidim::EngineRouter.main_proxy(component)
      assert_difference "Decidim::Proposals::Proposal.count", 1 do
        post router.proposals_path,
             params: { proposal: { title: "Klupa i javno mjesto za okupljanje",
                                   body: "Predlažem uređenje javnog prostora sa klupom. Trošak je do 3.000 KM, uz dogovor o održavanju i potrebnim dozvolama." } }
      end
      assert_response :redirect
      proposal = Decidim::Proposals::Proposal.where(component:).last
      assert proposal.draft?
      follow_redirect!
      assert_response :success
      post router.publish_proposal_path(proposal)
      assert_response :redirect
      assert proposal.reload.published?
    end
    Decidim::Authorization.find_by!(user: @citizen, name: "sms").update!(granted_at: nil)
    assert_no_difference "Decidim::Proposals::Proposal.count" do
      post Decidim::EngineRouter.main_proxy(@city_component).proposals_path,
           params: { proposal: { title: "Neodobren prijedlog za projekat", body: "Prijedlog bez važeće telefonske potvrde." } }
    end
  end

  test "verified citizens can discuss proposals through the native comment endpoint" do
    proposal = project_proposal
    sign_in @rural_citizen
    assert_difference "Decidim::Comments::Comment.count", 1 do
      post Decidim::Comments::Engine.routes.url_helpers.comments_path,
           params: { comment: { commentable_gid: proposal.to_sgid.to_s, body: "Predlažem da provjerimo pristup za sve komšije.", alignment: 0 } }, xhr: true
    end
    assert_response :success
    Decidim::Authorization.find_by!(user: @rural_citizen, name: "sms").update!(granted_at: nil)
    assert_no_difference "Decidim::Comments::Comment.count" do
      post Decidim::Comments::Engine.routes.url_helpers.comments_path,
           params: { comment: { commentable_gid: proposal.to_sgid.to_s, body: "Neodobren komentar.", alignment: 0 } }, xhr: true
    end
    assert_includes [302, 403], response.status
  end

  test "eligible voter can cast and withdraw a ballot through the native endpoint" do
    activate_project_voting
    proposal = project_proposal
    sign_in @citizen
    path = Decidim::EngineRouter.main_proxy(@city_component).proposal_proposal_vote_path(proposal)
    assert_difference "Decidim::Proposals::ProposalVote.count", 1 do
      post path, xhr: true
    end
    assert_response :success
    assert_difference "Decidim::Proposals::ProposalVote.count", -1 do
      delete path, xhr: true
    end
    assert_response :success
  end

  test "wrong neighbourhood vote is rejected through the native endpoint" do
    activate_project_voting
    proposal = project_proposal
    sign_in @rural_citizen
    assert_no_difference "Decidim::Proposals::ProposalVote.count" do
      post Decidim::EngineRouter.main_proxy(@city_component).proposal_proposal_vote_path(proposal), xhr: true
    end
    assert_includes [302, 403], response.status
  end
end
