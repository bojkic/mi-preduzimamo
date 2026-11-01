# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Characterization test for Transaction#credited_amount — the extracted
      # summation that ReportIntake#awarded_points previously inlined as
      #   txn.entries.select { |e| e.amount.positive? }.sum(&:amount)
      #
      # The result must equal that prior expression exactly for any transaction.
      class TransactionCreditedAmountTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        # The exact expression that used to live in ReportIntake#awarded_points.
        def legacy_sum(txn)
          txn.entries.select { |e| e.amount.positive? }.sum(&:amount)
        end

        test "credited_amount sums the positive entries of an earn" do
          txn = @ledger.award(@user, 20, reason: "report")

          assert_equal 20, txn.credited_amount
          assert_equal legacy_sum(txn), txn.credited_amount
        end

        test "credited_amount equals the legacy summation for an arbitrary balanced post" do
          system_account = @ledger.system_account_for(@organization)
          user_account = @ledger.account_for(@user)
          txn = @ledger.post(
            organization: @organization,
            kind: "earn",
            entries: [
              { account: system_account, amount: -7 },
              { account: user_account, amount: 7 }
            ]
          )

          assert_equal 7, txn.credited_amount
          assert_equal legacy_sum(txn), txn.credited_amount
        end

        test "credited_amount is 0 when there are no positive entries" do
          # A reversal of an earn flips signs: the user account entry becomes
          # negative, the system account positive — credited_amount still reads
          # the positive side, matching the legacy summation.
          earn = @ledger.award(@user, 12, reason: "report")
          reversal = @ledger.reverse(earn)

          assert_equal legacy_sum(reversal), reversal.credited_amount
        end
      end
    end
  end
end
