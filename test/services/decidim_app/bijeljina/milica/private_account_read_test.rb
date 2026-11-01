# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class PrivateAccountReadTest < ActiveSupport::TestCase
        Dialogue = Decidim::Bih::Concierge::Dialogue
        Goodwill = Decidim::Bih::Goodwill

        setup do
          @organization = create_organization
          @user = create(:user, :confirmed, organization: @organization, name: "Private synthetic citizen")
          @reader = PrivateAccountRead.new(organization: @organization)
        end

        test "reads only the current tenant actor and never creates a missing wallet" do
          assert_no_difference("Goodwill::Account.count") do
            result = read("balance")
            assert_equal "ok", result.status
            assert_equal I18n.t("decidim.bih.concierge.goodwill.none", locale: :sr,
                                                                       url: Decidim::Bih::Engine.routes.url_helpers.wallet_path), result.text
          end
          result = read("identity")
          assert_includes result.text, @user.name
          assert_not_includes result.inspect, @user.name
          assert_not_includes result.to_s, @user.name
        end

        test "anonymous and stale or foreign actors never expose identity" do
          foreign = create(:user, :confirmed, organization: create_organization, name: "Foreign secret")
          [nil, foreign.id, @user.id + 1_000_000].each do |actor|
            result = @reader.call(kind: "identity", context: context(actor:))
            assert_equal "not_authorized", result.status
            assert_not_includes result.text, @user.name
            assert_not_includes result.text, foreign.name
          end
          wrong = PrivateAccountRead.new(organization: @organization, actor_lookup: ->(_id) { foreign })
          assert_equal "not_authorized", wrong.call(kind: "identity", context: context).status
        end

        test "blocked deleted inactive and group identities fail closed" do
          [:blocked?, :deleted?, :group?].each do |predicate|
            @user.stub(predicate, true) do
              reader = PrivateAccountRead.new(organization: @organization, actor_lookup: ->(_id) { @user })
              assert_equal "not_authorized", reader.call(kind: "identity", context: context).status
            end
          end
          @user.stub(:active_for_authentication?, false) do
            reader = PrivateAccountRead.new(organization: @organization, actor_lookup: ->(_id) { @user })
            assert_equal "not_authorized", reader.call(kind: "identity", context: context).status
          end
        end

        test "foreign tenant invalid kind and expired budget reject before reading actor" do
          reader = PrivateAccountRead.new(organization: @organization, actor_lookup: ->(_id) { flunk "Actor read before authorization" })
          [context(organization_id: @organization.id + 1), context(deadline: expired_budget)].each do |scope|
            assert_raises(Dialogue::Contracts::Invalid) { reader.call(kind: "identity", context: scope) }
          end
          assert_raises(Dialogue::Contracts::Invalid) { reader.call(kind: "all_users", context: context) }
          assert_raises(Dialogue::Contracts::Invalid) { reader.call(kind: "identity", context: {}) }
        end

        test "affordability excludes expired and automatic rewards but not exhausted stock" do
          reward(key: "expired", expires_at: 1.day.ago)
          reward(key: "threshold", auto_issue_at_threshold: true, deducts_points: false)
          reward(key: "shirt", stock: 1)
          %w(expired threshold missing).each do |key|
            result = read("affordability", reward_key: key)
            assert_equal "unavailable", result.status
            assert_equal I18n.t("decidim.bih.dialogue.context_unavailable", locale: :sr), result.text
          end
          # Stock is a redemption concern. A read must compare the price even
          # when the only unit has been fulfilled, without promising availability.
          transaction = Goodwill::Ledger.new.award(@user, 10, reason: "proposal")
          Goodwill::RewardFulfillment.create!(organization: @organization, user: @user, reward_key: "shirt", status: "fulfilled", cost: 50,
                                              ledger_transaction: transaction)
          result = read("affordability", reward_key: "shirt")
          assert_includes result.text, "50"
          assert_includes result.text, "Synthetic shirt"
          assert_no_difference("Goodwill::RewardFulfillment.count") { read("affordability", reward_key: "shirt") }
        end

        test "invitation uses recognition score and keeps verification guidance without issuing" do
          reward(key: Goodwill::LaunchInvitation::REWARD_KEY, cost: 20, auto_issue_at_threshold: true, deducts_points: false)
          assert_no_difference("Goodwill::RewardFulfillment.count") do
            result = read("invitation")
            assert_includes result.text, I18n.t("decidim.bih.dialogue.handoff_verify", locale: :sr,
                                                                                       url: Decidim::Bih::Engine.routes.url_helpers.verification_explainer_path)
          end
        end

        test "invitation threshold uses contribution score rather than spendable balance" do
          reward(key: Goodwill::LaunchInvitation::REWARD_KEY, cost: 20, auto_issue_at_threshold: true, deducts_points: false)
          ledger = Data.define(:balance, :contribution_score).new(0, 70)
          @reader.stub(:account, ledger) do
            result = read("invitation")
            expected = I18n.t("decidim.bih.concierge.account_state.invitation.reached", locale: :sr,
                                                                                        threshold: I18n.t("decidim.bih.concierge.goodwill.earning.points", count: 20, locale: :sr),
                                                                                        score: I18n.t("decidim.bih.concierge.goodwill.earning.points", count: 70, locale: :sr),
                                                                                        hub_url: Decidim::Bih.public_path("zajednistvo"))
            assert_equal expected, result.text
          end
        end

        test "provider report attribution alone does not authorize private account reads" do
          scope = ChannelConversationContext.call(organization: @organization, channel: "whatsapp",
                                                  sender: "38765123456", user: @user, private_reads: false)
          result = @reader.call(kind: "identity", context: scope.with(deadline: Dialogue::TurnBudget.new(timeout: 5)))
          assert_equal "not_authorized", result.status
          assert_not_includes result.text, @user.name
        end

        test "expired invitation cannot promise new issuance but an existing record remains readable" do
          reward(key: Goodwill::LaunchInvitation::REWARD_KEY, auto_issue_at_threshold: true,
                 deducts_points: false, expires_at: 1.minute.ago)
          assert_no_difference("Goodwill::RewardFulfillment.count") do
            result = read("invitation")
            assert_equal I18n.t("decidim.bih.concierge.account_state.invitation.unavailable", locale: :sr,
                                                                                              hub_url: Decidim::Bih.public_path("zajednistvo")), result.text
          end
          Goodwill::RewardFulfillment.create!(organization: @organization, user: @user,
                                              reward_key: Goodwill::LaunchInvitation::REWARD_KEY,
                                              auto_issued: true, status: "reserved", cost: 50, entry_code: "OWN-RECORD")
          assert_includes read("invitation").text, "OWN-RECORD"
        end

        test "foreign profile MZ falls back to the assigned areas valid MZ" do
          area_type = Data.define(:decidim_organization_id, :kind, :translated_name, :primary_mz)
          valid = area_type.new(@organization.id, "mz", "Own MZ", nil)
          foreign = area_type.new(@organization.id + 1, "mz", "Foreign MZ secret", nil)
          assigned = area_type.new(@organization.id, "komsiluk", "Own komsiluk", valid)
          profile = Data.define(:komsiluk, :mz).new(assigned, foreign)
          Decidim::Bih::CitizenProfile.stub(:find_by, profile) do
            result = read("area")
            assert_includes result.text, valid.translated_name
            assert_not_includes result.text, foreign.translated_name
          end
        end

        test "existing invitation wins over canceled row and another user's code stays private" do
          own = Goodwill::RewardFulfillment.create!(organization: @organization, user: @user,
                                                    reward_key: Goodwill::LaunchInvitation::REWARD_KEY, auto_issued: true, status: "reserved", cost: 50, entry_code: "OWN-CODE")
          other = create(:user, :confirmed, organization: @organization)
          Goodwill::RewardFulfillment.create!(organization: @organization, user: other,
                                              reward_key: Goodwill::LaunchInvitation::REWARD_KEY, auto_issued: true, status: "reserved", cost: 50, entry_code: "FOREIGN-CODE")
          transaction = Goodwill::Ledger.new.award(@user, 10, reason: "proposal")
          Goodwill::RewardFulfillment.create!(organization: @organization, user: @user, ledger_transaction: transaction,
                                              reward_key: Goodwill::LaunchInvitation::REWARD_KEY, status: "canceled", cost: 50)
          result = read("invitation")
          assert_includes result.text, own.entry_code
          assert_not_includes result.text, "FOREIGN-CODE"
        end

        private

        def expired_budget
          clock = 0
          budget = Dialogue::TurnBudget.new(timeout: 1, clock: -> { clock })
          clock = 2
          budget
        end

        def read(kind, **)
          @reader.call(kind:, context: context, **)
        end

        def context(actor: @user.id, organization_id: @organization.id, deadline: Dialogue::TurnBudget.new(timeout: 5))
          Dialogue::Contracts::TrustedContext.new(organization_id:, actor_id: actor, conversation_key: "a" * 64,
                                                  account_state: actor ? "registered" : "anonymous", capabilities: %w(public_reads own_report_reads), deadline:)
        end

        def reward(**attributes)
          Goodwill::Reward.create!(organization: @organization, active: true, cost: 50,
                                   title: { "sr" => "Synthetic shirt" }, **attributes)
        end
      end
    end
  end
end
