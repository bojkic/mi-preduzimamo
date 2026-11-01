# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      class OrganizationSpendingRequestTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @source_group = group("Udruženje izvor")
          @target_group = group("Udruženje cilj")
          @source_profile = profile("Udruženje izvor", "udruzenje-izvor", @source_group)
          @target_profile = profile("Udruženje cilj", "udruzenje-cilj", @target_group)
          @admin = FactoryBot.create(:user, :confirmed, organization: @organization)
          @operator = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @source_profile.memberships.create!(
            organization: @organization,
            user: @admin,
            role: "finance_contact",
            status: "accepted",
            accepted_at: Time.current
          )
          Ledger.new.award(@source_group, 500, reason: "gift")
        end

        test "finance admin creates inter-org support request and operator approval transfers points" do
          request = create_request!(
            request_type: "inter_org_support",
            target_partner_profile_id: @target_profile.id,
            points: 120,
            category: "collaboration"
          )

          assert request.pending?
          assert_equal @target_profile, request.target_partner_profile

          state = decide_request(request, "approved")

          assert_equal :ok, state
          assert request.reload.approved?
          ledger = Ledger.new
          assert_equal 380, ledger.account_for(@source_group).balance
          assert_equal 120, ledger.account_for(@target_group).balance
          assert_equal "gift", Transaction.find(request.metadata["ledger_transaction_id"]).kind
        end

        test "reward sponsorship approval spends points and creates sponsored reward inventory" do
          request = create_request!(
            request_type: "reward_sponsorship",
            points: 150,
            category: "voucher",
            reward_title: "Kupon za sadnice",
            reward_description: "Preuzimanje kod operatora.",
            reward_stock: 3,
            reward_cost: 20
          )

          state = decide_request(request, "approved")

          assert_equal :ok, state
          assert request.reload.approved?
          assert_equal 350, Ledger.new.account_for(@source_group).balance
          reward = Reward.find(request.metadata["reward_id"])
          assert_equal @source_profile, reward.sponsor_partner_profile
          assert_equal "Kupon za sadnice", reward.title["sr"]
          assert_equal 20, reward.cost
          assert_equal 3, reward.stock
          assert reward.active?
        end

        test "insufficient source wallet blocks request creation" do
          state = nil
          assert_no_difference -> { OrganizationSpendingRequest.count } do
            CreateOrganizationSpendingRequest.call(
              @admin,
              @source_profile.id,
              request_type: "inter_org_support",
              target_partner_profile_id: @target_profile.id,
              points: 999,
              category: "collaboration"
            ) do
              on(:ok) { state = :ok }
              on(:insufficient) { state = :insufficient }
              on(:forbidden) { state = :forbidden }
              on(:invalid) { state = :invalid }
            end
          end

          assert_equal :insufficient, state
        end

        private

        def create_request!(attributes)
          request = nil
          state = nil
          CreateOrganizationSpendingRequest.call(@admin, @source_profile.id, attributes) do
            on(:ok) do |record|
              state = :ok
              request = record
            end
            on(:insufficient) { state = :insufficient }
            on(:forbidden) { state = :forbidden }
            on(:invalid) { state = :invalid }
          end
          assert_equal :ok, state
          request
        end

        def decide_request(request, decision)
          state = nil
          DecideOrganizationSpendingRequest.call(request, decision:, decider: @operator) do
            on(:ok) { state = :ok }
            on(:insufficient) { state = :insufficient }
            on(:invalid) { state = :invalid }
          end
          state
        end

        def group(name)
          FactoryBot.create(:user, :confirmed, organization: @organization,
                                               name:,
                                               extended_data: { "group" => true })
        end

        def profile(name, slug, group)
          Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            display_name: name,
            slug:,
            kind: "association",
            verification_status: "verified",
            legacy_user_group: group,
            verified_at: Time.current
          )
        end
      end
    end
  end
end
