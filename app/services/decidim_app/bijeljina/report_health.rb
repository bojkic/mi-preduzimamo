# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Keeps the two operator duties separate in the health report.
    module ReportHealth
      module_function

      def first_response(scope, now:, stale_minutes:)
        scope.where(status: "primljeno", review_state: "pending", reviewed_at: nil)
             .where.not(id: Decidim::Bih::ReportMessage.where(actor_role: "staff").select(:report_id))
             .where("created_at < ?", now - stale_minutes.minutes)
      end

      def citizen_reply_overdue(scope, now:)
        scope.where(review_state: "needs_information").where("response_due_at < ?", now)
             .where.not(status: Decidim::Bih::Report::TERMINAL_STATUSES)
      end
    end
  end
end
