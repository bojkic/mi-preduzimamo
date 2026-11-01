# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/race_project_selection_fixture"

module DecidimApp
  module Bijeljina
    class RaceProjectSelectionTest < ActiveSupport::TestCase
      include RaceProjectSelectionFixture
      setup { prepare_race_projects }
      teardown { travel_back }

      test "owner acceptance finalizes unchanged scoring without invented voting dates" do
        assert @edition.reload.finalized_at
        assert_equal @before_rows, @review.preview
        assert_equal @preview[:score], Decidim::Bih::Race::Standings.new(@organization).rows.sum(&:score)
        assert_equal @preview[:snapshot_digest], @edition.snapshot_digest
        assert_nil @edition.settings["vote_starts_at"]
        assert_nil @edition.settings["vote_ends_at"]
        assert_equal true, @edition.events.find_by!(kind: "owner_closeout").data["scores_unchanged"]
        assert_equal false, @edition.events.find_by!(kind: "owner_closeout").data["appeals"]
        assert_equal true, @review.decisions.fetch("report:#{@report.id}")["include"]
        assert_equal "needs_information", @report.reload.review_state
      end

      test "native process has distinct public components and discussion before voting" do
        assert @process.published?
        assert @city_component.published?
        assert @rural_component.published?
        assert_not_equal @city_component.id, @rural_component.id
        assert_equal @city.id, RaceProjectSelection.area_id(@city_component)
        assert_equal @rural.id, RaceProjectSelection.area_id(@rural_component)
        assert @city_component.current_settings.creation_enabled?
        assert @city_component.settings.comments_enabled?
        assert_not @city_component.current_settings.votes_enabled?
        assert_equal 1, @city_component.settings.vote_limit
        assert_equal 0, Decidim::Proposals::Proposal.where(component: @result[:components]).count
        assert_nil @process.end_date
        assert(@process.steps.where.not(position: 0).all? { |step| step.start_date.nil? && step.end_date.nil? })
        assert_equal 2, RaceProjectSelection.links(@organization).size
        assert_includes Decidim::Pages::Page.find_by!(component: @result[:archive]).body["sr"], 'href="/trka"'
        assert_includes @process.description["sr-Cyrl"], "/processes/#{RaceProjectSelection::PROCESS_SLUG}/f/"
      end

      test "replaying closeout does not change finalized evidence or duplicate the process" do
        digest = @edition.reload.final_digest
        assert_no_difference ["Decidim::ParticipatoryProcess.count", "Decidim::Component.count", "Decidim::Bih::Race::Event.count", "Decidim::Bih::OperatorAuditEvent.count"] do
          @closeout.apply!(expected_snapshot_digest: @preview[:snapshot_digest], expected_rows_digest: @preview[:rows_digest],
                           winners: { grad: @city.id, selo: @rural.id })
        end
        assert_equal digest, @edition.reload.final_digest
        assert_raises(ArgumentError) do
          @closeout.apply!(expected_snapshot_digest: "stale", expected_rows_digest: @preview[:rows_digest],
                           winners: { grad: @city.id, selo: @rural.id })
        end
      end

      test "voting eligibility follows the currently selected neighbourhood" do
        Decidim::Bih::CitizenProfile.find_by!(user: @citizen).assign_komsiluk!(@rural, source: "dropdown")
        assert_not RaceProjectSelection.eligible_voter?(@citizen, @city_component)
        assert RaceProjectSelection.eligible_voter?(@citizen, @rural_component)
        assert_not RaceProjectSelection.eligible_voter?(@rural_citizen, @city_component)
      end

      test "new residents are eligible and revoked phone authorization prevents voting" do
        late = create(:user, :confirmed, organization: @organization)
        create(:authorization, :granted, user: late, name: "sms")
        Decidim::Bih::CitizenProfile.create!(organization: @organization, user: late, komsiluk: @city, source: "dropdown", assigned_at: Time.current)
        assert RaceProjectSelection.eligible_voter?(late, @city_component)
        Decidim::Authorization.find_by!(user: @citizen, name: "sms").update!(granted_at: nil)
        assert_not RaceProjectSelection.eligible_voter?(@citizen, @city_component)
      end

      test "votes require the voting phase and the correct electorate and cannot exceed one" do
        first = project_proposal
        second = project_proposal
        vote = Decidim::Proposals::ProposalVote.new(proposal: first, author: @citizen)
        assert_not vote.valid?
        activate_project_voting
        vote.save!
        assert_not Decidim::Proposals::ProposalVote.new(proposal: second, author: @citizen).valid?
        assert_not Decidim::Proposals::ProposalVote.new(proposal: first, author: @rural_citizen).valid?
        vote.destroy!
        assert Decidim::Proposals::ProposalVote.new(proposal: second, author: @citizen).valid?
        @city_component.update!(published_at: nil)
        assert_not RaceProjectSelection.vote_allowed?(@citizen, @city_component)
      end

      test "native vote command rejects a second vote and unrelated components stay unchanged" do
        activate_project_voting
        first = project_proposal
        second = project_proposal
        Decidim::Proposals::VoteProposal.call(first, @citizen)
        rejected = false
        Decidim::Proposals::VoteProposal.call(second, @citizen) { on(:invalid) { rejected = true } }
        assert rejected
        assert_equal 1, Decidim::Proposals::ProposalVote.where(author: @citizen).count
        ordinary = create(:proposal_component, organization: @organization)
        proposal = project_proposal(ordinary)
        assert Decidim::Proposals::ProposalVote.new(proposal:, author: @rural_citizen).valid?
      end
      test "generated project copy uses reviewed community names and configured budget" do
        assert_includes @process.subtitle["sr"], @city.name["sr"]
        assert_includes @process.subtitle["sr"], @rural.name["sr"]
        assert_includes @process.subtitle["sr"], "1.234,50 KM"
        assert_includes @process.developer_group["sr"], RaceProjectSelection.localized_name(@organization.name)
        archive = Decidim::Pages::Page.find_by!(component: @result[:archive]).body["sr"]
        assert_includes archive, @city.name["sr"]
        assert_includes archive, @rural.name["sr"]
        assert_includes archive, @edition.reload.finalized_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y.")
        block = Decidim::ContentBlock.find_by!(organization: @organization, manifest_name: "highlighted_content_banner")
        assert_includes block.settings.action_button_subtitle["sr"], @city.name["sr"]
        assert_includes block.settings.action_button_subtitle["sr"], @rural.name["sr"]
        assert_equal RaceProjectSelection.localized_name(@organization.name), @edition.reload.settings["project_owner"]
      end

      test "absent project budget does not invent a funded amount" do
        prepare_race_projects(budget_bam: nil)
        assert_includes @process.subtitle["sr"], "u okviru objavljenog budžeta procesa"
        assert_no_match(/\d[\d.,]*\s*KM/, @process.description["sr"])
        assert_no_match(/\d[\d.,]*\s*KM/, Decidim::Pages::Page.find_by!(component: @result[:archive]).body["sr"])
      end

      test "invalid budget cannot write and authorization is checked first" do
        Decidim::Bih::Setting.put(@organization, "race_projects", "project_budget_bam", "NaN")
        assert_no_difference ["Decidim::ParticipatoryProcess.count", "Decidim::Component.count", "Decidim::Bih::OperatorAuditEvent.count"] do
          assert_raises(ArgumentError) do
            RaceProjectSelectionSetup.new(organization: @organization, actor: @admin, reason: "Authored invalid budget").call(publish: true)
          end
          assert_raises(Decidim::ActionForbidden) do
            RaceProjectSelectionSetup.new(organization: @organization, actor: @citizen, reason: "Authored forbidden action").call(publish: true)
          end
        end
      end

      test "winner and community names cannot introduce HTML into generated content" do
        city_name = '<img src=x onerror="authoredTest()"> TESTNI VRT'
        rural_name = "TESTNO POLJE & AUTORSKI PRIMJER"
        community_name = "TIM <script>authoredTest()</script>"
        prepare_race_projects(city_name:, rural_name:, community_name:)
        archive = Nokogiri::HTML.fragment(Decidim::Pages::Page.find_by!(component: @result[:archive]).body["sr"])
        assert_empty archive.css("img,script")
        assert_includes archive.text, city_name
        assert_includes archive.text, rural_name
        announcement = Nokogiri::HTML.fragment(@city_component.settings.announcement["sr"])
        assert_empty announcement.css("img,script")
        assert_includes announcement.text, city_name
        developer = Nokogiri::HTML.fragment(@process.developer_group["sr"])
        assert_empty developer.css("script")
        assert_includes developer.text, community_name
      end

      test "reviewed winner labels remain scoped to the requested organization" do
        first_organization = @organization
        first_names = [@city.name["sr"], @rural.name["sr"]]
        prepare_race_projects(city_name: "Drugi izmišljeni grad", rural_name: "Drugo izmišljeno selo")
        assert_equal first_names, RaceProjectSelection.winner_names(first_organization)
        assert_equal [@city.name["sr"], @rural.name["sr"]], RaceProjectSelection.winner_names(@organization)
      end

    end
  end
end
