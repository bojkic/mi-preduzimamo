# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module Admin
      class GoodwillCorrectionsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @report = Report.create!(organization: @organization, author: @citizen, description: "Rupa na putu", address: "Vidovdanska 1")
          @ledger = Goodwill::Ledger.new
          @ledger.award(@citizen, 20, reason: "report", idempotency_key: Goodwill::IdempotencyKey.report(@report.id))
          @report.update_columns(status: "odbijeno")
        end

        test "citizen cannot see correction queue or preview" do
          sign_in @citizen
          get "/admin/bih/goodwill/corrections"
          assert_response :redirect
          get "/admin/bih/goodwill/corrections/preview", params: { reference: @report.reference }
          assert_response :redirect
        end

        test "preview is read only and signed application corrects only once" do
          sign_in @admin
          assert_no_difference -> { Goodwill::CreditCorrection.count } do
            get "/admin/bih/goodwill/corrections/preview", params: { reference: @report.reference }
          end
          assert_response :success
          token = css_select("input[name='preview_token']").first["value"]
          assert_difference -> { Goodwill::CreditCorrection.count }, 1 do
            post "/admin/bih/goodwill/corrections", params: { preview_token: token, reason: "Provjeren ishod" }
          end
          assert_response :redirect
          assert_equal 0, @ledger.account_for(@citizen).reload.balance
          assert_no_difference -> { Goodwill::CreditCorrection.count } do
            post "/admin/bih/goodwill/corrections", params: { preview_token: token, reason: "Ponovljen zahtjev" }
          end
        end

        test "changed wallet invalidates reviewed preview" do
          sign_in @admin
          get "/admin/bih/goodwill/corrections/preview", params: { reference: @report.reference }
          token = css_select("input[name='preview_token']").first["value"]
          @ledger.award(@citizen, 5, reason: "comment")
          assert_no_difference -> { Goodwill::CreditCorrection.count } do
            post "/admin/bih/goodwill/corrections", params: { preview_token: token, reason: "Provjeren ishod" }
          end
          assert_equal 25, @ledger.account_for(@citizen).reload.balance
        end

        test "signed preview cannot be replayed by another admin" do
          sign_in @admin
          get "/admin/bih/goodwill/corrections/preview", params: { reference: @report.reference }
          token = css_select("input[name='preview_token']").first["value"]
          sign_out @admin
          sign_in FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          assert_no_difference -> { Goodwill::CreditCorrection.count } do
            post "/admin/bih/goodwill/corrections", params: { preview_token: token, reason: "Provjeren ishod" }
          end
        end
      end
    end
  end
end
