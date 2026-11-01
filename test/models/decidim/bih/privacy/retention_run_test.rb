# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Privacy
      class RetentionRunTest < ActiveSupport::TestCase
        test "failure metadata is sanitized before persistence" do
          organization = create_organization
          run = RetentionRun.create!(
            organization: organization,
            dry_run: false,
            source: "test",
            started_at: Time.current,
            cutoffs: { "report_contact_before" => 3.years.ago.utc.iso8601 }
          )

          run.fail!(RuntimeError.new("email old@example.org phone +387 65 111 222 api_key=secret"))

          assert_equal "fail", run.status
          assert_equal "RuntimeError", run.error_class
          assert_includes run.error_message, "[email]"
          assert_includes run.error_message, "[phone]"
          assert_includes run.error_message, "api_key=[redacted]"
          assert_not_includes run.error_message, "old@example.org"
          assert_not_includes run.error_message, "+387 65 111 222"
          assert_not_includes run.error_message, "secret"
        end

        test "finish stores only aggregate counts and total" do
          organization = create_organization
          run = RetentionRun.create!(
            organization: organization,
            dry_run: true,
            source: "test",
            started_at: Time.current,
            cutoffs: { "report_contact_before" => 3.years.ago.utc.iso8601 }
          )

          run.finish!(counts: { "report_contacts" => 2, "report_photos" => 1 })

          assert_equal "ok", run.status
          assert_equal({ "report_contacts" => 2, "report_photos" => 1 }, run.counts)
          assert_equal 3, run.total
          assert_not run.live?
        end
      end
    end
  end
end
