# frozen_string_literal: true

require "test_helper"
require "capybara"
require "decidim/budgets/test/factories"

module Decidim
  module Bih
    # HTTP coverage for the volunteering surface: browse, availability,
    # citizen browse/propose/availability/logging flows. Admin review and hour
    # verification are consolidated under /admin/bih/goodwill.
    class VolunteerPageTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-centar",
          name: { "sr" => "Centar" }
        )
        @komsiluk = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "k-centar",
          name: { "sr" => "Centar" },
          primary_mz_slug: @mz.slug,
          overlapping_mz_slugs: [@mz.slug]
        )
        @opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Čišćenje parka",
          active: true,
          category: "environment",
          komsiluk: @komsiluk
        )
      end

      test "index lists active opportunities" do
        get "/biceriseno/volontiranje"

        assert_response :success
        assert_includes response.body, "Čišćenje parka"
        assert_includes response.body, "Otvorene prilike"
        assert_not_includes response.body, "name=\"day_keys[]\""
      end

      test "index uses server-rendered tabs for large volunteer workflows" do
        sign_in @volunteer

        get "/biceriseno/volontiranje?tab=dostupnost"

        assert_response :success
        assert_includes response.body, "Tvoja dostupnost za volontiranje"
        assert_includes response.body, "Prijavi dostupnost za volontiranje"
        assert_includes response.body, "Unesi priliku za volontiranje"
        assert_includes response.body, "Moja istorija"
        assert_includes response.body, "name=\"day_keys[]\""
        assert_not_includes response.body, "name=\"opportunity_day_keys[]\""
        assert_select "input[name='interest_keys[]'][checked]",
                      Decidim::Bih::VolunteeringTaxonomy::INTERESTS.size
        assert_select "input[name='skill_keys[]'][checked]",
                      Decidim::Bih::VolunteeringTaxonomy::SKILLS.size
        assert_select "input[name='capability_keys[]'][checked]",
                      Decidim::Bih::VolunteeringTaxonomy::CAPABILITIES.size
        assert_select "input[name='interest_keys[]'][value='environment'][checked]"
        assert_select "input[name='interest_keys[]'][value='community_care'][checked]"
        assert_select "input[name='interest_keys[]'][value='people_support']", false
        assert_select "input[name='interest_keys[]'][value='neighborhood_help']", false

        get "/biceriseno/volontiranje?tab=predlozi"

        assert_response :success
        assert_includes response.body, "Predloži volontersku priliku"
        assert_includes response.body, "Volonterske prilike mogu predlagati samo verifikovane organizacije"
        assert_includes response.body, "/biceriseno/organizacije/nova"
        assert_not_includes response.body, "name=\"opportunity_day_keys[]\""

        profile = create_volunteer_partner_profile(user: @volunteer)

        get "/biceriseno/volontiranje?tab=predlozi"

        assert_response :success
        assert_includes response.body, "name=\"opportunity_area_scope\""
        assert_includes response.body, "name=\"opportunity_mz_local_area_id\""
        assert_includes response.body, "name=\"opportunity_komsiluk_local_area_id\""
        assert_includes response.body, "name=\"opportunity_day_keys[]\""
        assert_not_includes response.body, "name=\"day_keys[]\""
        assert_not_includes response.body, "name=\"partner_name\""
        assert_select "select[name='partner_profile_id'][required]"
        assert_select "select[name='partner_profile_id'] option[value='#{profile.id}']", text: profile.display_name
        assert_select "select[name='category'] option[value='environment']"
        assert_select "select[name='category'] option[value='community_care']"
        assert_select "select[name='category'] option[value='admin_logistics']", false
        assert_select "select[name='category'] option[value='other']", false
        assert_select "input[name='quantity'][max='9999999999.99']"
        assert_select "input[name='opportunity_skill_keys[]'][checked]",
                      Decidim::Bih::VolunteeringTaxonomy::SKILLS.size
        assert_select "input[name='opportunity_capability_keys[]'][checked]",
                      Decidim::Bih::VolunteeringTaxonomy::CAPABILITIES.size

        get "/biceriseno/volontiranje?tab=nepoznato"

        assert_response :success
        assert_includes response.body, "Otvorene prilike"
      end

      test "index does not list opportunities from another organization" do
        other = create_organization
        VolunteerOpportunity.create!(
          organization: other,
          title: "Tuđa akcija",
          active: true,
          review_status: "approved"
        )

        get "/biceriseno/volontiranje"

        assert_response :success
        assert_not_includes response.body, "Tuđa akcija"
      end

      test "suspended partner opportunities cannot be listed signed up for or logged while profileless opportunities remain usable" do
        profile = create_volunteer_partner_profile(user: @volunteer, name: "Suspendovani domaćin")
        linked = VolunteerOpportunity.create!(
          organization: @organization,
          author: @volunteer,
          partner_profile: profile,
          partner_name: profile.display_name,
          title: "Skrivena partnerska akcija",
          active: true,
          review_status: "approved",
          category: "environment",
          komsiluk: @komsiluk
        )
        profile.update!(verification_status: "suspended")

        get "/biceriseno/volontiranje"
        assert_response :success
        assert_not_includes response.body, linked.title
        assert_includes response.body, @opportunity.title

        sign_in @volunteer
        assert_no_difference -> { VolunteerSignup.where(opportunity: linked).count } do
          post "/biceriseno/volontiranje/prijavi-se/#{linked.id}"
        end
        assert_response :redirect

        assert_no_difference -> { VolunteerLog.where(opportunity: linked).count } do
          post "/biceriseno/volontiranje/sati", params: work_params(linked, 2)
        end
        assert_response :redirect

        assert_difference -> { VolunteerSignup.where(opportunity: @opportunity, user: @volunteer).count }, 1 do
          post "/biceriseno/volontiranje/prijavi-se/#{@opportunity.id}"
        end
        assert_response :redirect

        assert_difference -> { VolunteerLog.where(opportunity: @opportunity, user: @volunteer).count }, 1 do
          post "/biceriseno/volontiranje/sati", params: work_params(@opportunity, 2)
        end
        assert_response :redirect
      end

      test "a signed-in citizen logs pending hours" do
        approved_signup_for(@opportunity, @volunteer)
        sign_in @volunteer
        post "/biceriseno/volontiranje/sati", params: work_params(@opportunity, 2)

        assert_response :redirect
        log = VolunteerLog.last
        assert_equal @volunteer.id, log.decidim_user_id
        assert_equal 2, log.hours
        assert log.pending?
      end

      test "signed-in users from another organization cannot log hours on this host" do
        outsider = signed_in_other_org_user

        assert_no_difference -> { VolunteerLog.count } do
          post "/biceriseno/volontiranje/sati", params: work_params(@opportunity, 2)
        end

        assert_response :redirect
        assert_nil VolunteerLog.find_by(organization: @organization, user: outsider)
      end

      test "a fractional-hours submission is not silently floored to an integer" do
        approved_signup_for(@opportunity, @volunteer)
        sign_in @volunteer
        assert_no_difference -> { VolunteerLog.where(hours: 1).count } do
          post "/biceriseno/volontiranje/sati", params: work_params(@opportunity, 1.5)
        end

        assert_response :redirect
        # Either rejected outright, or recorded exactly — never silently floored to 1.
        log = VolunteerLog.last
        assert_not_equal 1, log&.hours, "fractional 1.5 must not be silently floored to 1"
      end

      test "logging hours against a capped opportunity without confirmed signup is refused" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        other_volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: other_volunteer, status: "going",
          review_status: "automatic", review_source: "automatic"
        )

        sign_in @volunteer
        assert_no_difference -> { VolunteerLog.where(opportunity: full).count } do
          post "/biceriseno/volontiranje/sati", params: work_params(full, 2)
        end

        assert_response :redirect
      end

      test "a confirmed attendee can log hours even when the opportunity is full" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: @volunteer, status: "going",
          review_status: "automatic", review_source: "automatic"
        )

        sign_in @volunteer
        assert_difference -> { VolunteerLog.where(opportunity: full).count }, 1 do
          post "/biceriseno/volontiranje/sati", params: work_params(full, 3)
        end

        assert_response :redirect
      end

      test "a waitlisted citizen cannot log hours before promotion" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        other_volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: other_volunteer, status: "going",
          review_status: "automatic", review_source: "automatic"
        )
        VolunteerSignup.create!(
          organization: @organization, opportunity: full, user: @volunteer, status: "waitlisted",
          review_status: "automatic", review_source: "automatic", queued_at: Time.current
        )

        sign_in @volunteer
        assert_no_difference -> { VolunteerLog.where(opportunity: full).count } do
          post "/biceriseno/volontiranje/sati", params: work_params(full, 3)
        end

        assert_response :redirect
      end

      test "a historic log alone cannot create a new claim without an approved place" do
        full = VolunteerOpportunity.create!(
          organization: @organization, title: "Popunjena akcija",
          active: true, review_status: "approved", capacity: 1
        )
        # Historic claims remain readable, but a new claim requires an approved place.
        VolunteerLog.create!(
          organization: @organization, opportunity: full, user: @volunteer, hours: 2, status: "pending",
          **work_interval(2)
        )

        sign_in @volunteer
        assert_no_difference -> { VolunteerLog.where(opportunity: full).count } do
          post "/biceriseno/volontiranje/sati", params: work_params(full, 3)
        end

        assert_response :redirect
      end

      test "a signed-in citizen cannot log hours for another organization's opportunity" do
        other = create_organization
        other_opportunity = VolunteerOpportunity.create!(
          organization: other,
          title: "Druga smjena",
          active: true,
          review_status: "approved"
        )

        sign_in @volunteer
        assert_no_difference -> { VolunteerLog.count } do
          post "/biceriseno/volontiranje/sati", params: work_params(other_opportunity, 2)
        end

        assert_response :redirect
      end

      test "a signed-in citizen registers volunteer availability once for points" do
        sign_in @volunteer

        post "/biceriseno/volontiranje/dostupnost",
             params: {
               area_scope: "komsiluk",
               komsiluk_local_area_id: @komsiluk.id,
               day_keys: %w(saturday sunday),
               month_keys: %w(june july),
               time_slot_keys: %w(day afternoon),
               interest_keys: %w(environment neighborhood_infrastructure),
               skill_keys: %w(field_work),
               capability_keys: %w(outdoor_work),
               availability: "Subotom",
               interests: "Parkovi"
             }

        assert_response :redirect
        assert_includes response.location, "tab=dostupnost"
        availability = VolunteerAvailability.last
        assert_equal @volunteer.id, availability.decidim_user_id
        assert_equal "Subotom", availability.availability
        assert_equal "komsiluk", availability.area_scope
        assert_equal @komsiluk.id, availability.local_area_id
        assert_equal %w(saturday sunday), availability.day_keys
        assert_equal %w(june july), availability.month_keys
        assert_equal %w(day afternoon), availability.time_slot_keys
        assert_equal %w(environment neighborhood_infrastructure), availability.interest_keys
        assert_equal ["field_work"], availability.skill_keys
        assert_equal ["outdoor_work"], availability.capability_keys
        assert_equal 10, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score

        post "/biceriseno/volontiranje/dostupnost",
             params: {
               area_scope: "mz",
               mz_local_area_id: @mz.id,
               day_keys: %w(sunday),
               month_keys: %w(august),
               time_slot_keys: %w(afternoon),
               interest_keys: %w(neighborhood_infrastructure),
               availability: "Nedjeljom",
               interests: "Drveće"
             }

        assert_response :redirect
        assert_includes response.location, "tab=dostupnost"
        assert_equal "Nedjeljom", availability.reload.availability
        assert_equal "mz", availability.area_scope
        assert_equal @mz.id, availability.local_area_id
        assert_equal ["sunday"], availability.day_keys
        assert_equal ["august"], availability.month_keys
        assert_equal ["afternoon"], availability.time_slot_keys
        assert_equal ["neighborhood_infrastructure"], availability.interest_keys
        assert_equal 10, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "signed-in users from another organization cannot register availability on this host" do
        outsider = signed_in_other_org_user

        assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.count } do
          assert_no_difference -> { VolunteerAvailability.count } do
            post "/biceriseno/volontiranje/dostupnost",
                 params: { availability: "Subotom", interests: "Parkovi" }
          end
        end

        assert_response :redirect
        assert_nil VolunteerAvailability.find_by(organization: @organization, user: outsider)
      end

      test "a citizen without an eligible organization cannot propose volunteer opportunities" do
        sign_in @volunteer

        assert_no_difference -> { VolunteerOpportunity.count } do
          post "/biceriseno/volontiranje/prilika",
               params: {
                 title: "Samostalna akcija",
                 description: "Bez organizacije",
                 category: "environment",
                 opportunity_area_scope: "komsiluk",
                 opportunity_komsiluk_local_area_id: @komsiluk.id,
                 capacity: 5
               }
        end

        assert_response :redirect
        assert_includes response.location, "tab=predlozi"
      end

      test "an organization proposal waits for admin review and does not award before approval" do
        profile = create_volunteer_partner_profile(user: @volunteer)
        sign_in @volunteer
        submit_previewed_opportunity(
          {
               title: "Sadnja cvijeća",
               description: "U centru",
               category: "environment",
               opportunity_area_scope: "komsiluk",
               opportunity_komsiluk_local_area_id: @komsiluk.id,
               partner_profile_id: profile.id,
               capacity: 5
          }
        )

        assert_response :redirect
        assert_includes response.location, "tab=moje"
        opportunity = VolunteerOpportunity.order(:created_at).last
        assert_equal @volunteer.id, opportunity.decidim_author_id
        assert opportunity.pending_review?
        assert_not opportunity.active?
        assert_equal @komsiluk.id, opportunity.komsiluk_id
        assert_equal profile.id, opportunity.partner_profile_id
        assert_equal profile.display_name, opportunity.partner_name
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "opportunity project selector links only an approved project of the represented partner" do
        profile = create_volunteer_partner_profile(user: @volunteer, name: "Vlasnik projekta")
        own_project = create_approved_partner_project(
          profile:,
          representative: @volunteer,
          title: "Vlastiti projekat"
        )
        other_user = FactoryBot.create(:user, :confirmed, organization: @organization)
        other_profile = create_volunteer_partner_profile(user: other_user, name: "Drugi vlasnik")
        other_project = create_approved_partner_project(
          profile: other_profile,
          representative: other_user,
          title: "Tuđi projekat"
        )
        sign_in @volunteer

        assert_difference -> { VolunteerOpportunity.where(title: "Pomoć vlastitom projektu").count }, 1 do
          submit_previewed_opportunity(opportunity_params(
                 profile:,
                 title: "Pomoć vlastitom projektu",
                 budget_project_id: own_project.id
               ))
        end
        assert_response :redirect
        assert_equal own_project, VolunteerOpportunity.find_by!(title: "Pomoć vlastitom projektu").budget_project

        assert_no_difference -> { VolunteerOpportunity.count } do
          post "/biceriseno/volontiranje/prilika/pregled",
               params: opportunity_params(
                 profile:,
                 title: "Neovlašteno povezivanje",
                 budget_project_id: other_project.id
               )
        end
        assert_response :redirect
      end

      test "a verified informal group can target a local community from the location dropdown" do
        profile = create_volunteer_partner_profile(user: @volunteer, kind: "informal_group", name: "Neformalna grupa Centar")
        sign_in @volunteer
        submit_previewed_opportunity(
          {
               title: "Akcija za MZ",
               description: "Za cijelu mjesnu zajednicu",
               category: "community_care",
               opportunity_area_scope: "mz",
               opportunity_mz_local_area_id: @mz.id,
               partner_profile_id: profile.id,
               capacity: 8
          }
        )

        assert_response :redirect
        opportunity = VolunteerOpportunity.order(:created_at).last
        assert_equal "Akcija za MZ", opportunity.title
        assert_nil opportunity.komsiluk_id
        assert_equal "Centar", opportunity.location
        assert_equal "Centar", opportunity.location_label
        assert_equal profile.id, opportunity.partner_profile_id
        assert opportunity.pending_review?
      end

      test "an organization can propose weekly recurring shifts with partner metadata" do
        starts_at = 1.week.from_now.change(sec: 0)
        profile = create_volunteer_partner_profile(user: @volunteer, name: "Partner centar")

        sign_in @volunteer
        assert_difference -> { VolunteerOpportunity.where(title: "Sedmična pomoć").count }, 3 do
          submit_previewed_opportunity(
            {
                 title: "Sedmična pomoć",
                 description: "Pomoć partneru",
                 komsiluk_id: @komsiluk.id,
                 meeting_point: "Dom omladine",
                 category: "community_care",
                 opportunity_day_keys: %w(monday tuesday),
                 opportunity_month_keys: %w(july august),
                 opportunity_time_slot_keys: %w(day afternoon),
                 ends_at: (starts_at + 2.hours).strftime("%Y-%m-%dT%H:%M"),
                 opportunity_skill_keys: %w(field_work organization),
                 opportunity_capability_keys: %w(outdoor_work),
                 partner_profile_id: profile.id,
                 starts_at: starts_at.strftime("%Y-%m-%dT%H:%M"),
                 capacity: 4,
                 recurrence_count: 3
            }
          )
        end

        shifts = VolunteerOpportunity.where(title: "Sedmična pomoć").order(:series_position).to_a
        assert_equal [1, 2, 3], shifts.map(&:series_position)
        assert_equal [3, 3, 3], shifts.map(&:series_total)
        assert_equal 1, shifts.map(&:series_key).uniq.size
        assert_equal ["Partner centar"], shifts.map(&:partner_name).uniq
        assert_equal [profile.id], shifts.map(&:partner_profile_id).uniq
        assert_equal [@komsiluk.id], shifts.map(&:komsiluk_id).uniq
        assert_equal ["Dom omladine"], shifts.map(&:meeting_point).uniq
        assert_equal ["community_care"], shifts.map(&:category).uniq
        assert_equal [%w(monday tuesday)], shifts.map(&:day_keys).uniq
        assert_equal [%w(july august)], shifts.map(&:month_keys).uniq
        assert_equal [%w(day afternoon)], shifts.map(&:time_slot_keys).uniq
        assert_equal [%w(field_work organization)], shifts.map(&:skill_keys).uniq
        assert_equal [0, 1, 2], (shifts.map { |shift| ((shift.starts_at - starts_at) / 1.week).round })
        assert_equal [0, 1, 2], (shifts.map { |shift| ((shift.ends_at - (starts_at + 2.hours)) / 1.week).round })
        assert shifts.all?(&:pending_review?)
        assert shifts.none?(&:active?)
      end

      test "signed-in users from another organization cannot propose opportunities on this host" do
        outsider = signed_in_other_org_user

        assert_no_difference -> { VolunteerOpportunity.count } do
          post "/biceriseno/volontiranje/prilika",
               params: { title: "Tuđi prijedlog", description: "Ne smije se sačuvati", capacity: 5 }
        end

        assert_response :redirect
        assert_nil VolunteerOpportunity.find_by(organization: @organization, author: outsider)
      end

      test "a rejected opportunity proposal shows a visible reason and no points" do
        profile = create_volunteer_partner_profile(user: @volunteer)
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          author: @volunteer,
          title: "Noćno dežurstvo",
          active: false,
          review_status: "pending",
          category: "community_care",
          komsiluk: @komsiluk,
          partner_profile: profile,
          partner_name: profile.display_name
        )

        Decidim::Bih::RejectVolunteerOpportunity.call(
          opportunity,
          reviewer: @admin,
          reason: "Termin nije potvrđen"
        )

        sign_in @volunteer
        get "/biceriseno/volontiranje?tab=moje"

        assert_response :success
        assert_includes response.body, "Noćno dežurstvo"
        assert_includes response.body, "Termin nije potvrđen"
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "legacy public admin opportunity review routes are not exposed" do
        profile = create_volunteer_partner_profile(user: @volunteer)
        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          author: @volunteer,
          title: "Uređenje igrališta",
          active: false,
          review_status: "pending",
          category: "environment",
          komsiluk: @komsiluk,
          partner_profile: profile,
          partner_name: profile.display_name
        )

        assert_not_routed "/biceriseno/volontiranje/prilika/#{opportunity.id}/odobri"
        assert_not_routed "/biceriseno/volontiranje/prilika/#{opportunity.id}/odbij"
      end

      test "rejected pending hours show a visible reason and no points" do
        log = VolunteerLog.create!(
          organization: @organization, opportunity: @opportunity, user: @volunteer, hours: 4, status: "pending",
          **work_interval(4)
        )

        Decidim::Bih::RejectVolunteerLog.call(
          log,
          verifier: @admin,
          reason: "Nije potvrđeno kod organizatora"
        )

        sign_in @volunteer
        get "/biceriseno/volontiranje?tab=moje"

        assert_response :success
        assert_includes response.body, "Nije potvrđeno kod organizatora"
        assert_equal 0, Decidim::Bih::Goodwill::Ledger.new.account_for(@volunteer).contribution_score
      end

      test "legacy public admin volunteer log routes are not exposed" do
        log = VolunteerLog.create!(
          organization: @organization, opportunity: @opportunity, user: @volunteer, hours: 4, status: "pending",
          **work_interval(4)
        )

        assert_not_routed "/biceriseno/volontiranje/verifikacija/#{log.id}"
        assert_not_routed "/biceriseno/volontiranje/verifikacija/#{log.id}/odbij"
      end

      test "personal contribution offer completes through accept deliver and confirm routes" do
        beneficiary = FactoryBot.create(:user, :confirmed, organization: @organization)
        profile = create_volunteer_partner_profile(user: beneficiary, name: "Primaoc opreme")
        need = create_approved_contribution_need(profile:, author: beneficiary, title: "Dvije stolice")
        sign_in @volunteer

        assert_difference -> { ContributionOffer.count }, 1 do
          post "/biceriseno/volontiranje/potrebe/#{need.id}/ponude",
               params: { offer_quantity: 2, offering_partner_profile_id: "" }
        end
        assert_response :redirect
        offer = ContributionOffer.order(:id).last
        assert_equal "offered", offer.status
        assert_equal @volunteer, offer.contributor
        assert_nil offer.partner_profile

        get "/biceriseno/volontiranje", params: { tab: "moje" }
        assert_response :success
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{offer.id}/povuci']"

        sign_out @volunteer
        sign_in beneficiary
        get "/biceriseno/volontiranje", params: { tab: "moje" }
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{offer.id}/prihvati']"
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{offer.id}/odbij']"
        post "/biceriseno/volontiranje/ponude/#{offer.id}/prihvati"
        assert_response :redirect
        assert_equal "accepted", offer.reload.status

        sign_out beneficiary
        sign_in @volunteer
        get "/biceriseno/volontiranje", params: { tab: "moje" }
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{offer.id}/isporuceno']"
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{offer.id}/povuci']"
        post "/biceriseno/volontiranje/ponude/#{offer.id}/isporuceno"
        assert_response :redirect
        assert_equal "delivered", offer.reload.status

        sign_out @volunteer
        sign_in beneficiary
        get "/biceriseno/volontiranje", params: { tab: "moje" }
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{offer.id}/potvrdi']"
        post "/biceriseno/volontiranje/ponude/#{offer.id}/potvrdi"
        assert_response :redirect
        assert_equal "confirmed", offer.reload.status
        assert_equal "fulfilled", need.reload.fulfillment_status
      end

      test "volunteer coordinator may attribute an offer to the represented partner" do
        beneficiary = FactoryBot.create(:user, :confirmed, organization: @organization)
        beneficiary_profile = create_volunteer_partner_profile(user: beneficiary, name: "Primaoc pomoći")
        need = create_approved_contribution_need(
          profile: beneficiary_profile,
          author: beneficiary,
          title: "Materijal za događaj"
        )
        offering_profile = create_volunteer_partner_profile(user: @volunteer, name: "Koordinatorova organizacija")
        backup_manager = FactoryBot.create(:user, :confirmed, organization: @organization)
        offering_profile.memberships.create!(
          organization: @organization,
          user: backup_manager,
          role: "manager",
          status: "accepted",
          accepted_at: Time.current
        )
        offering_profile.memberships.find_by!(user: @volunteer).update!(role: "volunteer_coordinator")
        sign_in @volunteer

        get "/biceriseno/volontiranje"
        assert_response :success
        assert_select "select[name='offering_partner_profile_id'] option[value='#{offering_profile.id}']"

        assert_difference -> { ContributionOffer.where(partner_profile: offering_profile).count }, 1 do
          post "/biceriseno/volontiranje/potrebe/#{need.id}/ponude",
               params: { offer_quantity: 1, offering_partner_profile_id: offering_profile.id }
        end
        assert_response :redirect
        assert_equal @volunteer, ContributionOffer.order(:id).last.contributor
      end

      test "beneficiary may decline an accepted offer and contributor may withdraw an offered one" do
        beneficiary = FactoryBot.create(:user, :confirmed, organization: @organization)
        profile = create_volunteer_partner_profile(user: beneficiary, name: "Upravljač potrebe")
        accepted_need = create_approved_contribution_need(profile:, author: beneficiary, title: "Prihvaćena ponuda")
        accepted_offer = ContributionOffer.create!(
          organization: @organization,
          contribution_need: accepted_need,
          contributor: @volunteer,
          quantity: 1,
          status: "accepted",
          accepted_by: beneficiary,
          accepted_at: Time.current
        )
        offered_need = create_approved_contribution_need(profile:, author: beneficiary, title: "Ponuđena pomoć")
        offered_offer = ContributionOffer.create!(
          organization: @organization,
          contribution_need: offered_need,
          contributor: @volunteer,
          quantity: 1,
          status: "offered"
        )

        sign_in beneficiary
        get "/biceriseno/volontiranje", params: { tab: "moje" }
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{accepted_offer.id}/odbij']"
        post "/biceriseno/volontiranje/ponude/#{accepted_offer.id}/odbij", params: { reason: "Više nije potrebno" }
        assert_response :redirect
        assert_equal "declined", accepted_offer.reload.status
        assert_equal "Više nije potrebno", accepted_offer.decline_reason

        sign_out beneficiary
        sign_in @volunteer
        post "/biceriseno/volontiranje/ponude/#{offered_offer.id}/povuci"
        assert_response :redirect
        assert_equal "withdrawn", offered_offer.reload.status

        get "/biceriseno/volontiranje"
        assert_response :success
        assert_select "form[action='/biceriseno/volontiranje/potrebe/#{accepted_need.id}/ponude']"
        assert_select "form[action='/biceriseno/volontiranje/potrebe/#{offered_need.id}/ponude']"

        assert_difference -> { ContributionOffer.where(contribution_need: accepted_need).count }, 1 do
          post "/biceriseno/volontiranje/potrebe/#{accepted_need.id}/ponude",
               params: { offer_quantity: 1, offering_partner_profile_id: "" }
        end
        assert_response :redirect
        assert_equal "offered", ContributionOffer.order(:id).last.status
      end

      test "offer actions are tenant scoped and managed view tolerates an anonymized contributor" do
        beneficiary = FactoryBot.create(:user, :confirmed, organization: @organization)
        profile = create_volunteer_partner_profile(user: beneficiary, name: "Domaći primalac")
        need = create_approved_contribution_need(profile:, author: beneficiary, title: "Anonimizovana ponuda")
        anonymized_offer = ContributionOffer.create!(
          organization: @organization,
          contribution_need: need,
          contributor: @volunteer,
          quantity: 1,
          status: "offered"
        )
        # Simulate the intentional FK nullification performed when the citizen
        # account is deleted; this historical row cannot revalidate without the
        # contributor it is specifically testing.
        anonymized_offer.update_column(:decidim_user_id, nil) # rubocop:disable Rails/SkipsModelValidations
        other = create_organization
        foreign_user = FactoryBot.create(:user, :confirmed, organization: other)
        foreign_profile = Decidim::Bih::PartnerProfile.create!(
          organization: other,
          display_name: "Tuđi primalac",
          slug: "tudji-primalac-#{SecureRandom.hex(3)}",
          kind: "association",
          verification_status: "verified",
          verified_at: Time.current
        )
        foreign_profile.memberships.create!(
          organization: other,
          user: foreign_user,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )
        foreign_need = create_approved_contribution_need(
          profile: foreign_profile,
          author: foreign_user,
          title: "Tuđa ponuda"
        )
        foreign_offer = ContributionOffer.create!(
          organization: other,
          contribution_need: foreign_need,
          contributor: foreign_user,
          quantity: 1,
          status: "offered"
        )
        sign_in beneficiary

        get "/biceriseno/volontiranje", params: { tab: "moje" }
        assert_response :success
        assert_includes response.body, I18n.t("decidim.bih.volunteer.index.contributions.former_contributor")

        assert_no_changes -> { foreign_offer.reload.status } do
          post "/biceriseno/volontiranje/ponude/#{foreign_offer.id}/prihvati"
        end
        assert_response :redirect
        assert_equal "offered", anonymized_offer.reload.status
      end

      test "a current beneficiary manager can cancel an approved need after suspension" do
        profile = create_volunteer_partner_profile(user: @volunteer)
        need = create_approved_contribution_need(profile:, author: @volunteer, title: "Oprema za akciju")
        contributor = FactoryBot.create(:user, :confirmed, organization: @organization)
        offer = ContributionOffer.create!(
          organization: @organization,
          contribution_need: need,
          contributor:,
          quantity: 1,
          status: "accepted",
          accepted_by: @volunteer,
          accepted_at: Time.current
        )
        profile.update!(verification_status: "suspended")
        sign_in @volunteer

        get "/biceriseno/volontiranje", params: { tab: "moje" }
        assert_response :success
        assert_includes response.body, need.title
        assert_select "form[action='/biceriseno/volontiranje/potrebe/#{need.id}/otkazi']"

        post "/biceriseno/volontiranje/potrebe/#{need.id}/otkazi"

        assert_response :redirect
        assert_equal "cancelled", need.reload.fulfillment_status
        assert_equal "declined", offer.reload.status
      end

      test "need cancellation is tenant scoped and waits for delivered help to be confirmed" do
        profile = create_volunteer_partner_profile(user: @volunteer)
        need = create_approved_contribution_need(profile:, author: @volunteer, title: "Prevoz opreme")
        contributor = FactoryBot.create(:user, :confirmed, organization: @organization)
        ContributionOffer.create!(
          organization: @organization,
          contribution_need: need,
          contributor:,
          quantity: 1,
          status: "delivered",
          accepted_by: @volunteer,
          accepted_at: 1.hour.ago,
          delivered_at: Time.current
        )
        sign_in @volunteer

        post "/biceriseno/volontiranje/potrebe/#{need.id}/otkazi"
        assert_response :redirect
        assert_equal "open", need.reload.fulfillment_status
        assert_equal I18n.t(
          "decidim.bih.volunteer.contributions.flash.cancel_delivered_pending_confirmation"
        ), flash[:alert]

        other = create_organization
        other_user = FactoryBot.create(:user, :confirmed, organization: other)
        other_profile = Decidim::Bih::PartnerProfile.create!(
          organization: other,
          display_name: "Druga organizacija",
          slug: "druga-organizacija-#{SecureRandom.hex(3)}",
          kind: "association",
          verification_status: "verified",
          verified_at: Time.current
        )
        other_profile.memberships.create!(
          organization: other,
          user: other_user,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )
        foreign_need = create_approved_contribution_need(
          profile: other_profile,
          author: other_user,
          title: "Tuđa potreba"
        )

        post "/biceriseno/volontiranje/potrebe/#{foreign_need.id}/otkazi"
        assert_response :redirect
        assert_equal "open", foreign_need.reload.fulfillment_status
      end

      test "revoked representatives lose historical company offer controls" do
        beneficiary = FactoryBot.create(:user, :confirmed, organization: @organization)
        beneficiary_profile = create_volunteer_partner_profile(user: beneficiary, name: "Primaoc pomoći")
        need = create_approved_contribution_need(
          profile: beneficiary_profile,
          author: beneficiary,
          title: "Materijal za radionicu"
        )
        offering_profile = create_volunteer_partner_profile(user: @volunteer, name: "Kompanija ponuđač")
        add_backup_manager(offering_profile)
        offer = ContributionOffer.create!(
          organization: @organization,
          contribution_need: need,
          contributor: @volunteer,
          partner_profile: offering_profile,
          quantity: 1,
          status: "accepted",
          accepted_by: beneficiary,
          accepted_at: Time.current
        )
        membership = offering_profile.memberships.find_by!(user: @volunteer)
        membership.update!(status: "revoked", revoked_at: Time.current)
        sign_in @volunteer

        get "/biceriseno/volontiranje", params: { tab: "moje" }

        assert_response :success
        assert_not_includes response.body, offer.contribution_need.title
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{offer.id}/isporuceno']", count: 0
        assert_select "form[action='/biceriseno/volontiranje/ponude/#{offer.id}/povuci']", count: 0
      end

      test "nonblank unauthorized company offer ids fail closed instead of becoming personal" do
        beneficiary = FactoryBot.create(:user, :confirmed, organization: @organization)
        beneficiary_profile = create_volunteer_partner_profile(user: beneficiary, name: "Korisnik pomoći")
        need = create_approved_contribution_need(
          profile: beneficiary_profile,
          author: beneficiary,
          title: "Stolice za događaj"
        )
        suspended = create_volunteer_partner_profile(user: @volunteer, name: "Suspendovana kompanija")
        suspended.update!(verification_status: "suspended")
        revoked = create_volunteer_partner_profile(user: @volunteer, name: "Bivša kompanija")
        add_backup_manager(revoked)
        revoked.memberships.find_by!(user: @volunteer).update!(status: "revoked", revoked_at: Time.current)
        other_user = FactoryBot.create(:user, :confirmed, organization: @organization)
        unauthorized = create_volunteer_partner_profile(user: other_user, name: "Tuđa kompanija")
        sign_in @volunteer

        [suspended, revoked, unauthorized].each do |profile|
          assert_no_difference -> { ContributionOffer.count } do
            post "/biceriseno/volontiranje/potrebe/#{need.id}/ponude",
                 params: { offer_quantity: 1, offering_partner_profile_id: profile.id }
          end
          assert_response :redirect
        end

        assert_difference -> { ContributionOffer.where(partner_profile_id: nil).count }, 1 do
          post "/biceriseno/volontiranje/potrebe/#{need.id}/ponude",
               params: { offer_quantity: 1, offering_partner_profile_id: "" }
        end
        assert_response :redirect
      end

      test "known need id does not accept offers after its beneficiary is suspended" do
        beneficiary = FactoryBot.create(:user, :confirmed, organization: @organization)
        beneficiary_profile = create_volunteer_partner_profile(user: beneficiary, name: "Suspendovani primalac")
        need = create_approved_contribution_need(
          profile: beneficiary_profile,
          author: beneficiary,
          title: "Skrivena potreba"
        )
        beneficiary_profile.update!(verification_status: "suspended")
        sign_in @volunteer

        assert_no_difference -> { ContributionOffer.count } do
          post "/biceriseno/volontiranje/potrebe/#{need.id}/ponude",
               params: { offer_quantity: 1, offering_partner_profile_id: "" }
        end

        assert_response :redirect
      end

      test "nonblank invalid project id cannot silently create an unlinked need" do
        profile = create_volunteer_partner_profile(user: @volunteer)
        sign_in @volunteer

        assert_no_difference -> { ContributionNeed.count } do
          post "/biceriseno/volontiranje/potrebe",
               params: {
                 need_partner_profile_id: profile.id,
                 project_id: "999999999",
                 need_type: "equipment",
                 need_title: "Oprema uz projekat",
                 need_description: "Ova potreba mora ostati povezana sa izabranim projektom.",
                 quantity: 2,
                 unit: "komada"
               }
        end

        assert_response :redirect
      end

      private

      def assert_not_routed(path)
        assert_raises(ActionController::RoutingError) do
          Rails.application.routes.recognize_path(path, method: :post)
        end
      end

      def signed_in_other_org_user
        other_organization = create_organization
        outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)
        sign_in outsider
        outsider
      end

      def create_volunteer_partner_profile(user:, kind: "association", name: "Udruženje volontera")
        profile = Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name: name,
          slug: "#{name.parameterize}-#{user.id}",
          kind:,
          verification_status: "verified",
          verified_at: Time.current
        )
        profile.memberships.create!(
          organization: @organization,
          user:,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )
        profile
      end

      def add_backup_manager(profile)
        profile.memberships.create!(
          organization: @organization,
          user: FactoryBot.create(:user, :confirmed, organization: @organization),
          role: "manager",
          status: "accepted",
          accepted_at: Time.current
        )
      end

      def create_approved_contribution_need(profile:, author:, title:)
        ContributionNeed.create!(
          organization: profile.organization,
          partner_profile: profile,
          author:,
          need_type: "equipment",
          title:,
          description: "Detaljan opis nenovčane potrebe",
          quantity: 2,
          unit: "komada",
          review_status: "approved",
          fulfillment_status: "open",
          reviewed_at: Time.current,
          published_at: Time.current
        )
      end

      def create_approved_partner_project(profile:, representative:, title:)
        budget = DecidimApp::Bijeljina::CommunityProjectsSetup.call(
          organization: @organization,
          publish: true
        )
        project = FactoryBot.create(
          :project,
          budget:,
          title: { "sr" => title },
          description: { "sr" => "Detaljan opis #{title}" },
          budget_amount: 5_000
        )
        PartnerProjectSubmission.create!(
          organization: @organization,
          partner_profile: profile,
          representative:,
          reviewer: @admin,
          project:,
          title:,
          description: "Detaljan opis #{title}",
          budget_amount: 5_000,
          review_status: "approved",
          submitted_at: 1.day.ago,
          reviewed_at: Time.current
        )
        ProjectDonationLink.create!(
          organization: @organization,
          project:,
          campaign_key: "project-#{project.id}",
          active: true
        )
        project
      end

      def opportunity_params(profile:, title:, budget_project_id:)
        {
          title:,
          description: "Detaljan opis volonterske prilike",
          category: "environment",
          opportunity_area_scope: "komsiluk",
          opportunity_komsiluk_local_area_id: @komsiluk.id,
          partner_profile_id: profile.id,
          budget_project_id:,
          capacity: 5
        }
      end

      def submit_previewed_opportunity(attributes)
        post "/biceriseno/volontiranje/prilika/pregled", params: attributes
        assert_response :success
        token = Nokogiri::HTML(response.body).at_css("input[name='preview_token']")&.[]("value")
        assert token.present?, "schedule preview must issue a confirmation token"
        post "/biceriseno/volontiranje/prilika",
             params: attributes.merge(preview_token: token, schedule_preview_confirmed: "1")
      end

      def approved_signup_for(opportunity, user)
        VolunteerSignup.create!(organization: @organization, opportunity:, user:,
                                status: "going", review_status: "automatic", review_source: "automatic")
      end

      def work_interval(hours, date: Date.current - 2)
        zone = Time.find_zone!("Europe/Sarajevo")
        started = zone.parse("#{date.iso8601} 10:00")
        { work_date: date, worked_from_at: started, worked_until_at: started + hours.hours }
      end

      def work_params(opportunity, hours, date: Date.current - 2)
        start_minutes = 10 * 60
        end_minutes = start_minutes + (hours.to_f * 60).to_i
        { opportunity_id: opportunity.id, work_date: date.iso8601,
          worked_from_time: format("%02d:%02d", start_minutes / 60, start_minutes % 60),
          worked_until_time: format("%02d:%02d", end_minutes / 60, end_minutes % 60) }
      end
    end
  end
end
