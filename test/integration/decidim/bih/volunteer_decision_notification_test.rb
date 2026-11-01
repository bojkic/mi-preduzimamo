# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class VolunteerDecisionNotificationTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization(badges_enabled: false)
        @volunteer = FactoryBot.create(:user, :confirmed, organization: @organization)
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @profile = PartnerProfile.create!(
          organization: @organization,
          display_name: "Udruženje obavijesti",
          slug: "udruzenje-obavijesti",
          kind: "association",
          verification_status: "verified",
          verified_at: Time.current
        )
        @opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          author: @volunteer,
          title: "Sadnja drveća",
          category: "environment",
          partner_profile: @profile,
          partner_name: @profile.display_name,
          active: false,
          review_status: "pending"
        )
      end

      test "approval notification title renders" do
        perform_enqueued_jobs do
          ApproveVolunteerOpportunity.call(@opportunity, reviewer: @admin, confirm_partner: true)
        end

        notification = Decidim::Notification.where(
          decidim_user_id: @volunteer.id,
          event_class: "Decidim::Bih::VolunteerDecisionEvent"
        ).first
        assert_not_nil notification
        assert_includes notification.event_class_instance.notification_title, "Sadnja drveća"
      end
    end
  end
end
