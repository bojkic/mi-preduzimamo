# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # R13 — matched-giving request: a mutable status record (NOT the ledger)
      # capturing intent to match received goodwill with a manual micro-grant.
      class MatchRequestTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                        extended_data: { "group" => true })
        end

        def build_request(points: 100, status: "pending")
          MatchRequest.create!(
            organization: @organization, owner: @group, points:,
            status:, created_by: @admin
          )
        end

        test "requires positive points" do
          assert_raises(ActiveRecord::RecordInvalid) { build_request(points: 0) }
        end

        test "validates status inclusion" do
          req = build_request
          req.status = "bogus"
          assert_not req.valid?
        end

        test "decide! approves a pending request and stamps the decider" do
          req = build_request
          assert req.decide!("approved", by: @admin)
          assert_equal "approved", req.reload.status
          assert_equal @admin.id, req.decided_by_id
          assert_not_nil req.decided_at
        end

        test "decide! is a no-op once decided (no re-decide)" do
          req = build_request
          assert req.decide!("approved", by: @admin)
          assert_not req.decide!("rejected", by: @admin)
          assert_equal "approved", req.reload.status
        end

        test "decide! rejects invalid decisions" do
          req = build_request
          assert_not req.decide!("maybe", by: @admin)
          assert_equal "pending", req.reload.status
        end

        test "owner must belong to the request organization" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          req = MatchRequest.new(
            organization: @organization,
            owner: outsider,
            points: 100,
            status: "pending",
            created_by: @admin
          )

          assert_not req.valid?
          assert req.errors[:owner].any?
        end

        test "record_payout! marks an approved unpaid request as paid" do
          req = build_request(status: "approved")

          assert req.record_payout!(
            by: @admin,
            amount_minor_units: 12_500,
            currency: "bam",
            paid_on: Date.new(2026, 6, 17),
            reference: "BANK-2026-42",
            note: "June grant"
          )

          req.reload
          assert_equal "paid", req.payout_status
          assert_equal 12_500, req.payout_amount_minor_units
          assert_equal "BAM", req.payout_currency
          assert_equal Date.new(2026, 6, 17), req.payout_paid_on
          assert_equal "BANK-2026-42", req.payout_reference
          assert_equal "June grant", req.payout_note
          assert_equal @admin.id, req.payout_recorded_by_id
          assert req.payout_recorded_at.present?
          assert_equal 12_500, req.metadata.fetch("payout_events").last.fetch("amount_minor_units")
        end

        test "record_payout! is approved-only and one-time" do
          pending = build_request
          assert_not pending.record_payout!(
            by: @admin,
            amount_minor_units: 12_500,
            reference: "BANK-2026-42"
          )
          assert_equal "unpaid", pending.reload.payout_status

          approved = build_request(status: "approved")
          assert approved.record_payout!(
            by: @admin,
            amount_minor_units: 12_500,
            reference: "BANK-2026-42"
          )
          assert_not approved.record_payout!(
            by: @admin,
            amount_minor_units: 13_500,
            reference: "BANK-2026-43"
          )
          assert_equal "BANK-2026-42", approved.reload.payout_reference
        end

        test "paid payout requires amount reference and paid date" do
          req = build_request(status: "approved")
          req.payout_status = "paid"

          assert_not req.valid?
          assert req.errors[:payout_amount_minor_units].any?
          assert req.errors[:payout_reference].any?
          assert req.errors[:payout_paid_on].any?
        end

        test "a stale decision cannot overwrite an already approved request" do
          req = build_request
          stale = MatchRequest.find(req.id)
          assert req.decide!("approved", by: @admin)
          assert_not stale.decide!("rejected", by: @admin)
          assert_equal "approved", req.reload.status
        end

        test "a stale payout cannot replace the first payment evidence" do
          req = build_request(status: "approved")
          stale = MatchRequest.find(req.id)
          assert req.record_payout!(by: @admin, reference: "FIRST", amount_minor_units: 100)
          assert_not stale.record_payout!(by: @admin, reference: "SECOND", amount_minor_units: 200)
          assert_equal "FIRST", req.reload.payout_reference
          assert_equal 1, req.metadata.fetch("payout_events").size
        end

        test "an audit failure rolls back a decision and payment" do
          req = build_request
          assert_raises(RuntimeError) { req.decide!("approved", by: @admin) { raise "audit failed" } }
          assert_equal "pending", req.reload.status
          assert req.decide!("approved", by: @admin)
          assert_raises(RuntimeError) do
            req.record_payout!(by: @admin, reference: "FIRST", amount_minor_units: 100) { raise "audit failed" }
          end
          assert_equal "unpaid", req.reload.payout_status
          assert_empty Array(req.metadata["payout_events"])
        end

        test "payment amount must be an exact positive integer" do
          req = build_request(status: "approved")
          %w(12.5 12oops -10 0).each do |amount|
            assert_not req.record_payout!(by: @admin, reference: "BANK", amount_minor_units: amount)
            assert_equal "unpaid", req.reload.payout_status
          end
        end

        test "pending scope returns only undecided requests" do
          pending = build_request
          decided = build_request
          decided.decide!("rejected", by: @admin)

          assert_equal [pending.id], MatchRequest.pending.pluck(:id)
        end
      end
    end
  end
end
