# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    # 2026-10-06: City-reply bells were attached to the report, and the
    # notifications page then failed with a 500 for every staff member.
    class StaffNotificationsRender20261006Test < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      test "a City reply bell renders on the staff notifications page" do
        organization = create_organization
        admin = FactoryBot.create(:user, :admin, :confirmed, organization:)
        report = Report.create!(organization:, description: "Crossing", address: "Test street", category: "saobracaj")
        email = InboundEmail.create!(organization:, account: "prijave@example.org", folder: "INBOX", gm_msgid: "city-1", uidvalidity: 1, uid: 1,
                                     size_bytes: 10, internal_date: Time.current, state: "review", classification: "candidate")
        ReportCityReply::StaffNotice.call(report:, inbound_email: email, reason: "mail_review")
        notification = Decidim::Notification.where(user: admin).last
        assert_equal admin, notification.resource
        host! organization.host
        sign_in admin
        get "/notifications"
        assert_response :success
      end
    end
  end
end
