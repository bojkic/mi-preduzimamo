# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # 2026-10-06 morning review: staff decisions left their tasks open, City mail
    # followed the staff UI language, quoted case numbers linked unrelated cases
    # and the AI budget kept full worst-case reservations.
    class ReportPipelineFixes20261006Test < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        Setting.put(@organization, "sistem48_routing", "central_intake", "intake@example.org")
        @report = Report.create!(organization: @organization, description: "Crossing is unsafe", address: "Test street", category: "saobracaj",
                                 review_state: "validated", reviewed_at: 2.days.ago, status: "proslijedjeno", forwarded_at: 2.days.ago,
                                 forwarding_recipient: "intake@example.org")
      end

      def decide(action, values = {})
        ReportDecision.new(@report.reload, @admin).call(action:, values:, version: ReportReviewVersion.digest(@report.reload), confirmed: true)
      end

      test "a substantive decision closes earlier review and mail tasks but not approvals" do
        review = @report.obligations.create!(kind: "review", actor: "staff", due_at: 1.day.ago)
        mail = @report.obligations.create!(kind: "mail_review", actor: "staff", due_at: 1.day.from_now)
        approval = @report.obligations.create!(kind: "dispatch_approval", actor: "staff", due_at: 1.day.from_now)
        decide("note", body: "Internal note")
        assert review.reload.open?
        decide("review")
        assert_equal(%w(fulfilled fulfilled open), [review, mail, approval].map { |task| task.reload.state })
        assert_not_includes ReportWorkQueue.new(organization: @organization).scope("review").where.not(id: approval.report_id), @report
      end

      test "City mail uses the organization language whatever the staff interface uses" do
        ReportMailbox::ReplyAddress.ensure!(report: @report, audience: "service", correspondents: [@report.forwarding_recipient])
        mail = I18n.with_locale(:"sr-Cyrl") { ReportDispatching.preview(report: @report, kind: "followup", text: "Status?") }
        assert_equal "Upit o prijavi [#{@report.reference}]", mail.subject
      end

      test "case numbers in our own quoted e-mail do not link the reply to other cases" do
        other = Report.create!(organization: @organization, description: "Other", address: "Other street", category: "saobracaj")
        mail = Mail.new(from: "city@city.example", to: "prijave@example.org", subject: "Re: Upit o prijavi [#{@report.reference}]",
                        body: "Proslijeđeno odjeljenju.\n\nOn Mon, prijave@example.org wrote:\n> Povezano sa #{other.reference}\n")
        references = ReportMailbox::Associator.call(mail, organization: @organization).map { |link| link[:report].reference }
        assert_equal [@report.reference], references
      end

      test "the daily AI budget keeps only the tokens actually used" do
        client = Struct.new(:last_usage) do
          def generate_content(**) = (self.last_usage = { "promptTokenCount" => 1000, "candidatesTokenCount" => 500, "thoughtsTokenCount" => 500 }) && {}
        end.new
        prices = { "m" => { verified: true, input: 1.0, output: 10.0, requires_access_receipt: false } }
        usage = Ai::CaseUsage.new(prices:, cap: "5")
        usage.call(client:, model: "m", purpose: "primary", contents: [{ role: "user", parts: [{ text: "x" * 4000 }] }],
                   generation_limits: { max_output_tokens: 10_000, candidate_count: 1 })
        assert_in_delta 0.011, CaseUsageDay.find_by!(day: Time.current.utc.to_date).reserved_usd.to_f, 0.0001
      end
    end
  end
end
