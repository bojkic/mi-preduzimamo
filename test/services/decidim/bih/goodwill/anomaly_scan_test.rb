# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # R10 — read-only fraud/anomaly monitoring over the ledger (no IP/device
      # data). Advisory flags only; the scan never writes and never punishes.
      class AnomalyScanTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @alice = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "a clean ledger produces no flags" do
          @ledger.award(@alice, 20, reason: "proposal")
          assert_empty AnomalyScan.new(@organization).flags
        end

        test "abnormal daily earn velocity is flagged" do
          # 35 distinct earn awards today (> EARN_VELOCITY_PER_DAY = 30).
          35.times { |i| @ledger.award(@alice, 1, reason: "engagement", idempotency_key: "e#{i}") }

          flags = AnomalyScan.new(@organization).flags
          velocity = flags.select { |f| f[:type] == "earn_velocity" }
          assert_equal 1, velocity.size
          assert_equal @alice.id, velocity.first[:user].id
        end

        test "self-dealing gift<->regrant loop with an administered group is flagged" do
          skip "legacy group memberships table unavailable" unless GroupMembership.available?

          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          GroupMembership.create!(decidim_user_id: @alice.id, decidim_user_group_id: group.id, role: "admin")

          @ledger.award(@alice, 100, reason: "volunteer_hour")
          @ledger.transfer(from_owner: @alice, to_owner: group, amount: 60, kind: "gift")
          @ledger.transfer(from_owner: group, to_owner: @alice, amount: 40, kind: "regrant")

          flags = AnomalyScan.new(@organization).flags
          loop_flag = flags.select { |f| f[:type] == "self_dealing" }
          assert_equal 1, loop_flag.size
          assert_equal "low", loop_flag.first[:severity], "a review flag is not proof of fraud"
          assert_equal @alice.id, loop_flag.first[:user].id
        end

        test "a one-directional gift is NOT flagged as self-dealing" do
          skip "legacy group memberships table unavailable" unless GroupMembership.available?

          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          GroupMembership.create!(decidim_user_id: @alice.id, decidim_user_group_id: group.id, role: "admin")

          @ledger.award(@alice, 100, reason: "volunteer_hour")
          @ledger.transfer(from_owner: @alice, to_owner: group, amount: 60, kind: "gift")
          # No return regrant => not a loop.

          flags = AnomalyScan.new(@organization).flags
          assert_empty(flags.select { |f| f[:type] == "self_dealing" })
        end

        test "a referral cluster from one referrer in a day is flagged" do
          10.times do
            invitee = FactoryBot.create(:user, :confirmed, organization: @organization)
            Referral.create!(
              organization: @organization, referrer: @alice, invitee:,
              status: "rewarded", rewarded_at: Time.current
            )
          end

          flags = AnomalyScan.new(@organization).flags
          cluster = flags.select { |f| f[:type] == "referral_cluster" }
          assert_equal 1, cluster.size
          assert_equal @alice.id, cluster.first[:user].id
        end

        test "the scan is read-only (writes no ledger rows)" do
          35.times { |i| @ledger.award(@alice, 1, reason: "engagement", idempotency_key: "e#{i}") }
          before = Transaction.count
          AnomalyScan.new(@organization).flags
          assert_equal before, Transaction.count
        end
      end
    end
  end
end
