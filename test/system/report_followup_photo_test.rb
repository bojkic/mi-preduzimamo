# frozen_string_literal: true

require "application_system_test_case"

class ReportFollowupPhotoTest < ApplicationSystemTestCase
  test "citizen uploads a photo against the specific outstanding question and staff can view the followup" do
    organization = create_organization
    use_organization_host!(organization)
    admin = FactoryBot.create(:user, :admin, :confirmed, organization:)
    report = Decidim::Bih::Report.create!(organization:, description: "Fixture damaged container", address: "Fixture street")
    question = report.case_messages.create!(actor: admin, actor_role: "staff", kind: "question", body: "Please attach the requested photograph.")
    obligation = Decidim::Bih::ReportObligations.open!(report, kind: "info_request", actor: "citizen", source: question)
    visit report.tokenized_status_path
    accept_data_consent!
    within "#report-private-conversation" do
      assert_text question.body
      assert_selector "input[type=hidden][name=\"case_message[answers_message_id]\"][value=\"#{question.id}\"]", visible: :all
      fill_in "case_message[body]", with: "Here is the requested photograph."
      attach_file "case_message[photo]", Rails.root.join("test/fixtures/files/chat_photo.jpg")
      click_button I18n.t("decidim.bih.report_case.reply")
    end
    assert_selector "#report-private-conversation", text: "Here is the requested photograph."
    reply = report.case_messages.where(actor_role: "citizen").order(:id).last
    assert_equal question, reply.answers_message
    assert reply.photo.attached?
    assert_equal "image/jpeg", reply.photo.blob.content_type
    assert_equal "fulfilled", obligation.reload.state
    assert_equal reply, obligation.fulfilled_by
    assert_no_horizontal_overflow!
    sign_in_user! admin
    visit "/admin/bih/reports/#{report.reference}"
    assert_selector "#report-case-conversation", text: reply.body
    assert_link I18n.t("decidim.bih.report_evidence.download"), href: "?photo_message_id=#{reply.id}"
  end
end
