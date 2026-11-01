# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Decidim
  module Bih
    module Sistem48
      class ArchiveSyncJobTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup { @organization = create_organization }

        test "runs on the integrations queue" do
          assert_equal "integrations", Decidim::Bih::Sistem48::ArchiveSyncJob.queue_name
        end

        test "resolves the organization and delegates to ArchiveSync" do
          sync = Minitest::Mock.new
          sync.expect(:call, 0)
          received_org = nil

          ArchiveSync.stub(:new, lambda { |org|
            received_org = org
            sync
          }) do
            Decidim::Bih::Sistem48::ArchiveSyncJob.perform_now(@organization.id)
          end

          assert_equal @organization, received_org
          sync.verify
        end

        test "is a no-op for an unknown organization id" do
          called = false
          ArchiveSync.stub(:new, lambda { |_org|
            called = true
            Minitest::Mock.new
          }) do
            Decidim::Bih::Sistem48::ArchiveSyncJob.perform_now(-1)
          end

          assert_not called
        end
      end
    end
  end
end
