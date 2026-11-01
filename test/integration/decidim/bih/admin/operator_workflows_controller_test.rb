# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      class OperatorWorkflowsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @operator = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Operator Test")
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Ana Gradjanka")
        end

        test "admin grants and revokes multiple expiring operator roles" do
          sign_in @admin

          get "/admin/bih/operator-roles", params: { q: "Operator" }
          assert_response :success
          assert_includes response.body, "Operator Test"
          assert_includes response.body, I18n.t("decidim.bih.admin.operator_roles.permissions.reports_update_status")
          assert_includes response.body, "data-operator-permission-label=\"reports_update_status\""

          assert_difference -> { Decidim::Bih::OperatorRole.active.count }, 2 do
            assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "operator_role_granted").count }, 2 do
              post "/admin/bih/operator-roles",
                   params: {
                     decidim_user_id: @operator.id,
                     roles: %w(report_triager support_agent),
                     expires_on: 30.days.from_now.to_date.iso8601,
                     approval_rationale: "Weekly report and support rota"
                   }
            end
          end
          assert_response :redirect

          roles = Decidim::Bih::OperatorRole.active.where(user: @operator).order(:role)
          assert_equal %w(report_triager support_agent), roles.pluck(:role)
          assert(roles.all? { |role| role.expires_at.future? })
          assert_equal(
            ["Weekly report and support rota"],
            Decidim::Bih::OperatorAuditEvent
              .where(event_type: "operator_role_granted")
              .order(:id)
              .last(2)
              .map { |event| event.metadata["approval_rationale"] }
              .uniq
          )

          assert_difference -> { Decidim::Bih::OperatorRole.where.not(revoked_at: nil).count }, 1 do
            assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "operator_role_revoked").count }, 1 do
              post "/admin/bih/operator-roles/#{roles.first.id}/revoke"
            end
          end
          assert_response :redirect
        end

        test "operator role expiry warnings are sent once at 30 and 7 days" do
          role = Decidim::Bih::OperatorRole.create!(
            organization: @organization,
            user: @operator,
            created_by: @admin,
            role: "report_triager",
            expires_at: 29.days.from_now
          )

          assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "operator_role_expiry_warning_sent").count }, 1 do
            assert_enqueued_with(job: ActionMailer::MailDeliveryJob) do
              assert_equal 1, Decidim::Bih::OperatorRoleExpiryNotifier.call
            end
          end
          assert_equal 0, Decidim::Bih::OperatorRoleExpiryNotifier.call

          role.update!(expires_at: 6.days.from_now)
          assert_equal 1, Decidim::Bih::OperatorRoleExpiryNotifier.call
        end

        test "admin reviews and verifies organization profiles" do
          profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Novo udruzenje",
            slug: "novo-udruzenje",
            kind: "association",
            verification_status: "submitted",
            public_description: "Udruženje organizuje provjerene programe za lokalnu zajednicu."
          )

          sign_in @admin
          get "/admin/bih/organizations", params: { status: "submitted" }
          assert_response :success
          assert_includes response.body, "Novo udruzenje"

          assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_profile_verified").count }, 1 do
            post "/admin/bih/organizations/#{profile.id}/verify",
                 params: { private_reason: "Registration evidence reviewed", evidence_reviewed: "1" }
          end
          assert_response :redirect

          profile.reload
          assert_equal "verified", profile.verification_status
          assert_equal @admin, profile.verified_by
          assert profile.verified_at.present?
          event = Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_profile_verified").order(:id).last
          assert_equal "Registration evidence reviewed", event.metadata["private_reason"]
          assert_equal true, event.metadata["evidence_reviewed"]
        end

        test "admin verification keeps placeholder organization profiles out of the public directory" do
          profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Organizacija (uzorak)",
            slug: "organizacija-uzorak",
            kind: "association",
            verification_status: "submitted",
            public_description: "asdfgbhnj"
          )

          sign_in @admin
          assert_no_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_profile_verified").count } do
            post "/admin/bih/organizations/#{profile.id}/verify",
                 params: { private_reason: "Evidence reviewed", evidence_reviewed: "1" }
          end

          assert_response :redirect
          assert_equal "submitted", profile.reload.verification_status
          assert flash[:alert].present?
        end

        test "generic organization edit does not change verification status" do
          profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Granica statusa",
            slug: "granica-statusa",
            kind: "association",
            verification_status: "verified",
            public_description: "Originalni opis"
          )

          sign_in @admin
          get "/admin/bih/organizations/#{profile.id}/edit"
          assert_response :success
          assert_includes response.body, "partner-profile-status-boundary"
          assert_includes response.body, I18n.t("decidim.bih.admin.partner_profiles.form.status_locked")
          assert_not_includes response.body, "partner_profile[verification_status]"

          patch "/admin/bih/organizations/#{profile.id}",
                params: {
                  partner_profile: {
                    display_name: "Granica statusa updated",
                    slug: "granica-statusa",
                    kind: "association",
                    verification_status: "suspended",
                    public_description: "Azuriran opis"
                  }
                }

          assert_response :redirect
          profile.reload
          assert_equal "verified", profile.verification_status
          assert_equal "Granica statusa updated", profile.display_name
          assert_equal "Azuriran opis", profile.public_description
        end

        test "admin assigns updates and revokes organization members" do
          profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Udruzenje za kontrolu",
            slug: "udruzenje-za-kontrolu",
            kind: "association",
            verification_status: "verified"
          )

          sign_in @admin
          get "/admin/bih/organizations/#{profile.id}/memberships", params: { member_q: "Ana" }
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.admin.partner_profiles.memberships.title")
          assert_includes response.body, "Ana Gradjanka"

          assert_difference -> { Decidim::Bih::PartnerMembership.count }, 1 do
            assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_membership_added").count }, 1 do
              post "/admin/bih/organizations/#{profile.id}/memberships",
                   params: {
                     partner_membership: {
                       decidim_user_id: @citizen.id,
                       role: "owner",
                       status: "accepted"
                     }
                   }
            end
          end
          assert_response :redirect

          membership = profile.memberships.find_by!(user: @citizen)
          assert_equal "owner", membership.role
          assert_equal "pending", membership.status
          assert_equal @admin, membership.invited_by
          assert_nil membership.accepted_at
          assert_nil membership.revoked_at

          assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_membership_updated").count }, 1 do
            patch "/admin/bih/organizations/#{profile.id}/memberships/#{membership.id}",
                  params: {
                    partner_membership: {
                      role: "content_editor",
                      status: "accepted"
                    }
                  }
          end
          assert_response :redirect
          membership.reload
          assert_equal "content_editor", membership.role
          assert_equal "pending", membership.status
          assert_nil membership.revoked_at

          assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_membership_revoked").count }, 1 do
            delete "/admin/bih/organizations/#{profile.id}/memberships/#{membership.id}"
          end
          assert_response :redirect
          membership.reload
          assert_equal "revoked", membership.status
          assert membership.revoked_at.present?
          assert_empty Decidim::Bih::PartnerMembership.accepted.where(user: @citizen)
        end

        test "admin reinvitation cannot turn the last accepted manager pending" do
          profile = verified_partner_profile("Partner for reinvitation")
          membership = accepted_partner_membership(profile, @citizen, role: "owner")
          sign_in @admin

          assert_no_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_membership_updated").count } do
            post "/admin/bih/organizations/#{profile.id}/memberships",
                 params: { partner_membership: { decidim_user_id: @citizen.id, role: "owner" } }
          end

          assert_response :redirect
          assert_equal "accepted", membership.reload.status
          assert_nil membership.revoked_at
          assert_equal I18n.t("decidim.bih.partner_memberships.last_manager_required"), flash[:alert]
        end

        test "admin cannot demote or revoke the last volunteer manager while a public need is open" do
          profile = verified_partner_profile("Partner sa otvorenom potrebom")
          membership = accepted_partner_membership(profile, @citizen, role: "owner")
          create_approved_open_need(profile, @citizen)
          sign_in @admin

          assert_no_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_membership_updated").count } do
            patch "/admin/bih/organizations/#{profile.id}/memberships/#{membership.id}",
                  params: { partner_membership: { role: "member", status: "accepted" } }
          end

          assert_response :redirect
          assert_equal "owner", membership.reload.role
          assert_equal "accepted", membership.status
          assert_equal I18n.t("decidim.bih.partner_memberships.last_manager_required"), flash[:alert]

          assert_no_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "partner_membership_revoked").count } do
            delete "/admin/bih/organizations/#{profile.id}/memberships/#{membership.id}"
          end

          assert_response :redirect
          assert_equal "accepted", membership.reload.status
          assert_nil membership.revoked_at
          assert_equal I18n.t("decidim.bih.partner_memberships.last_manager_required"), flash[:alert]
        end

        test "admin may revoke a manager when a replacement exists but cannot strand a suspended profile" do
          profile = verified_partner_profile("Partner sa zamjenom")
          owner = accepted_partner_membership(profile, @citizen, role: "owner")
          replacement_user = FactoryBot.create(:user, :confirmed, organization: @organization)
          replacement = accepted_partner_membership(profile, replacement_user, role: "manager")
          create_approved_open_need(profile, @citizen)
          sign_in @admin

          delete "/admin/bih/organizations/#{profile.id}/memberships/#{owner.id}"

          assert_response :redirect
          assert_equal "revoked", owner.reload.status

          profile.update!(verification_status: "suspended")
          delete "/admin/bih/organizations/#{profile.id}/memberships/#{replacement.id}"

          assert_response :redirect
          assert_equal "accepted", replacement.reload.status
          assert_equal I18n.t("decidim.bih.partner_memberships.last_manager_required"), flash[:alert]
        end

        test "admin cannot assign organization control to other tenant users or legacy groups" do
          profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Sigurna organizacija",
            slug: "sigurna-organizacija",
            kind: "association",
            verification_status: "verified"
          )
          other_organization = create_organization
          other_user = FactoryBot.create(:user, :confirmed, organization: other_organization, name: "Drugi Korisnik")
          legacy_group = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Stara grupa", extended_data: { "group" => true })

          sign_in @admin

          assert_no_difference -> { Decidim::Bih::PartnerMembership.count } do
            post "/admin/bih/organizations/#{profile.id}/memberships",
                 params: {
                   partner_membership: {
                     decidim_user_id: other_user.id,
                     role: "owner",
                     status: "accepted"
                   }
                 }
          end
          assert_response :redirect

          assert_no_difference -> { Decidim::Bih::PartnerMembership.count } do
            post "/admin/bih/organizations/#{profile.id}/memberships",
                 params: {
                   partner_membership: {
                     decidim_user_id: legacy_group.id,
                     role: "owner",
                     status: "accepted"
                   }
                 }
          end
          assert_response :redirect
        end

        def verified_partner_profile(name)
          Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: name,
            slug: "#{name.parameterize}-#{SecureRandom.hex(4)}",
            kind: "association",
            verification_status: "verified",
            verified_at: Time.current
          )
        end

        def accepted_partner_membership(profile, user, role:)
          profile.memberships.create!(
            organization: @organization,
            user:,
            role:,
            status: "accepted",
            accepted_at: Time.current
          )
        end

        def create_approved_open_need(profile, author)
          Decidim::Bih::ContributionNeed.create!(
            organization: @organization,
            partner_profile: profile,
            author:,
            need_type: "equipment",
            title: "Alat za akciju",
            description: "Potrebna oprema za odobrenu zajedničku akciju.",
            quantity: 2,
            unit: "komada",
            review_status: "approved",
            fulfillment_status: "open",
            reviewed_at: Time.current,
            published_at: Time.current
          )
        end

        test "admin audit page renders safe metadata without private note fields" do
          Decidim::Bih::OperatorAuditEvent.record!(
            organization: @organization,
            actor: @admin,
            event_type: "operator_test_event",
            permission: "reports_update_status",
            metadata: {
              status: "approved",
              internal_note: "private operator note",
              nested: { note: "secret", count: 1 }
            }
          )

          sign_in @admin
          get "/admin/bih/operator-audit", params: { event_type: "operator_test_event" }

          assert_response :success
          assert_includes response.body, "Operator test event"
          assert_select "details summary", text: /tehničke detalje/
          assert_includes response.body, "approved"
          assert_includes response.body, "count"
          assert_not_includes response.body, "private operator note"
          assert_not_includes response.body, "secret"
        end

        test "support operator without general support permission cannot use broad message path" do
          Decidim::Bih::OperatorRole.create!(
            organization: @organization,
            user: @operator,
            role: "support_agent",
            created_by: @admin,
            expires_at: 30.days.from_now
          )

          sign_in @operator
          get "/admin/bih/messages/new", params: { recipient_id: @citizen.id }
          assert_response :redirect
          assert_equal "http://#{@organization.host}/admin/", response.location
        end

        test "case-bound support operator sends a report message with audit context" do
          report = Decidim::Bih::Report.create!(
            organization: @organization,
            author: @citizen,
            description: "Rupa na pjesackoj stazi",
            reference: "BR-2026-9001"
          )
          %w(report_triager support_agent).each do |role|
            Decidim::Bih::OperatorRole.create!(
              organization: @organization,
              user: @operator,
              role:,
              created_by: @admin,
              expires_at: 30.days.from_now
            )
          end

          sign_in @operator
          get "/admin/bih/reports/#{report.reference}"
          assert_response :success
          assert_select "#report-decision-form option[value=message]", count: 1

          get "/admin/bih/messages/new", params: { context_type: "report", context_id: report.id }
          assert_response :success
          assert_includes response.body, report.reference
          assert_includes response.body, "Ana Gradjanka"

          published_payload = nil
          Decidim::EventsManager.stub(:publish, lambda { |**payload|
            published_payload = payload
            true
          }) do
            assert_difference -> { Decidim::Bih::OperatorMessage.count }, 1 do
              assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "operator_message_sent").count }, 1 do
                post "/admin/bih/messages",
                     params: {
                       context_type: "report",
                       context_id: report.id,
                       subject: "Dopuna prijave",
                       body: "Molimo provjerite status prijave.",
                       message_reviewed: "1"
                     }
              end
            end
          end
          assert_response :redirect
          assert_equal "http://#{@organization.host}/admin/bih/reports/#{report.reference}", response.location

          message = Decidim::Bih::OperatorMessage.order(:created_at).last
          assert_equal @operator, message.sender
          assert_equal @citizen, message.recipient
          assert_equal "Decidim::Bih::Report", message.context_type
          assert_equal report.id, message.context_id
          assert_nil published_payload, "report messages use the case notification job"
          case_message = report.case_messages.last
          assert_equal @operator, case_message.actor
          assert_includes case_message.body, "Molimo provjerite status prijave."
          assert_enqueued_with(job: Decidim::Bih::ReportCaseMessageJob, args: [case_message.id])

          audit = Decidim::Bih::OperatorAuditEvent.where(event_type: "operator_message_sent").order(:created_at).last
          assert_equal "support_agent", audit.role
          assert_equal "operator_message_send", audit.permission
          assert_equal "Decidim::Bih::Report", audit.metadata.fetch("context_type")
          assert_equal report.id, audit.metadata.fetch("context_id")
          assert_not_includes audit.metadata.to_json, "Molimo provjerite"
        end

        test "case-bound support message requires report read access" do
          report = Decidim::Bih::Report.create!(
            organization: @organization,
            author: @citizen,
            description: "Rupa na putu",
            reference: "BR-2026-9002"
          )
          Decidim::Bih::OperatorRole.create!(
            organization: @organization,
            user: @operator,
            role: "support_agent",
            created_by: @admin,
            expires_at: 30.days.from_now
          )

          sign_in @operator
          get "/admin/bih/messages/new", params: { context_type: "report", context_id: report.id }
          assert_response :redirect
          assert_equal "http://#{@organization.host}/admin/", response.location
        end

        test "general support operator sends a Decidim-only message and writes audit row" do
          Decidim::Bih::OperatorRole.create!(
            organization: @organization,
            user: @operator,
            role: "general_support_agent",
            created_by: @admin,
            expires_at: 30.days.from_now
          )

          sign_in @operator
          get "/admin/bih/messages/new", params: { recipient_id: @citizen.id }
          assert_response :success
          assert_includes response.body, "Ana Gradjanka"

          published_payload = nil
          Decidim::EventsManager.stub(:publish, lambda { |**payload|
            published_payload = payload
            true
          }) do
            assert_difference -> { Decidim::Bih::OperatorMessage.count }, 1 do
              assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "operator_message_sent").count }, 1 do
                post "/admin/bih/messages",
                     params: {
                       recipient_id: @citizen.id,
                       subject: "Status prijave",
                       body: "Sadrzaj poruke za korisnika.",
                       message_reviewed: "1"
                     }
              end
            end
          end
          assert_response :redirect

          message = Decidim::Bih::OperatorMessage.order(:created_at).last
          assert_equal @operator, message.sender
          assert_equal @citizen, message.recipient
          assert_equal "Status prijave", message.subject
          assert_equal "decidim.events.bih.operator.message", published_payload.fetch(:event)

          audit = Decidim::Bih::OperatorAuditEvent.where(event_type: "operator_message_sent").order(:created_at).last
          assert_equal "general_support_agent", audit.role
          assert_equal "general_support_message_send", audit.permission
          assert_equal @citizen.id, audit.metadata.fetch("recipient_id")
          assert_equal message.subject.length, audit.metadata.fetch("subject_length")
          assert_equal message.body.length, audit.metadata.fetch("body_length")
          assert_not_includes audit.metadata.to_json, "Sadrzaj poruke"
        end

        test "organization membership context preserves draft until message review is confirmed" do
          profile = Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: "Organizacija za podrsku",
            slug: "organizacija-za-podrsku",
            kind: "association",
            verification_status: "verified",
            public_description: "Organizacija sa potpunim javnim opisom za provjeru."
          )
          membership = profile.memberships.create!(
            organization: @organization,
            user: @citizen,
            role: "owner",
            status: "accepted",
            accepted_at: Time.current
          )

          sign_in @admin
          assert_no_difference -> { Decidim::Bih::OperatorMessage.count } do
            post "/admin/bih/messages",
                 params: {
                   context_type: "partner_membership",
                   context_id: membership.id,
                   subject: "Dokumentacija",
                   body: "Molimo dopunite javni opis."
                 }
          end

          assert_response :unprocessable_entity
          assert_includes response.body, "Dokumentacija"
          assert_includes response.body, "Molimo dopunite javni opis."

          assert_difference -> { Decidim::Bih::OperatorMessage.count }, 1 do
            post "/admin/bih/messages",
                 params: {
                   context_type: "partner_membership",
                   context_id: membership.id,
                   subject: "Dokumentacija",
                   body: "Molimo dopunite javni opis.",
                   message_reviewed: "1"
                 }
          end
          assert_response :redirect
          message = Decidim::Bih::OperatorMessage.order(:id).last
          assert_equal "Decidim::Bih::PartnerMembership", message.context_type
          assert_equal membership.id, message.context_id
          assert_equal @citizen, message.recipient
        end
      end
    end
  end
end
