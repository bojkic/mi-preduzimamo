# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # HTTP coverage for the public org goodwill profile + admin re-grant.
    class OrganizationPageTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                      name: "Udruženje X",
                                                      extended_data: { "group" => true })
        @profile = Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name: "Udruženje X",
          slug: "udruzenje-x",
          kind: "association",
          verification_status: "verified",
          legacy_user_group: @group,
          verified_at: Time.current
        )
        @admin = FactoryBot.create(:user, :confirmed, organization: @organization)
        @member = FactoryBot.create(:user, :confirmed, organization: @organization)
        @profile.memberships.create!(
          organization: @organization,
          user: @admin,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )
        @profile.memberships.create!(
          organization: @organization,
          user: @member,
          role: "member",
          status: "accepted",
          accepted_at: Time.current
        )
        Decidim::Bih::Goodwill::Ledger.new.award(@group, 100, reason: "gift")
      end

      test "GET organizacija renders the org goodwill profile for anonymous visitors" do
        get "/biceriseno/organizacija/#{@profile.slug}"

        assert_response :success
        assert_includes response.body, "Udruženje X" # org name
        assert_includes response.body, "100" # received goodwill (wallet balance)
      end

      test "GET organizacija remains available while an older controller has no impact summary" do
        Decidim::Bih::PartnerImpactSummary.stub(:call, nil) do
          get "/biceriseno/organizacija/#{@profile.slug}"
        end

        assert_response :success
        assert_includes response.body, "Udruženje X"
        assert_select "#uticaj-organizacije", count: 0
      end

      test "organization admins see points and volunteer actions in the profile menu" do
        sign_in @admin

        get "/biceriseno/organizacija/#{@profile.slug}"

        assert_response :success
        assert_includes response.body, "Meni organizacije"
        assert_includes response.body, "Bodovi organizacije"
        assert_includes response.body, "Dostupno za dodjelu"
        assert_includes response.body, "/biceriseno/volontiranje?tab=predlozi#predlozi"
        assert_includes response.body, "#clanovi-organizacije"
      end

      test "business profile shows aggregate impact and representatives without organization Goodwill controls" do
        owner = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Poslovni predstavnik")
        representative = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Drugi predstavnik")
        business = Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name: "Kompanija primjer",
          slug: "kompanija-primjer",
          kind: "business",
          verification_status: "verified",
          verified_at: Time.current
        )
        business.memberships.create!(
          organization: @organization,
          user: owner,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )
        business.memberships.create!(
          organization: @organization,
          user: representative,
          role: "member",
          status: "accepted",
          accepted_at: Time.current
        )
        sign_in owner

        get "/biceriseno/organizacija/#{business.slug}"

        assert_response :success
        assert_select "#uticaj-organizacije"
        assert_includes response.body, "Predstavnici na platformi"
        assert_includes response.body, "Ne dodaj radnike"
        assert_includes response.body, owner.name
        assert_includes response.body, representative.name
        assert_select "#dodaj-clana"
        assert_select "#bodovi-organizacije", count: 0
        assert_select "#zahtjevi-potrosnje", count: 0
        assert_select "form[action='/biceriseno/organizacija/#{business.slug}/regrant']", count: 0
        assert_select "form[action='/biceriseno/organizacija/#{business.slug}/potrosnja']", count: 0
        assert_not_includes response.body, I18n.t("decidim.bih.organizations.show.points_balance")
        assert_includes response.body, "/biceriseno/volontiranje?tab=predlozi#predlozi"
      end

      test "GET organizacije renders current user's memberships ordered by profile name" do
        sign_in @member

        get "/biceriseno/organizacije"

        assert_response :success
        assert_includes response.body, "Udruženje X"
        assert_includes response.body, I18n.t("decidim.bih.partner_memberships.roles.member")
      end

      test "signed-in citizens submit organization data and documents for verification" do
        submitter = FactoryBot.create(:user, :confirmed, organization: @organization)
        document = Rack::Test::UploadedFile.new(
          StringIO.new("%PDF-1.4 proof"),
          "application/pdf",
          original_filename: "registracija.pdf"
        )
        sign_in submitter

        assert_difference -> { Decidim::Bih::PartnerProfile.count }, 1 do
          assert_difference -> { Decidim::Bih::PartnerMembership.count }, 1 do
            post "/biceriseno/organizacije",
                 params: {
                   partner_profile: {
                     display_name: "Udruženje mladih Bijeljina",
                     legal_name: "Udruženje mladih Bijeljina",
                     kind: "association",
                     website: "https://example.org",
                     public_description: "Rad sa mladima.",
                     private_contact_name: "Mila",
                     private_contact_email: "mila@example.org",
                     private_contact_phone: "+387 55 000 000",
                     verification_documents: [document]
                   }
                 }
          end
        end

        assert_redirected_to "/biceriseno/organizacije"
        profile = Decidim::Bih::PartnerProfile.order(:created_at).last
        assert_equal "submitted", profile.verification_status
        assert profile.verification_documents.attached?
        assert_equal ["registracija.pdf"], (profile.verification_documents.map { |attachment| attachment.filename.to_s })

        membership = profile.memberships.find_by!(user: submitter)
        assert_equal "owner", membership.role
        assert_equal "accepted", membership.status
        assert_equal submitter, membership.invited_by
        assert membership.accepted_at.present?
      end

      test "organization submission can omit documents when the organization type does not require them" do
        submitter = FactoryBot.create(:user, :confirmed, organization: @organization)
        sign_in submitter

        assert_difference -> { Decidim::Bih::PartnerProfile.count }, 1 do
          post "/biceriseno/organizacije",
               params: {
                 partner_profile: {
                   display_name: "Organizacija bez dokaza",
                   kind: "association",
                   private_contact_name: "Mila",
                   private_contact_email: "mila@example.org",
                   public_description: "Neformalna grupa koja organizuje lokalne akcije u zajednici."
                 }
               }
        end

        assert_redirected_to "/biceriseno/organizacije"
        assert_not Decidim::Bih::PartnerProfile.order(:id).last.verification_documents.attached?
      end

      test "a signed-in group admin sends a private invitation that the citizen accepts before publication" do
        candidate = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Novi Član")
        sign_in @admin

        assert_difference -> { Decidim::Bih::PartnerMembership.count }, 1 do
          post "/biceriseno/organizacija/#{@profile.slug}/clanovi", params: { member_lookup: candidate.email.upcase }
        end

        assert_response :redirect
        membership = @profile.memberships.find_by!(user: candidate)
        assert_equal "member", membership.role
        assert_equal "pending", membership.status
        assert_equal @admin, membership.invited_by
        assert_nil membership.accepted_at

        get "/biceriseno/organizacija/#{@profile.slug}"
        assert_not Capybara.string(response.body).has_css?(".mi-organization-member-list", text: "Novi Član")

        sign_out @admin
        sign_in candidate
        get "/biceriseno/organizacije"
        assert_response :success
        assert_includes response.body, I18n.t("decidim.bih.organizations.index.accept_invitation")

        patch "/biceriseno/organizacija/clanstvo/#{membership.id}/prihvati"
        assert_response :redirect
        assert_equal "accepted", membership.reload.status
        assert membership.accepted_at.present?

        get "/biceriseno/organizacija/#{@profile.slug}"
        assert Capybara.string(response.body).has_css?(".mi-organization-member-list", text: "Novi Član")
      end

      test "citizen can decline an invitation and leave an accepted non-manager membership" do
        candidate = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Pozvani Član")
        invitation = @profile.memberships.create!(
          organization: @organization,
          user: candidate,
          role: "member",
          status: "pending",
          invited_by: @admin
        )
        sign_in candidate

        patch "/biceriseno/organizacija/clanstvo/#{invitation.id}/odbij"
        assert_response :redirect
        assert_equal "revoked", invitation.reload.status

        invitation.update!(status: "accepted", accepted_at: Time.current, revoked_at: nil)
        delete "/biceriseno/organizacija/clanstvo/#{invitation.id}/napusti"
        assert_response :redirect
        assert_equal "revoked", invitation.reload.status
      end

      test "organization manager corrects and resubmits a rejected profile" do
        @profile.reject!(reason: "Dopunite javni opis")
        sign_in @admin

        get "/biceriseno/organizacije"
        assert_response :success
        assert_includes response.body, "Dopunite javni opis"
        assert_includes response.body, "/biceriseno/organizacije/#{@profile.id}/uredi"

        get "/biceriseno/organizacije/#{@profile.id}/uredi"
        assert_response :success
        assert_select "form[action='/biceriseno/organizacije/#{@profile.id}']"

        patch "/biceriseno/organizacije/#{@profile.id}", params: {
          partner_profile: {
            display_name: @profile.display_name,
            kind: @profile.kind,
            public_description: "Dopunjeni javni opis rada organizacije u lokalnoj zajednici.",
            private_contact_name: "Kontakt osoba",
            private_contact_email: "kontakt@example.org"
          }
        }

        assert_redirected_to "/biceriseno/organizacije"
        @profile.reload
        assert_equal "submitted", @profile.verification_status
        assert_nil @profile.rejection_reason
        assert_equal "Dopunjeni javni opis rada organizacije u lokalnoj zajednici.", @profile.public_description
      end

      test "organization manager assigns a functional member role with an audit row" do
        membership = @profile.memberships.find_by!(user: @member)
        sign_in @admin

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_membership_role_updated").count }, 1 do
          patch "/biceriseno/organizacija/#{@profile.slug}/clanovi/#{membership.id}",
                params: { role: "content_editor" }
        end

        assert_response :redirect
        assert_equal "content_editor", membership.reload.role
      end

      test "organization cannot demote its last accepted manager" do
        owner_membership = @profile.memberships.find_by!(user: @admin)
        sign_in @admin

        assert_no_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_membership_role_updated").count } do
          patch "/biceriseno/organizacija/#{@profile.slug}/clanovi/#{owner_membership.id}",
                params: { role: "member" }
        end

        assert_response :redirect
        assert_equal "owner", owner_membership.reload.role
      end

      test "a non-admin member cannot add organization members" do
        candidate = FactoryBot.create(:user, :confirmed, organization: @organization)
        sign_in @member

        assert_no_difference -> { Decidim::Bih::PartnerMembership.count } do
          post "/biceriseno/organizacija/#{@profile.slug}/clanovi", params: { member_lookup: candidate.email }
        end

        assert_response :redirect
        assert_nil @profile.memberships.find_by(user: candidate)
      end

      test "reinviting an accepted member preserves the accepted membership" do
        membership = @profile.memberships.find_by!(user: @member)
        accepted_at = membership.accepted_at
        sign_in @admin

        assert_no_difference -> { Decidim::Bih::PartnerMembership.count } do
          post "/biceriseno/organizacija/#{@profile.slug}/clanovi", params: { member_lookup: @member.email }
        end

        assert_response :redirect
        assert_equal "accepted", membership.reload.status
        assert_equal "member", membership.role
        assert_equal accepted_at, membership.accepted_at
        assert_equal I18n.t("decidim.bih.organizations.add_member.already_member", name: @member.name), flash[:notice]
      end

      test "a signed-in group admin can re-grant points to a member" do
        sign_in @admin

        post "/biceriseno/organizacija/#{@profile.slug}/regrant", params: { member_id: @member.id, amount: 40, request_key: SecureRandom.uuid }

        assert_response :redirect
        ledger = Decidim::Bih::Goodwill::Ledger.new
        assert_equal 60, ledger.account_for(@group).balance
        assert_equal 40, ledger.account_for(@member).balance
      end

      test "a non-admin member cannot re-grant" do
        sign_in @member

        post "/biceriseno/organizacija/#{@profile.slug}/regrant", params: { member_id: @admin.id, amount: 10, request_key: SecureRandom.uuid }

        assert_response :redirect
        assert_equal 100, Decidim::Bih::Goodwill::Ledger.new.account_for(@group).balance
      end

      test "a signed-in group admin from another organization cannot re-grant on this host" do
        other_organization = create_organization
        other_group = FactoryBot.create(:user, :confirmed, organization: other_organization,
                                                           name: "Tuđa grupa",
                                                           extended_data: { "group" => true })
        other_profile = Decidim::Bih::PartnerProfile.create!(
          organization: other_organization,
          display_name: "Tuđa grupa",
          slug: "tudja-grupa",
          kind: "association",
          verification_status: "verified",
          legacy_user_group: other_group,
          verified_at: Time.current
        )
        outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)
        other_profile.memberships.create!(
          organization: other_organization,
          user: outsider,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )

        sign_in outsider

        assert_no_difference("Decidim::Bih::Goodwill::Transaction.count") do
          post "/biceriseno/organizacija/#{@profile.slug}/regrant", params: { member_id: @member.id, amount: 40, request_key: SecureRandom.uuid }
        end

        ledger = Decidim::Bih::Goodwill::Ledger.new
        assert_response :redirect
        assert_equal 100, ledger.account_for(@group).balance
        assert_equal 0, ledger.account_for(@member).balance
      end
    end
  end
end
