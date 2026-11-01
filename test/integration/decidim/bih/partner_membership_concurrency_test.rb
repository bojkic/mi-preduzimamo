# frozen_string_literal: true

require "test_helper"
require "timeout"

module Decidim
  module Bih
    # Each worker must see committed rows through its own PostgreSQL connection.
    class PartnerMembershipConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @organization = create_organization
        @profile = PartnerProfile.create!(
          organization: @organization, display_name: "Concurrent partner",
          slug: "concurrent-partner-#{SecureRandom.hex(4)}", kind: "association",
          verification_status: "verified", verified_at: Time.current
        )
        @users = 2.times.map { FactoryBot.create(:user, :confirmed, organization: @organization) }
        @memberships = @users.map do |user|
          @profile.memberships.create!(
            organization: @organization, user:, role: "manager",
            status: "accepted", accepted_at: Time.current
          )
        end
      end

      teardown do
        if @organization
          ContributionNeed.where(partner_profile: @profile).delete_all
          PartnerMembership.where(partner_profile: @profile).delete_all
          PartnerProfile.where(id: @profile.id).delete_all
          @users&.each(&:destroy!)
          @organization.static_pages.delete_all
          @organization.destroy!
        end
      end

      test "direct model updates on separate connections preserve a manager" do
        results = concurrent_changes do |membership|
          PartnerMembership.find(membership.id).update!(role: "member")
          :changed
        end

        assert_equal [:changed, :retained], results.sort
        assert_equal 1, @profile.memberships.accepted.where(role: PartnerMembership::MANAGER_ROLES).count
      end

      test "concurrent volunteer-manager departures preserve an approved open need" do
        # A legacy profile without an owner tests the distinct open-need rule.
        @memberships.each { |membership| membership.update_columns(role: "volunteer_coordinator") }
        ContributionNeed.create!(
          organization: @organization, partner_profile: @profile, author: @users.first,
          need_type: "equipment", title: "Tools for action",
          description: "Equipment for the approved community action",
          quantity: 2, unit: "pieces", review_status: "approved",
          fulfillment_status: "open", reviewed_at: Time.current, published_at: Time.current
        )

        results = concurrent_changes do |membership|
          PartnerMembership.find(membership.id).leave!
          :left
        end

        assert_equal [:left, :retained], results.sort
        assert_equal 1, @profile.memberships.accepted.where(role: PartnerMembership::VOLUNTEER_ROLES).count
      end

      test "concurrent manager departures preserve one accepted manager" do
        results = concurrent_changes do |membership|
          PartnerMembership.find(membership.id).leave!
          :left
        end

        assert_equal [:left, :retained], results.sort
        assert_equal 1, @profile.memberships.accepted.where(role: PartnerMembership::MANAGER_ROLES).count
      end

      test "direct destruction cannot remove the last accepted manager" do
        @memberships.first.update!(role: "member")
        last_manager = @memberships.last

        assert_no_difference -> { PartnerMembership.where(partner_profile: @profile).count } do
          assert_equal false, last_manager.destroy
          assert last_manager.errors[:base].present?
          error = assert_raises(ActiveRecord::RecordNotDestroyed) { last_manager.destroy! }
          assert_equal last_manager, error.record
        end
        assert_equal "manager", last_manager.reload.role
        assert last_manager.accepted?
      end

      test "direct destruction cannot remove the last volunteer manager for an approved open need" do
        # Legacy data can have an approved need without an owner or manager.
        @memberships.first.update_columns(role: "volunteer_coordinator")
        @memberships.last.update_columns(role: "member")
        ContributionNeed.create!(
          organization: @organization, partner_profile: @profile, author: @users.first,
          need_type: "equipment", title: "Tools for action",
          description: "Equipment for the approved community action",
          quantity: 2, unit: "pieces", review_status: "approved",
          fulfillment_status: "open", reviewed_at: Time.current, published_at: Time.current
        )

        assert_no_difference -> { PartnerMembership.where(partner_profile: @profile).count } do
          assert_raises(ActiveRecord::RecordNotDestroyed) { @memberships.first.destroy! }
        end
        assert @memberships.first.reload.accepted?
      end

      test "concurrent direct destructions retain one accepted manager" do
        results = concurrent_changes do |membership|
          PartnerMembership.find(membership.id).destroy!
          :destroyed
        end

        assert_equal [:destroyed, :retained], results.sort
        assert_equal 1, @profile.memberships.accepted.where(role: PartnerMembership::MANAGER_ROLES).count
      end

      test "profile destruction still cascades through its memberships" do
        assert_difference -> { PartnerMembership.where(partner_profile: @profile).count }, -2 do
          @profile.destroy!
        end
        assert_not PartnerProfile.exists?(@profile.id)
      end

      private

      def concurrent_changes(&action)
        ready = Queue.new
        start = Queue.new
        threads = @memberships.map do |membership|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do |connection|
              connection.execute("SET lock_timeout = '5s'")
              ready << connection.select_value("SELECT pg_backend_pid()")
              start.pop
              action.call(membership)
            rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed
              :retained
            ensure
              connection.execute("RESET lock_timeout") if connection
            end
          end
        end

        Timeout.timeout(15) do
          pids = threads.map { ready.pop }
          assert_equal 2, pids.uniq.size
          threads.size.times { start << true }
          threads.map(&:value)
        end
      ensure
        threads&.each { |thread| thread.kill if thread.alive? }
        threads&.each(&:join)
      end
    end
  end
end
