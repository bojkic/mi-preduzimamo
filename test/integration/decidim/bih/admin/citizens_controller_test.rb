# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 11, Items 3 + 4 — citizen lookup, account summary, manual award,
      # plus the CSRF regression tests (Round 6 convention).
      class CitizensControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @citizen.update!(name: "Ana Kovač", nickname: "ana_kovac")
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        # --- index (search) ---

        test "admin can access the citizen search page" do
          sign_in @admin
          get "/admin/bih/citizens"
          assert_response :success
        end

        test "non-admin is denied access" do
          sign_in @citizen
          get "/admin/bih/citizens"
          assert_response :redirect
        end

        test "search by name returns the citizen" do
          sign_in @admin
          get "/admin/bih/citizens", params: { q: "Ana" }
          assert_response :success
          assert_includes response.body, "Ana Kovač"
        end

        test "search by nickname returns the citizen" do
          sign_in @admin
          get "/admin/bih/citizens", params: { q: "ana_kovac" }
          assert_response :success
          assert_includes response.body, "Ana Kovač"
        end

        test "search does not return citizens from another organization" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          outsider.update!(name: "Ana Kovač Outsider")

          sign_in @admin
          get "/admin/bih/citizens", params: { q: "Outsider" }
          assert_response :success
          # Outsider's profile link must not appear (cross-org isolation)
          assert_not_includes response.body, "/admin/bih/citizens/#{outsider.id}"
        end

        test "empty query shows no results table" do
          sign_in @admin
          get "/admin/bih/citizens"
          assert_response :success
          # No results table when no query — citizen profile link must not appear
          assert_not_includes response.body, "/admin/bih/citizens/#{@citizen.id}"
        end

        # --- show ---

        test "admin can view citizen account summary" do
          @ledger.award(@citizen, 200, reason: "proposal")
          sign_in @admin
          get "/admin/bih/citizens/#{@citizen.id}"

          assert_response :success
          assert_includes response.body, "200"
          assert_includes response.body, "Ana Kovač"
        end

        test "citizen summary page does not load for a cross-org ID" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)

          sign_in @admin
          get "/admin/bih/citizens/#{outsider.id}"
          assert_response :redirect
        end

        # R3 (scoped-finder concern): a GET show of a non-existent citizen must
        # halt on the finder's redirect — never fall through to render the show
        # template (no 500 / DoubleRender).
        test "show of a non-existent citizen redirects to index, not 500" do
          sign_in @admin
          get "/admin/bih/citizens/999999"
          assert_response :redirect
          assert_redirected_to "/admin/bih/citizens"
        end

        # R3: a GET show of another org's citizen redirects cleanly (org-scoped
        # finder => nil => redirect), not a 500.
        test "show of another organization's citizen redirects to index, not 500" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)

          sign_in @admin
          get "/admin/bih/citizens/#{outsider.id}"
          assert_response :redirect
          assert_redirected_to "/admin/bih/citizens"
        end

        # --- manual award ---

        test "admin can award points to a citizen" do
          sign_in @admin
          assert_difference -> { @ledger.account_for(@citizen).contribution_score }, 50 do
            post "/admin/bih/citizens/#{@citizen.id}/award",
                 params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 50, reason: "Test aktivnost" }
          end
          assert_response :redirect
        end

        test "award is capped at 500" do
          sign_in @admin
          assert_no_difference -> { @ledger.account_for(@citizen).contribution_score } do
            post "/admin/bih/citizens/#{@citizen.id}/award",
                 params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 501, reason: "Previše" }
          end
          assert_response :redirect
        end

        test "award requires a reason" do
          sign_in @admin
          assert_no_difference -> { @ledger.account_for(@citizen).contribution_score } do
            post "/admin/bih/citizens/#{@citizen.id}/award",
                 params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 50, reason: "" }
          end
          assert_response :redirect
        end

        test "award is idempotent within the same minute" do
          sign_in @admin
          post "/admin/bih/citizens/#{@citizen.id}/award",
               params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 50, reason: "Test aktivnost" }

          # Same idempotency key (same admin, same citizen, same minute)
          initial_balance = @ledger.account_for(@citizen).contribution_score
          post "/admin/bih/citizens/#{@citizen.id}/award",
               params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 50, reason: "Test aktivnost" }

          assert_equal initial_balance, @ledger.account_for(@citizen).contribution_score
        end

        test "two different same-minute awards to the same citizen both post" do
          sign_in @admin
          # First award. Then a second, genuinely DIFFERENT award (different
          # amount AND reason) within the same minute must NOT collide on the
          # idempotency key — both are real, unrecorded-otherwise contributions.
          assert_difference -> { @ledger.account_for(@citizen).contribution_score }, 50 + 30 do
            post "/admin/bih/citizens/#{@citizen.id}/award",
                 params: { request_key: SecureRandom.uuid, amount: 50, reason: "Prva aktivnost" }
            post "/admin/bih/citizens/#{@citizen.id}/award",
                 params: { request_key: SecureRandom.uuid, amount: 30, reason: "Druga aktivnost" }
          end
          assert_response :redirect
        end

        test "admin cannot award points to a cross-org citizen" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)

          sign_in @admin
          assert_no_difference -> { @ledger.account_for(outsider).contribution_score } do
            post "/admin/bih/citizens/#{outsider.id}/award",
                 params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 50, reason: "Cross-org attack" }
          end
          assert_response :redirect
        end

        test "award CSRF regression: missing token returns 422, no ledger change" do
          sign_in @admin

          with_forgery_protection do
            assert_no_difference -> { @ledger.account_for(@citizen).contribution_score } do
              post "/admin/bih/citizens/#{@citizen.id}/award",
                   params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 50, reason: "Test" }
            end
          end

          assert_response :unprocessable_entity
        end

        test "non-admin cannot award points" do
          sign_in @citizen
          assert_no_difference -> { @ledger.account_for(@citizen).contribution_score } do
            post "/admin/bih/citizens/#{@citizen.id}/award",
                 params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 50, reason: "Test" }
          end
          assert_response :redirect
        end

        # Fix 2: group users must not appear in search or be awardable
        test "search does not return group users" do
          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true, "extra" => "value" })
          group.update!(name: "Ana Kovač Group Org")

          sign_in @admin
          get "/admin/bih/citizens", params: { q: "Ana Kovač Group" }
          assert_response :success
          assert_not_includes response.body, "/admin/bih/citizens/#{group.id}"
        end

        test "group user cannot be shown or awarded" do
          group = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                       extended_data: { "group" => true })
          group.update!(name: "Some Group")

          sign_in @admin
          get "/admin/bih/citizens/#{group.id}"
          assert_response :redirect

          assert_no_difference -> { @ledger.account_for(group).contribution_score } do
            post "/admin/bih/citizens/#{group.id}/award",
                 params: { request_key: (@award_request_key ||= SecureRandom.uuid), amount: 50, reason: "Pogrešan cilj" }
          end
          assert_response :redirect
        end

        # Fix 8e: show page does not crash when citizen has no account yet
        test "citizen show page renders even without a ledger account" do
          fresh = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in @admin
          get "/admin/bih/citizens/#{fresh.id}"
          assert_response :success
        end

        # --- Round 25 / W4.7: identity panel (Viber linkage + komšiluk/MZ) ---

        test "show page renders the Viber linkage status when one exists" do
          Decidim::Bih::Viber::Linkage.create!(
            organization: @organization,
            decidim_user_id: @citizen.id,
            viber_sender: "viber-sender-abc",
            phone: "38765123456",
            verified_at: Time.current
          )

          sign_in @admin
          get "/admin/bih/citizens/#{@citizen.id}"
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.admin.citizens.show.identity_title")
          assert_includes response.body, I18n.t("decidim.bih.admin.citizens.show.viber_linked")
        end

        test "show page never prints the raw phone of a linkage" do
          Decidim::Bih::Viber::Linkage.create!(
            organization: @organization,
            decidim_user_id: @citizen.id,
            viber_sender: "viber-sender-abc",
            phone: "38765123456",
            verified_at: Time.current
          )

          sign_in @admin
          get "/admin/bih/citizens/#{@citizen.id}"
          assert_response :success
          assert_not_includes response.body, "38765123456"
          assert_not_includes response.body, "viber-sender-abc"
        end

        test "show page renders the komšiluk + MZ assignment when present" do
          mz = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "mz",
            name: { "sr" => "MZ Centar" }, slug: "mz-centar"
          )
          komsiluk = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk",
            name: { "sr" => "Komšiluk Sjever" }, slug: "komsiluk-sjever"
          )
          profile = Decidim::Bih::CitizenProfile.for_user(@citizen, organization: @organization)
          profile.update!(komsiluk:, mz:, mz_id: mz.id, source: "dropdown", assigned_at: Time.current)

          sign_in @admin
          get "/admin/bih/citizens/#{@citizen.id}"
          assert_response :success
          assert_includes response.body, "Komšiluk Sjever"
          assert_includes response.body, "MZ Centar"
        end

        test "show page renders the identity panel even without linkage or komšiluk" do
          sign_in @admin
          get "/admin/bih/citizens/#{@citizen.id}"
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.admin.citizens.show.identity_title")
          assert_includes response.body, I18n.t("decidim.bih.admin.citizens.show.viber_not_linked")
        end

        test "unlink Viber clears the linkage decidim_user_id" do
          linkage = Decidim::Bih::Viber::Linkage.create!(
            organization: @organization,
            decidim_user_id: @citizen.id,
            viber_sender: "viber-sender-abc",
            phone: "38765123456",
            verified_at: Time.current
          )

          sign_in @admin
          post "/admin/bih/citizens/#{@citizen.id}/unlink-viber"
          assert_response :redirect

          assert_nil linkage.reload.decidim_user_id
        end

        test "unlink Viber CSRF regression: missing token returns 422, linkage intact" do
          linkage = Decidim::Bih::Viber::Linkage.create!(
            organization: @organization,
            decidim_user_id: @citizen.id,
            viber_sender: "viber-sender-abc",
            phone: "38765123456",
            verified_at: Time.current
          )

          sign_in @admin
          with_forgery_protection do
            post "/admin/bih/citizens/#{@citizen.id}/unlink-viber"
          end
          assert_response :unprocessable_entity
          assert_equal @citizen.id, linkage.reload.decidim_user_id
        end

        test "non-admin cannot unlink Viber" do
          linkage = Decidim::Bih::Viber::Linkage.create!(
            organization: @organization,
            decidim_user_id: @citizen.id,
            viber_sender: "viber-sender-abc",
            phone: "38765123456",
            verified_at: Time.current
          )

          sign_in @citizen
          post "/admin/bih/citizens/#{@citizen.id}/unlink-viber"
          assert_response :redirect
          assert_equal @citizen.id, linkage.reload.decidim_user_id
        end

        test "admin cannot unlink a cross-org citizen's Viber" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          linkage = Decidim::Bih::Viber::Linkage.create!(
            organization: other,
            decidim_user_id: outsider.id,
            viber_sender: "viber-sender-xyz",
            phone: "38765999999",
            verified_at: Time.current
          )

          sign_in @admin
          post "/admin/bih/citizens/#{outsider.id}/unlink-viber"
          assert_response :redirect
          assert_equal outsider.id, linkage.reload.decidim_user_id
        end

        # --- per-citizen reversal (new-feature #7) ---

        test "reversing an original earn journals recognition and settles the wallet once" do
          earn = @ledger.award(@citizen, 200, reason: "proposal")
          assert_equal 200, @ledger.account_for(@citizen).balance

          sign_in @admin
          assert_difference -> { Decidim::Bih::Goodwill::Transaction.count }, 1 do
            post "/admin/bih/citizens/#{@citizen.id}/reverse/#{earn.id}",
                 params: { private_reason: "Ispravka pogrešno dodijeljenih bodova" }
          end
          assert_response :redirect
          assert_redirected_to "/admin/bih/citizens/#{@citizen.id}"

          account = @ledger.account_for(@citizen)
          assert_equal [0, 0], [account.balance, account.contribution_score]
          correction = Decidim::Bih::Goodwill::CreditCorrection.find_by!(original_transaction: earn)
          assert_equal [-200, 0], [correction.recognition_delta, correction.target_amount]
          assert_equal @admin, correction.actor
          assert_equal "settled", correction.settlement.status
          assert_equal(-200, correction.settlement.wallet_delta)
          assert_equal "source_wallet_correction", correction.settlement.ledger_transaction.reason
          assert_equal 200, earn.reload.credited_amount, "the original earn remains immutable"
        end

        test "reversal of a cross-org transaction is refused with no change" do
          other = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other)
          other_ledger = Decidim::Bih::Goodwill::Ledger.new
          foreign_earn = other_ledger.award(outsider, 120, reason: "proposal")

          sign_in @admin
          assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.count } do
            post "/admin/bih/citizens/#{@citizen.id}/reverse/#{foreign_earn.id}",
                 params: { private_reason: "Provjera granice organizacije" }
          end
          assert_response :redirect
          # Outsider's balance untouched.
          assert_equal 120, other_ledger.account_for(outsider).balance
        end

        test "reversal of a transaction not touching this citizen is refused" do
          stranger = FactoryBot.create(:user, :confirmed, organization: @organization)
          stranger_earn = @ledger.award(stranger, 90, reason: "proposal")

          sign_in @admin
          # The txn belongs to this org but to a DIFFERENT citizen, so reversing it
          # from @citizen's profile must not find/touch it.
          assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.count } do
            post "/admin/bih/citizens/#{@citizen.id}/reverse/#{stranger_earn.id}",
                 params: { private_reason: "Provjera vlasništva transakcije" }
          end
          assert_response :redirect
          assert_equal 90, @ledger.account_for(stranger).balance
        end

        test "double reversal of the same transaction is an idempotent no-op" do
          earn = @ledger.award(@citizen, 200, reason: "proposal")

          sign_in @admin
          post "/admin/bih/citizens/#{@citizen.id}/reverse/#{earn.id}",
               params: { private_reason: "Prva ispravka" }
          assert_equal 0, @ledger.account_for(@citizen).balance

          # Second reverse must not post another mirror debit (would drive negative).
          assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.count } do
            post "/admin/bih/citizens/#{@citizen.id}/reverse/#{earn.id}",
                 params: { private_reason: "Ponovljena ispravka" }
          end
          assert_response :redirect
          assert_equal 0, @ledger.account_for(@citizen).balance
        end

        test "pending wallet recovery blocks repeat revocation while a restored source becomes reversible again" do
          earn = @ledger.award(@citizen, 20, reason: "report")
          @ledger.spend(owner: @citizen, amount: 20, kind: "redeem")
          sign_in @admin
          path = "/admin/bih/citizens/#{@citizen.id}/reverse/#{earn.id}"
          post path, params: { private_reason: "Prva ispravka" }
          correction = Decidim::Bih::Goodwill::CreditCorrection.find_by!(original_transaction: earn)
          assert_equal "admin_pending", correction.settlement.status
          get "/admin/bih/citizens/#{@citizen.id}"
          assert_select "form[action='#{path}']", count: 0
          assert_no_difference -> { Decidim::Bih::Goodwill::CreditCorrection.count } do
            post path, params: { private_reason: "Ponovljena ispravka" }
          end
          assert_equal 0, @ledger.account_for(@citizen).balance

          Decidim::Bih::Goodwill::SourceCreditCorrection.correct(
            original: earn, target: -> { 20 }, version: -> { "confirmed-again" }, actor: @admin, reason: "source_reinstated"
          )
          assert_equal "superseded", correction.settlement.reload.status
          get "/admin/bih/citizens/#{@citizen.id}"
          assert_select "form[action='#{path}']", count: 1
          assert_difference -> { Decidim::Bih::Goodwill::CreditCorrection.count }, 1 do
            post path, params: { private_reason: "Nova ispravka nakon vraćanja" }
          end
          account = @ledger.account_for(@citizen)
          assert_equal [0, 0], [account.balance, account.contribution_score]
        end

        test "reversing an adjustment/reversal transaction is refused" do
          earn = @ledger.award(@citizen, 200, reason: "proposal")
          reversal = @ledger.reverse(earn)
          assert_equal "adjustment", reversal.kind
          assert_equal "source_wallet_correction", reversal.reason
          assert_equal 0, @ledger.account_for(@citizen).balance

          sign_in @admin
          assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.count } do
            post "/admin/bih/citizens/#{@citizen.id}/reverse/#{reversal.id}",
                 params: { private_reason: "Pokušaj ispravke storna" }
          end
          assert_response :redirect
          # Balance stays at the already-reversed zero (no double mirror).
          assert_equal 0, @ledger.account_for(@citizen).balance
        end

        test "non-admin cannot reverse a transaction" do
          earn = @ledger.award(@citizen, 200, reason: "proposal")

          sign_in @citizen
          assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.count } do
            post "/admin/bih/citizens/#{@citizen.id}/reverse/#{earn.id}"
          end
          assert_response :redirect
          assert_equal 200, @ledger.account_for(@citizen).balance
        end

        test "reverse CSRF regression: missing token returns 422, no ledger change" do
          earn = @ledger.award(@citizen, 200, reason: "proposal")

          sign_in @admin
          with_forgery_protection do
            assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.count } do
              post "/admin/bih/citizens/#{@citizen.id}/reverse/#{earn.id}",
                   params: { private_reason: "CSRF provjera" }
            end
          end
          assert_response :unprocessable_entity
          assert_equal 200, @ledger.account_for(@citizen).balance
        end

        test "the Reverse button appears on a reversible ledger entry" do
          @ledger.award(@citizen, 200, reason: "proposal")
          sign_in @admin
          get "/admin/bih/citizens/#{@citizen.id}"
          assert_response :success
          assert_includes response.body, "/reverse/"
          assert_includes response.body,
                          I18n.t("decidim.bih.admin.citizens.show.reverse", default: "Reverse")
        end

        test "clear komšiluk resets the citizen profile assignment" do
          komsiluk = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk",
            name: { "sr" => "Komšiluk Sjever" }, slug: "komsiluk-sjever"
          )
          profile = Decidim::Bih::CitizenProfile.for_user(@citizen, organization: @organization)
          profile.update!(komsiluk:, source: "dropdown", assigned_at: Time.current)

          sign_in @admin
          post "/admin/bih/citizens/#{@citizen.id}/clear-komsiluk"
          assert_response :redirect

          assert_nil profile.reload.komsiluk_id
        end

        private

        def with_forgery_protection
          previous = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          yield
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end
      end
    end
  end
end
