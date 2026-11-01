# frozen_string_literal: true

require "test_helper"
require "support/synthetic_messaging_configuration"
require "minitest/mock"

module Decidim
  module Bih
    module Sistem48
      class ForwarderTest < ActiveSupport::TestCase
        include SyntheticMessagingConfiguration

        teardown { restore_synthetic_intake }

        setup { install_synthetic_intake }
        include ActiveJob::TestHelper
        include ActionMailer::TestHelper

        Report = Struct.new(
          :reference, :category, :department, :severity, :description,
          :address, :lat, :lng, :photo_url, :reporter_contact,
          keyword_init: true
        )

        def report
          Report.new(
            reference: "BR-2026-0007",
            category: :rasvjeta,
            department: "Javna rasvjeta",
            severity: :normalan,
            description: "Ne radi ulična rasvjeta cijelom ulicom.",
            address: "Izmišljena ulica 3, Testna zajednica",
            lat: 0.15,
            lng: 0.25,
            photo_url: nil
          )
        end

        test "call forwards the report by e-mail and returns true" do
          result = nil
          assert_emails 1 do
            result = Forwarder.new.call(report)
          end

          assert result
          delivered = ActionMailer::Base.deliveries.last
          assert_equal [DepartmentRouting.central_intake], delivered.to
          assert_includes delivered.subject, "BR-2026-0007"
        end

        test "call accepts a plain Hash report" do
          assert_emails 1 do
            assert Forwarder.new.call(report.to_h)
          end
        end

        test "call rescues mail errors and returns false" do
          boom = ->(*) { raise StandardError, "smtp down for reporter@example.org +387 65 123 456" }
          forwarder = Forwarder.new

          ReportMailer.stub(:report_email, boom) do
            assert_no_emails do
              assert_not forwarder.call(report)
            end
          end

          assert_instance_of StandardError, forwarder.last_error
        end
      end
    end
  end
end
