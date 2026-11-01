# frozen_string_literal: true

require "digest"

module DecidimApp
  module Bijeljina
    # Operator-recorded, verified milestones; never deployment or activation.
    # Settings and audit records survive task cleanup. No WIP receipt discovery.
    class ReportRolloutReadiness
      NAMESPACE = "report_rollout"
      KEY = "verified_milestones"
      EVENT = "decidim.events.decidim_app.report_rollout_readiness"
      AUDIT = "report_rollout_readiness_notified"
      FREEZE = Time.utc(2026, 10, 14, 18)
      REQUIREMENTS = {
        "R2" => %w(R1), "R3" => %w(R1), "R4" => %w(R3),
        "R5" => %w(R4), "R6" => %w(R2 R5), "R7" => %w(R5 T2.6), "R8" => %w(R6 T3.7)
      }.freeze
      EVIDENCE_KEYS = (%w(R1) + REQUIREMENTS.keys + %w(T3.7 T2.6)).freeze

      def initialize(organization:, now: Time.current)
        @organization = organization
        @now = now
      end

      # Trusted operator API ONLY after the exact deployment/runtime verification
      # (R*) or named gate (T*) is independently verified. Approval is identity,
      # not proof that a deployment or shadow interval happened.
      def record_verified!(key:, owner_approval:, evidence_digest:)
        raise ArgumentError, "Unknown milestone" unless EVIDENCE_KEYS.include?(key)
        raise ArgumentError, "Evidence digest required" unless evidence_digest.match?(/\Asha256:[0-9a-f]{64}\z/)

        owner = authenticated_owner(owner_approval)
        raise ArgumentError, "Authenticated release owner required" unless owner

        owner.with_lock do
          state = stored_state
          previous = state["owner_approval_id"]
          raise ArgumentError, "Release owner source cannot change" if previous && previous != owner_approval.id

          state["owner_approval_id"] = owner_approval.id
          state[key] = { "evidence_digest" => evidence_digest, "verified_at" => now.utc.iso8601 }
          Decidim::Bih::Setting.put(organization, NAMESPACE, KEY, state)
          Decidim::Bih::OperatorAuditEvent.record!(organization:, actor: nil, role: "delegated_operator",
                                                   event_type: "report_rollout_milestone_verified", permission: "release_restart",
                                                   resource: owner_approval, metadata: { stage: key, evidence_digest:, authenticated_owner_approval_id: owner_approval.id })
          clear_notice(owner, key)
        end
      end

      def call
        state = stored_state
        approval = Decidim::Bih::GovernanceApproval.find_by(id: state["owner_approval_id"], organization:)
        owner = authenticated_owner(approval)
        return 0 unless owner

        owner.with_lock { notify_ready(owner, stored_state) }
      end

      private

      attr_reader :organization, :now

      def stored_state
        Decidim::Bih::Setting.namespace_for(organization, NAMESPACE).fetch(KEY, {}).deep_dup
      end

      def authenticated_owner(approval)
        return unless release_owner_approval?(approval)

        owner = approval.user
        return unless owner && owner.organization == organization && owner.admin? && !owner.blocked && owner.deleted_at.nil?
        return unless approval.operator_audit_event&.user == owner

        owner
      end

      def release_owner_approval?(approval)
        approval && approval.organization == organization && approval.status == "approved" &&
          approval.governance_kind == "release_restart" && approval.approval_role == "technical_release_owner"
      end

      def eligible?(stage, state)
        return false if state.has_key?(stage) || (stage == "R4" && now < FREEZE)

        REQUIREMENTS.fetch(stage).all? do |key|
          state.dig(key, "evidence_digest").to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
        end
      end

      def notify_ready(owner, state)
        REQUIREMENTS.keys.sum do |stage|
          unless eligible?(stage, state)
            clear_notice(owner, stage)
            next 0
          end
          condition = Digest::SHA256.hexdigest([stage, state["owner_approval_id"], *REQUIREMENTS.fetch(stage).map { |key| state.dig(key, "evidence_digest") }].join(":"))
          next 0 if notified?(owner, condition)

          clear_notice(owner, stage)
          Decidim::Notification.create!(user: owner, resource: owner, event_name: EVENT,
                                        event_class: ReportRolloutReadinessEvent.name,
                                        extra: { "received_as" => "affected_user", "stage" => stage, "condition" => condition })
          Decidim::Bih::OperatorAuditEvent.record!(organization:, actor: nil, event_type: AUDIT,
                                                   permission: "release_restart", resource: owner,
                                                   metadata: { stage:, condition: })
          1
        end
      end

      def notified?(owner, condition)
        Decidim::Bih::OperatorAuditEvent.where(organization:, event_type: AUDIT, resource_type: owner.class.base_class.name,
                                               resource_id: owner.id).exists?(["metadata ->> 'condition' = ?", condition])
      end

      def clear_notice(owner, stage)
        Decidim::Notification.where(user: owner, event_name: EVENT).where("extra ->> 'stage' = ?", stage).find_each(&:destroy!)
      end
    end
  end
end
