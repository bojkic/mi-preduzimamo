# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      class GovernanceControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "admin records bounded governance approval evidence" do
          with_public_verification_policy do
            sign_in @admin

            assert_difference -> { Decidim::Bih::GovernanceApproval.count }, 1 do
              assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "governance_approval_recorded").count }, 1 do
                post "/admin/bih/governance/release_restart/approvals", params: {
                  governance_approval: {
                    status: "approved",
                    scope_key: "release-2026-07-09",
                    app_sha: "a" * 40,
                    engine_sha: "b" * 40,
                    restart_window_starts_at: 1.hour.ago,
                    restart_window_ends_at: 1.hour.from_now,
                    verification_lane: "fast",
                    local_gate_status: "passed",
                    verification_result_digest: "sha256:#{"e" * 64}",
                    backup_health_status: "passed",
                    restore_smoke_status: "passed",
                    backup_manifest_digest: "sha256:#{"c" * 64}",
                    migration_state: "pending_reviewed",
                    evidence_summary: "Required local fast checks passed; restart window approved by owner.",
                    evidence_digest: "sha256:#{"a" * 64}"
                  }
                }
              end
            end

            approval = Decidim::Bih::GovernanceApproval.last
            assert_redirected_to "/admin/bih/governance#governance-release_restart"
            assert_equal @organization, approval.organization
            assert_equal @admin, approval.user
            assert_equal "release_restart", approval.governance_kind
            assert_equal "approved", approval.status
            assert_equal "a" * 40, approval.app_sha
            assert_equal "b" * 40, approval.engine_sha
            assert_equal "fast", approval.verification_lane
            assert_equal "passed", approval.local_gate_status
            assert_equal Decidim::Bih::GovernanceApproval.verification_scopes("fast").sort, approval.required_scopes
            assert_equal Decidim::Bih::GovernanceApproval.local_verification_policy_sha256, approval.verification_policy_sha256
            assert_nil approval.local_full_gate_status
            assert_nil approval.external_ci_status
            assert_nil approval.branch_protection_status
            assert_nil approval.secondary_approver
            assert_nil approval.secondary_approval_role
            assert_equal "docs/operations/release-approval-policy.md", approval.metadata.fetch("runbook")
            assert_not approval.local_verification_matches?(result: {}, result_digest: approval.verification_result_digest)
            assert approval.operator_audit_event.present?
            assert_equal "governance_approval_recorded", approval.operator_audit_event.event_type
            assert_equal approval.evidence_digest, approval.operator_audit_event.metadata.fetch("evidence_digest")
            assert_equal approval, Decidim::Bih::GovernanceApproval.current_release_for(
              @organization,
              app_sha: "a" * 40,
              engine_sha: "b" * 40,
              backup_manifest_digest: "sha256:#{"c" * 64}"
            )

            follow_redirect!
            assert_response :success
            assert_select "[data-governance-latest='release_restart']", text: /Required local fast checks passed/
            assert_select "[data-governance-latest='release_restart']", text: /#{"a" * 40}/
            assert_select "[data-release-attestation-status]", count: 0
            assert_not_includes response.body, "TOKEN"
            assert_not_includes response.body, "PASSWORD"
          end
        end

        test "release form requires explicit local evidence and retires external fields" do
          with_public_verification_policy do
            sign_in @admin
            get "/admin/bih/governance"
            assert_response :success
            assert_select "[data-governance-row='release_restart']" do
              %w(verification_lane local_gate_status verification_result_digest).each do |field|
                assert_select "[name='governance_approval[#{field}]'][required]", count: 1
              end
              %w(local_fast_gate_status local_full_gate_status external_ci_status branch_protection_status).each do |field|
                assert_select "[name='governance_approval[#{field}]']", count: 0
              end
              assert_select "select[name='governance_approval[local_gate_status]'] option[value='passed'][selected]", count: 0
              assert_select "select[name='governance_approval[local_gate_status]'] option[value='not_applicable']", count: 0
            end
          end
        end

        test "missing local policy does not expose release approval form" do
          sign_in @admin
          Decidim::Bih::GovernanceApproval.stub(:local_verification_policy, -> { raise Errno::ENOENT }) do
            get "/admin/bih/governance"
            assert_response :success
            assert_select "[data-governance-row='release_restart']" do
              assert_select "form[action*='release_restart']", count: 0
            end
            assert_no_difference -> { Decidim::Bih::GovernanceApproval.count } do
              post "/admin/bih/governance/release_restart/approvals", params: {
                governance_approval: {
                  status: "approved", app_sha: "a" * 40, engine_sha: "b" * 40,
                  verification_lane: "fast", local_gate_status: "passed",
                  verification_result_digest: "sha256:#{"e" * 64}",
                  restart_window_starts_at: 1.hour.ago, restart_window_ends_at: 1.hour.from_now,
                  backup_health_status: "passed", restore_smoke_status: "passed",
                  backup_manifest_digest: "sha256:#{"c" * 64}", migration_state: "no_pending",
                  evidence_summary: "Authored fixture, no local policy exists."
                }
              }
            end
            assert_response :unprocessable_entity
          end
        end

        test "legacy green fields cannot create a new approval without local evidence" do
          sign_in @admin
          assert_no_difference -> { Decidim::Bih::GovernanceApproval.count } do
            post "/admin/bih/governance/release_restart/approvals", params: {
              governance_approval: {
                status: "approved", app_sha: "a" * 40, engine_sha: "b" * 40,
                restart_window_starts_at: 1.hour.ago, restart_window_ends_at: 1.hour.from_now,
                local_fast_gate_status: "passed", local_full_gate_status: "passed",
                external_ci_status: "passed", branch_protection_status: "verified",
                backup_health_status: "passed", restore_smoke_status: "passed",
                backup_manifest_digest: "sha256:#{"c" * 64}", migration_state: "no_pending",
                evidence_summary: "Old fields alone cannot authorize a new release."
              }
            }
          end
          assert_response :unprocessable_entity
        end

        test "secret-like governance evidence is rejected and not echoed" do
          sign_in @admin

          assert_no_difference -> { Decidim::Bih::GovernanceApproval.count } do
            post "/admin/bih/governance/privacy_retention/approvals", params: {
              governance_approval: {
                status: "approved",
                scope_key: "monthly-run",
                evidence_summary: "dry run passed TOKEN=private-value",
                evidence_digest: "sha256:#{"b" * 64}"
              }
            }
          end

          assert_response :unprocessable_entity
          assert_select "[data-governance-row='privacy_retention'] details[open]"
          assert_not_includes response.body, "private-value"
          assert_not_includes response.body, "TOKEN=private-value"
        end

        test "admin records channel-scoped external chat launch approval" do
          sign_in @admin
          scope = Decidim::Bih::GovernanceApproval.external_chat_scope_key(%w(whatsapp messenger))

          assert_difference -> { Decidim::Bih::GovernanceApproval.count }, 1 do
            post "/admin/bih/governance/external_chat_launch/approvals", params: {
              governance_approval: {
                status: "approved",
                scope_key: scope,
                evidence_summary: "Live WhatsApp and Messenger round trips verified.",
                evidence_digest: "sha256:#{"d" * 64}"
              }
            }
          end

          approval = Decidim::Bih::GovernanceApproval.last
          assert_redirected_to "/admin/bih/governance#governance-external_chat_launch"
          assert_equal "external_chat_launch", approval.governance_kind
          assert_equal scope, approval.scope_key
          assert_equal "docs/operations/omnichannel-chat-live-verification.md", approval.metadata.fetch("runbook")
        end

        test "non-admin cannot create governance approvals" do
          sign_in @citizen

          assert_no_difference -> { Decidim::Bih::GovernanceApproval.count } do
            post "/admin/bih/governance/release_restart/approvals", params: {
              governance_approval: {
                status: "approved",
                evidence_summary: "release gate passed"
              }
            }
          end

          assert_response :redirect
        end

        test "governance handoff remains readable while approval storage is unavailable" do
          sign_in @admin

          Decidim::Bih::GovernanceApproval.stub(:storage_available?, false) do
            get "/admin/bih/governance"

            assert_response :success
            assert_select "[data-governance-storage='unavailable']"
            assert_select "[data-governance-row]", count: Decidim::Bih::GovernanceApproval::GOVERNANCE_KINDS.size
            assert_select "form[action*='/governance/']", count: 0
          end
        end

        test "governance handoff remains readable when approval lookup raises a schema error" do
          sign_in @admin

          Decidim::Bih::GovernanceApproval.stub(:storage_available?, true) do
            Decidim::Bih::GovernanceApproval.stub(:latest_by_kind, ->(*) { raise ActiveRecord::StatementInvalid, "missing governance table" }) do
              get "/admin/bih/governance"

              assert_response :success
              assert_select "[data-governance-storage='unavailable']"
              assert_select "form[action*='/governance/']", count: 0
            end
          end
        end

        test "admin cannot submit an approval while approval storage is unavailable" do
          sign_in @admin

          Decidim::Bih::GovernanceApproval.stub(:storage_available?, false) do
            assert_no_difference -> { Decidim::Bih::GovernanceApproval.count } do
              post "/admin/bih/governance/release_restart/approvals", params: {
                governance_approval: {
                  status: "approved",
                  evidence_summary: "release gate passed"
                }
              }
            end

            assert_redirected_to "/admin/bih/governance"
          end
        end

        test "approval schema errors return to the readable governance handoff" do
          sign_in @admin

          recorder = ->(**) { raise ActiveRecord::StatementInvalid, "missing governance table" }
          Decidim::Bih::Governance::ApprovalRecorder.stub(:call, recorder) do
            post "/admin/bih/governance/release_restart/approvals", params: {
              governance_approval: {
                status: "approved",
                evidence_summary: "release gate passed"
              }
            }
          end

          assert_redirected_to "/admin/bih/governance"
        end
        private

        def with_public_verification_policy
          model = Decidim::Bih::GovernanceApproval
          path = Rails.root.join("config/examples/release-approval-policy.example.yml")
          policy = YAML.safe_load_file(path)
          digest = Digest::SHA256.file(path).hexdigest
          model.stub(:local_verification_policy, policy) do
            model.stub(:local_verification_policy_sha256, digest) { yield }
          end
        end
      end
    end
  end
end
