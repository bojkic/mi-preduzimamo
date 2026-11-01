# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Verifies the PostagesController override:
      #   - POST /admin/postal_letter/pending_authorizations/:id/postages mints
      #     exactly one postal LoginToken and renders the printable letter view.
      #   - GET /admin/postal_letter/pending_authorizations (index) does NOT
      #     mint any token — rendering it twice leaves token count unchanged.
      class PostalPostagesControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @original_magic_link_short_path_enabled = Decidim::Bih.magic_link_short_path_enabled
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)

          # A pending postal_letter authorization in pre-mailing state
          # (pending_verification_code present, letter not yet sent).
          @authorization = Decidim::Authorization.create!(
            user: @citizen,
            name: "postal_letter",
            granted_at: nil,
            verification_metadata: {
              "address" => "Ulica Cara Lazara 12, Bijeljina",
              "pending_verification_code" => "654321"
            }
          )
        end

        teardown do
          Decidim::Bih.magic_link_short_path_enabled = @original_magic_link_short_path_enabled
        end

        # ─── Index is read-only: GET never mints a token ─────────────────────

        test "GET index does not mint any postal tokens (first render)" do
          sign_in @admin
          token_count_before = Decidim::Bih::LoginToken.where(decidim_user_id: @citizen.id,
                                                              purpose: "postal").count
          get "/admin/postal_letter/pending_authorizations"
          assert_response :success

          assert_includes response.body, "admin-bih-navigation"
          assert_includes response.body, "postal-verification-privacy-note"

          token_count_after = Decidim::Bih::LoginToken.where(decidim_user_id: @citizen.id,
                                                             purpose: "postal").count
          assert_equal token_count_before, token_count_after,
                       "GET index must not mint any postal token"
        end

        test "GET index twice does not change token count or invalidate existing tokens" do
          # Simulate a token already minted by a prior Send action.
          raw = Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "postal")

          sign_in @admin
          get "/admin/postal_letter/pending_authorizations"
          assert_response :success
          get "/admin/postal_letter/pending_authorizations"
          assert_response :success

          token = Decidim::Bih::LoginToken.find_by(
            token_digest: Decidim::Bih::LoginToken.digest(raw)
          )
          assert_not_nil token, "pre-existing token must still exist after two index renders"
          assert_nil token.consumed_at, "pre-existing token must not be consumed by index renders"
        end

        test "GET index renders operator regenerate and cancel controls" do
          @authorization.update!(
            verification_metadata: {
              "address" => "Ulica Cara Lazara 12, Bijeljina",
              "verification_code" => "654321",
              "letter_sent_at" => Time.current.iso8601
            }
          )

          sign_in @admin
          get "/admin/postal_letter/pending_authorizations"

          assert_response :success
          assert_includes response.body,
                          I18n.t("decidim.verifications.postal_letter.admin.pending_authorizations.index.resend_regenerate", locale: :sr)
          assert_includes response.body,
                          I18n.t("decidim.verifications.postal_letter.admin.pending_authorizations.index.cancel_request", locale: :sr)
          assert_includes response.body,
                          "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages/resend"
          assert_includes response.body,
                          "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages/cancel"
        end

        # ─── POST /postages mints exactly one token + renders printable letter ─

        test "POST create mints exactly one postal token for the authorization's user" do
          sign_in @admin
          assert_difference(
            -> { Decidim::Bih::LoginToken.where(decidim_user_id: @citizen.id, purpose: "postal").count },
            1
          ) do
            post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"
          end
        end

        test "POST create renders the printable letter (not a redirect)" do
          sign_in @admin
          post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"
          assert_response :success, "printable letter must render 200, not a redirect"
        end

        test "POST create response contains the confirm URL" do
          sign_in @admin
          post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"
          assert_response :success
          assert_match %r{https://#{Regexp.escape(@organization.host)}/v/[A-Za-z0-9_-]+},
                       response.body,
                       "printable letter must contain the configured short confirm URL"
        end

        test "POST create response follows mounted magic-link path when short links are disabled" do
          Decidim::Bih.magic_link_short_path_enabled = false

          sign_in @admin
          post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"

          assert_response :success
          assert_match %r{https://#{Regexp.escape(@organization.host)}/biceriseno/v/[A-Za-z0-9_-]+},
                       response.body,
                       "printable letter must contain the configured mounted confirm URL"
        end

        test "POST create response does not contain the token digest (only the raw token)" do
          sign_in @admin
          post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"
          assert_response :success

          token = Decidim::Bih::LoginToken.where(decidim_user_id: @citizen.id,
                                                 purpose: "postal").last
          assert_not_nil token
          assert_not_includes response.body, token.token_digest,
                              "response must not expose the token digest"
        end

        test "POST create marks the letter as sent (letter_sent? becomes true)" do
          sign_in @admin
          post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"
          assert_response :success
          assert @authorization.reload.verification_metadata["verification_code"].present?,
                 "letter must be marked as sent (verification_code key set)"
        end

        test "re-sending (second POST) mints a new token and invalidates the first" do
          sign_in @admin
          # Update auth back to pre-mailing state to allow a second send
          @authorization.update!(
            verification_metadata: {
              "address" => "Ulica Cara Lazara 12, Bijeljina",
              "pending_verification_code" => "654321"
            }
          )
          post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"
          first_token = Decidim::Bih::LoginToken.where(decidim_user_id: @citizen.id,
                                                       purpose: "postal").last
          assert_not_nil first_token

          # Reset to pre-mailing state again to allow another Send
          @authorization.update!(
            verification_metadata: {
              "address" => "Ulica Cara Lazara 12, Bijeljina",
              "pending_verification_code" => "654321"
            }
          )

          post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"
          second_token = Decidim::Bih::LoginToken.where(decidim_user_id: @citizen.id,
                                                        purpose: "postal").last

          # The first token must now be consumed (invalidated by issue!)
          first_token.reload
          assert_not_nil first_token.consumed_at,
                         "first token must be invalidated when a second letter is sent"

          assert_nil second_token.consumed_at,
                     "second (most recent) token must be live"
        end

        test "operator resend regenerates the code mints a fresh token and renders printable letter" do
          raw = Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "postal")
          old_token = Decidim::Bih::LoginToken.find_by!(
            token_digest: Decidim::Bih::LoginToken.digest(raw)
          )
          @authorization.update!(
            verification_metadata: {
              "address" => "Ulica Cara Lazara 12, Bijeljina",
              "verification_code" => "111111",
              "letter_sent_at" => 2.days.ago.iso8601
            }
          )

          sign_in @admin
          assert_difference(
            -> { Decidim::Bih::LoginToken.where(decidim_user_id: @citizen.id, purpose: "postal").count },
            1
          ) do
            post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages/resend"
          end

          assert_response :success
          @authorization.reload
          new_code = @authorization.verification_metadata.fetch("verification_code")
          assert_match(/\A\d{6}\z/, new_code)
          assert_not_equal "111111", new_code
          assert_nil @authorization.verification_metadata["pending_verification_code"]
          assert_includes response.body, new_code

          old_token.reload
          assert_not_nil old_token.consumed_at,
                         "resend must invalidate the previously printed postal link"
          assert_nil Decidim::Bih::LoginToken.where(decidim_user_id: @citizen.id, purpose: "postal").last.consumed_at
        end

        test "operator cancel removes an ungranted postal request and invalidates postal tokens" do
          raw = Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "postal")
          token = Decidim::Bih::LoginToken.find_by!(
            token_digest: Decidim::Bih::LoginToken.digest(raw)
          )

          sign_in @admin
          assert_difference("Decidim::Authorization.where(name: 'postal_letter').count", -1) do
            delete "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages/cancel"
          end

          assert_redirected_to "/admin/postal_letter/pending_authorizations"
          assert_nil Decidim::Authorization.find_by(id: @authorization.id)
          token.reload
          assert_not_nil token.consumed_at,
                         "cancel must invalidate live postal links for the canceled request"
        end

        test "unauthenticated request is rejected" do
          post "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages"
          assert_response :redirect
        end

        test "unauthenticated cancel request is rejected" do
          delete "/admin/postal_letter/pending_authorizations/#{@authorization.id}/postages/cancel"
          assert_response :redirect
          assert Decidim::Authorization.exists?(@authorization.id)
        end
      end
    end
  end
end
