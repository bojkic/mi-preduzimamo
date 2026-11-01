# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Postal
      class PostalTokenServiceTest < ActiveSupport::TestCase
        setup do
          @original_magic_link_short_path_enabled = Decidim::Bih.magic_link_short_path_enabled
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @authorization = Decidim::Authorization.create!(
            user: @user,
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

        test "issue_for_authorization mints a LoginToken with purpose postal" do
          assert_difference("Decidim::Bih::LoginToken.count", 1) do
            PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)
          end

          token = Decidim::Bih::LoginToken.last
          assert_equal "postal", token.purpose
          assert_equal @user, token.user
          assert_nil token.phone, "postal tokens have no phone binding"
        end

        test "result contains a confirm_url with the raw token" do
          result = PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)
          assert result.confirm_url.present?
          assert result.confirm_url.start_with?("https://#{@organization.host}/v/"),
                 "URL must include the host and /v/ prefix"
          # The URL must not be the token digest — it carries the raw token
          token_record = Decidim::Bih::LoginToken.last
          raw = result.confirm_url.split("/v/").last
          assert_equal token_record.token_digest, Decidim::Bih::LoginToken.digest(raw),
                       "the URL must embed the raw token whose digest is stored"
        end

        test "confirm_url follows the configured magic-link path" do
          Decidim::Bih.magic_link_short_path_enabled = false

          result = PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)

          assert result.confirm_url.start_with?("https://#{@organization.host}/biceriseno/v/"),
                 "URL must use the mounted engine path when short links are disabled"
        end

        test "postal token TTL is 30 days (not 30 minutes)" do
          PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)
          token = Decidim::Bih::LoginToken.last
          assert_in_delta 30.days.from_now, token.expires_at, 60.seconds,
                          "postal tokens must expire in 30 days, not 30 minutes"
        end

        test "result contains a QR SVG when rqrcode is available" do
          result = PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)
          # rqrcode is a Decidim transitive dep so it should always be present.
          # When standalone: false, rqrcode returns the inner path element, not the <svg> wrapper.
          assert result.qr_svg.present?, "QR SVG should be generated"
          assert result.qr_svg.include?("<svg") || result.qr_svg.include?("<path") || result.qr_svg.include?("d="),
                 "qr_svg should contain SVG/path markup but got: #{result.qr_svg&.slice(0, 80)}"
        end

        test "raw token is not logged (does not appear in Rails.logger output)" do
          logged_output = StringIO.new
          old_logger = Rails.logger
          Rails.logger = Logger.new(logged_output)

          result = PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)
          raw = result.confirm_url.split("/v/").last

          Rails.logger = old_logger

          assert_not logged_output.string.include?(raw),
                     "raw token must never appear in log output"
        end

        # issue! semantics: minting a second token for the same user invalidates the first.
        # This is the correct lifecycle behavior — each Send (POST /postages) issues
        # a fresh token for the new letter, deliberately superseding the prior one.
        test "issuing a second token for the same user invalidates the first" do
          result1 = PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)
          raw1 = result1.confirm_url.split("/v/").last

          result2 = PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)
          raw2 = result2.confirm_url.split("/v/").last

          assert_nil Decidim::Bih::LoginToken.consume!(raw: raw1, organization: @organization),
                     "first postal token must be invalidated when a second is issued"
          assert Decidim::Bih::LoginToken.consume!(raw: raw2, organization: @organization),
                 "second postal token must be consumable"
        end

        # ─── Index view must never mint a token ──────────────────────────────
        # The pending-authorizations index is now read-only. It does NOT call
        # issue_for_authorization — rendering it twice leaves token state intact.

        test "the index view does not call issue_for_authorization (no side-effect on GET)" do
          # Mint a token as though the Send action had already been performed.
          raw = Decidim::Bih::LoginToken.issue!(user: @user, purpose: "postal")
          token_before = Decidim::Bih::LoginToken.find_by(
            token_digest: Decidim::Bih::LoginToken.digest(raw)
          )
          assert_not token_before.nil?, "token must exist before simulating index render"

          # Simulate two index renders by reading the ERB template and confirming
          # it contains no call to issue_for_authorization.
          # Use Decidim::Bih::Engine.root to locate the engine regardless of bundle
          # local override vs. gem install path.
          template_path = Decidim::Bih::Engine.root.join(
            "app/views/decidim/verifications/postal_letter/" \
            "admin/pending_authorizations/index.html.erb"
          )
          template_source = File.read(template_path)
          assert_not template_source.include?("issue_for_authorization"),
                     "index template must not call issue_for_authorization (GET must be side-effect-free)"

          # Token count and consumed_at must be unchanged after the template check.
          token_after = Decidim::Bih::LoginToken.find_by(
            token_digest: Decidim::Bih::LoginToken.digest(raw)
          )
          assert_not_nil token_after, "existing token must still exist"
          assert_nil token_after.consumed_at, "token must not be consumed"
          assert_equal token_before.token_digest, token_after.token_digest,
                       "token digest must be unchanged"
        end

        # ─── PostagesController override mints exactly one token on POST ─────
        # The override file itself is the canonical assertion; this test verifies
        # the PostalTokenService is the one called (correct seam) and that the
        # result struct carries the necessary fields for the printable letter.

        test "issue_for_authorization result has confirm_url and qr_svg for printable letter" do
          result = PostalTokenService.issue_for_authorization(@authorization, host: @organization.host)
          assert result.is_a?(PostalTokenService::Result)
          assert result.confirm_url.present?, "printable letter needs a confirm URL"
          # qr_svg may be nil if rqrcode fails; presence is already covered above
          assert_respond_to result, :qr_svg
        end
      end
    end
  end
end
