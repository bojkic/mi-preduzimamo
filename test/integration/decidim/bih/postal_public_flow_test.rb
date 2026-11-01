# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class PostalPublicFlowTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "citizen can request a postal verification letter from the public form" do
        sign_in @user

        get "/postal_letter/"
        assert_response :success
        assert_includes response.body, "Zatraži pismo za verifikaciju adrese"
        assert_includes response.body, "Privatnost adrese"
        assert_includes response.body, "Adresa se ne prikazuje na javnom profilu"

        post "/postal_letter/authorizations", params: {
          address: { full_address: "Ulica Cara Lazara 12, Bijeljina" }
        }

        assert_redirected_to "/authorizations"
        authorization = Decidim::Authorization.find_by!(user: @user, name: "postal_letter")
        assert_nil authorization.granted_at
        assert_equal "Ulica Cara Lazara 12, Bijeljina", authorization.verification_metadata["address"]
        assert authorization.verification_metadata["pending_verification_code"].present?
      end

      test "unsent pending postal request shows waiting status without leaking address" do
        Decidim::Authorization.create!(
          user: @user,
          name: "postal_letter",
          verification_metadata: {
            "address" => "Ulica Cara Lazara 12, Bijeljina",
            "pending_verification_code" => "123456"
          }
        )
        sign_in @user

        get "/postal_letter/authorizations/edit"

        assert_response :success
        assert_includes response.body, "Pismo još nije označeno kao poslano"
        assert_includes response.body, "Zahtjev je u redu za štampu i slanje"
        assert_not_includes response.body, "Ulica Cara Lazara 12"
      end

      test "sent postal request accepts manual code and grants authorization" do
        authorization = Decidim::Authorization.create!(
          user: @user,
          name: "postal_letter",
          verification_metadata: {
            "address" => "Ulica Cara Lazara 12, Bijeljina",
            "verification_code" => "123456",
            "letter_sent_at" => Time.current.iso8601
          }
        )
        sign_in @user

        get "/postal_letter/authorizations/edit"
        assert_response :success
        assert_includes response.body, "Potvrdi kod iz pisma"
        assert_includes response.body, "QR/magic link iz pisma važi 30 dana"
        assert_not_includes response.body, "Ulica Cara Lazara 12"

        put "/postal_letter/authorizations", params: {
          confirmation: { verification_code: "123456" }
        }

        assert_redirected_to "/authorizations"
        assert authorization.reload.granted?
      end
    end
  end
end
