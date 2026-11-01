# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # 2026-10-06: a City reply to one follow-up was also linked to two other
    # cases because Gmail had grouped the follow-ups into one thread.
    class ReportMailboxThreadAssociationTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        @answered = forwarded_report
        @neighbour = forwarded_report
        @dispatch = ReportDispatching.queue!(report: @answered, actor: @admin, digest: ReportCaseWorkflow.digest(@answered), kind: "followup", text: "Status?")
        copy = InboundEmail.create!(organization: @organization, account: "prijave@example.org", folder: "[Gmail]/All Mail", gm_msgid: "copy-1",
                                    uidvalidity: 1, uid: 1, size_bytes: 10, internal_date: Time.current, gm_thrid: "thread-1",
                                    classification: "outbound_copy", state: "processed")
        InboundEmailLink.create!(inbound_email: copy, report: @neighbour, matching_method: "in_reply_to", assurance: "association")
      end

      def forwarded_report
        Report.create!(organization: @organization, description: "Crossing is unsafe", address: "Test street", category: "saobracaj",
                       review_state: "validated", reviewed_at: 1.day.ago, status: "proslijedjeno", forwarded_at: 1.day.ago,
                       forwarding_recipient: "intake@example.org")
      end

      def reply(in_reply_to: nil, subject: "Re: Upit")
        mail = Mail.new(from: "city@city.example", to: "prijave@example.org", subject:, body: "Proslijeđeno nadležnom odjeljenju.")
        mail.in_reply_to = in_reply_to if in_reply_to
        mail
      end

      test "a precise reply header is not widened to other cases in the same Gmail thread" do
        links = ReportMailbox::Associator.call(reply(in_reply_to: @dispatch.message_id), organization: @organization, gm_thrid: "thread-1")
        assert_equal([[@answered.id, "in_reply_to"]], links.map { |link| [link[:report].id, link[:matching_method]] })
      end

      test "the Gmail thread is still used when nothing more precise matches" do
        links = ReportMailbox::Associator.call(reply, organization: @organization, gm_thrid: "thread-1")
        assert_equal([[@neighbour.id, "gmail_thread"]], links.map { |link| [link[:report].id, link[:matching_method]] })
      end
    end
  end
end
