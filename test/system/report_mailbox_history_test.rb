# frozen_string_literal: true

require "application_system_test_case"
require "tempfile"

class ReportMailboxHistoryTest < ApplicationSystemTestCase
  test "staff upload an original historical email then view and link it without opening live work" do
    organization = create_organization
    use_organization_host!(organization)
    admin = FactoryBot.create(:user, :admin, :confirmed, organization:)
    report = Decidim::Bih::Report.create!(organization:, description: "Fixture pothole", address: "Fixture street")
    before = report.attributes.slice("status", "review_state", "forwarded_at", "response_due_at", "resolved_at")
    obligation_count = report.obligations.count if report.respond_to?(:obligations)
    target = Decidim::Bih::ReportMailbox::Target::Selection.new(organization:, account: "fixture-mailbox@fixtures.invalid", config: nil)
    subject = "Historical fixture correspondence"
    body = "Original historical reply retained for staff review."
    raw = "From: service@fixtures.invalid\r\nTo: fixture-mailbox@fixtures.invalid\r\nSubject: #{subject}\r\n" \
          "Message-ID: <#{SecureRandom.uuid}@fixtures.invalid>\r\nDate: Wed, 1 Jan 2020 12:00:00 +0000\r\n\r\n#{body}\r\n"
    sign_in_user! admin
    visit "/admin/bih/report-mail"
    accept_data_consent!
    assert_text I18n.t("decidim.bih.report_mailbox.title")
    Decidim::Bih::ReportMailbox::Target.stub(:resolve!, target) do
      Tempfile.create(["fixture-history", ".eml"]) do |file|
        file.binmode
        file.write(raw)
        file.flush
        attach_file "history_file", file.path
        click_button I18n.t("decidim.bih.report_mailbox.import_history")
        assert_selector "h1", text: subject
        assert_text body
        assert_text I18n.t("decidim.bih.report_mailbox.history")
        email = Decidim::Bih::InboundEmail.find_by!(organization:, message_id: raw[/Message-ID: <([^>]+)>/, 1])
        assert_current_path "/admin/bih/report-mail/#{email.id}"
        assert email.history_only
        fill_in "references", with: report.reference
        click_button I18n.t("decidim.bih.report_mailbox.link")
        assert_field "references", with: ""
        assert_current_path "/admin/bih/report-mail/#{email.id}"
        link = email.inbound_email_links.find_by!(report:)
        assert_equal "manual", link.matching_method
        assert_equal "association", link.assurance
        assert_equal admin, link.created_by
        assert_equal "history", email.reload.state
        assert_equal before, report.reload.attributes.slice(*before.keys)
        assert_equal obligation_count, report.obligations.count if report.respond_to?(:obligations)
        assert_not report.events.exists?(event_type: "city_email_received")
        assert_empty report.case_messages
        assert_empty report.dispatches
        visit "/admin/bih/reports/#{report.reference}"
        assert_text body
        assert_link I18n.t("decidim.bih.report_mailbox.open"), href: "/admin/bih/report-mail/#{email.id}"
      end
    end
  end
end
