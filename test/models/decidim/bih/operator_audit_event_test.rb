# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class OperatorAuditEventTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @actor = create(:user, :admin, :confirmed, organization: @organization)
      end

      test "recorded audit events are readonly after creation" do
        event = OperatorAuditEvent.record!(
          organization: @organization,
          actor: @actor,
          event_type: "operator_role_granted",
          metadata: { "status" => "ok" }
        )

        assert event.persisted?
        assert event.readonly?
      end

      test "recorded audit events reject updates" do
        event = OperatorAuditEvent.record!(
          organization: @organization,
          actor: @actor,
          event_type: "operator_role_granted",
          metadata: { "status" => "ok" }
        )

        assert_raises ActiveRecord::ReadOnlyRecord do
          event.update!(event_type: "tampered")
        end
        assert_equal "operator_role_granted", OperatorAuditEvent.find(event.id).event_type
      end

      test "recorded audit events reject destroys" do
        event = OperatorAuditEvent.record!(
          organization: @organization,
          actor: @actor,
          event_type: "operator_role_granted",
          metadata: { "status" => "ok" }
        )

        assert_raises ActiveRecord::ReadOnlyRecord do
          event.destroy!
        end
        assert OperatorAuditEvent.exists?(event.id)
      end
    end
  end
end
