# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    class FoundationStatusOverrideTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "one row per organization with a known open status and a review window that ends after it starts" do
        override = build_override(current_open_status: "maybe")
        assert_not override.valid?
        assert_includes override.errors.attribute_names, :current_open_status

        override.current_open_status = "open"
        override.review_expires_on = override.reviewed_on
        assert_not override.valid?
        assert_includes override.errors.attribute_names, :review_expires_on

        override.reviewed_on = Date.current + 1
        override.review_expires_on = Date.current + 30
        assert_not override.valid?
        assert_includes override.errors.attribute_names, :reviewed_on

        override.reviewed_on = Date.current
        assert_predicate override, :valid?
        override.save!

        assert_not_predicate build_override, :valid?
      end

      test "for_organization returns the single draft row with the shipped defaults" do
        override = FoundationStatusOverride.for_organization(@organization)

        assert_predicate override, :new_record?
        assert_equal "unverified", override.current_open_status
        assert_predicate override, :draft?
        assert_nil FoundationStatusOverride.approved_for(@organization)
      end

      test "approve and rollback move the row between draft, approved and rolled_back with an audit trail" do
        override = build_override
        override.save!

        assert_nil FoundationStatusOverride.approved_for(@organization)
        assert_equal :not_authorized, override.approve!(actor: @citizen)

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "foundation_status_approved").count }, 1 do
          assert_equal :approved, override.approve!(actor: @admin)
        end
        assert_equal override, FoundationStatusOverride.approved_for(@organization)
        assert_equal @admin.id, override.reload.approved_by_id

        assert_equal :not_authorized, override.rollback!(actor: @citizen)
        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "foundation_status_rolled_back").count }, 1 do
          assert_equal :rolled_back, override.rollback!(actor: @admin)
        end
        assert_nil FoundationStatusOverride.approved_for(@organization)
        assert_equal :not_approved, override.rollback!(actor: @admin)
      end

      test "staging a change to an approved row drops it back to draft" do
        override = build_override
        override.save!
        override.approve!(actor: @admin)

        override.stage(current_open_status: "open")
        assert_predicate override, :approved?, "an unchanged value keeps approval"

        override.stage(current_open_status: "closed")
        override.save!
        assert_predicate override, :draft?
        assert_nil FoundationStatusOverride.approved_for(@organization)
      end

      private

      def build_override(**attributes)
        FoundationStatusOverride.new(
          {
            organization: @organization,
            current_open_status: "open",
            reviewed_on: Date.current,
            review_expires_on: Date.current + 90
          }.merge(attributes)
        )
      end
    end
  end
end
