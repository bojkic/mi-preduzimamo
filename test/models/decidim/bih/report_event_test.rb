# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportEventTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa na putu",
          address: "Vidovdanska 1"
        )
      end

      test "report records append-only event with actor and sanitized metadata" do
        event = @report.record_event!(
          "status_changed",
          actor: @admin,
          metadata: {
            from_status: "primljeno",
            to_status: "proslijedjeno",
            internal_note: "NE SMIJE U DOGADJAJ",
            reporter_email: "citizen@example.test"
          }
        )

        assert_equal @report, event.report
        assert_equal @organization, event.organization
        assert_equal @admin, event.actor
        assert_equal "admin", event.source
        assert_equal "admin", event.actor_role
        assert_equal "primljeno", event.metadata["from_status"]
        assert_equal "proslijedjeno", event.metadata["to_status"]
        assert_not event.metadata.has_key?("internal_note")
        assert_not event.metadata.has_key?("reporter_email")
      end

      test "events cannot be updated or destroyed" do
        event = @report.record_event!("forwarding_retry_enqueued", actor: @admin, metadata: { status: "primljeno" })

        assert_raises ActiveRecord::ReadOnlyRecord do
          event.update!(metadata: { status: "rijeseno" })
        end
        assert_raises ActiveRecord::ReadOnlyRecord do
          event.destroy!
        end
      end

      test "event actor must belong to the same organization" do
        other_admin = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
        event = Decidim::Bih::ReportEvent.new(
          report: @report,
          actor: other_admin,
          event_type: "status_changed",
          source: "admin",
          actor_role: "admin"
        )

        assert_not event.valid?
        assert event.errors[:decidim_user_id].any?
      end
    end
  end
end
