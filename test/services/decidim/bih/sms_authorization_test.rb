# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class SmsAuthorizationTest < ActiveSupport::TestCase
      # The previous inline formula, replicated verbatim from the three call
      # sites (PhoneSessionsController, GrantsSmsAuthorization, Viber
      # AccountLinking) before extraction. The helper MUST reproduce this
      # byte-for-byte: the value is compared against stored
      # Decidim::Authorization#unique_id rows, so any drift silently breaks OTP
      # verification AND the passwordless phone-login lookup.
      def legacy_inline_unique_id(phone)
        normalized = phone.to_s.gsub(/[^+0-9]/, "")
        Digest::SHA256.hexdigest("#{normalized}-#{Rails.application.secret_key_base}")
      end

      test "unique_id_for reproduces the previous inline formula for a normalized phone" do
        normalized = "38765123456"

        assert_equal legacy_inline_unique_id(normalized),
                     Decidim::Bih::SmsAuthorization.unique_id_for(normalized)
      end

      test "unique_id_for matches the legacy formula across the phone formats every site passes" do
        # Covers the candidate shapes the three sites feed in: digits-only and
        # +-prefixed (AccountLinking), local 0-prefixed and bare national, plus a
        # value carrying separators that normalization must strip.
        [
          "38765123456", # digits-only (Viber OTP stored shape)
          "+38765123456", # +-prefixed (form/login typical)
          "065123456", # local 0-prefixed
          "65123456", # bare national
          "+387 65 123-456", # separators that must be stripped to +-and-digits
          "" # blank edge case
        ].each do |phone|
          assert_equal legacy_inline_unique_id(phone),
                       Decidim::Bih::SmsAuthorization.unique_id_for(phone),
                       "unique_id_for drifted from legacy formula for #{phone.inspect}"
        end
      end

      test "normalization is idempotent so a pre-normalized phone hashes identically" do
        raw = "+387 65 123-456"
        pre_normalized = raw.gsub(/[^+0-9]/, "")

        assert_equal Decidim::Bih::SmsAuthorization.unique_id_for(raw),
                     Decidim::Bih::SmsAuthorization.unique_id_for(pre_normalized)
      end

      test "unique_id_for equals what Decidim's MobilePhoneForm would produce" do
        # The form sanitizes mobile_phone_number to [+0-9] then hashes it; the
        # helper must produce the identical unique_id for the same input. We build
        # the form with a + and separators to exercise its sanitization too.
        organization = create_organization
        user = FactoryBot.create(:user, :confirmed, organization: organization)

        form = Decidim::Verifications::Sms::MobilePhoneForm.from_params(
          mobile_phone_number: "+387 65 123-456"
        ).with_context(current_organization: organization, current_user: user)

        assert_equal form.unique_id,
                     Decidim::Bih::SmsAuthorization.unique_id_for("+387 65 123-456")
      end

      test "#normalize keeps only + and digits matching MobilePhoneForm" do
        assert_equal "+38765123456", Decidim::Bih::SmsAuthorization.normalize("+387 65/123-456")
        assert_equal "38765123456", Decidim::Bih::SmsAuthorization.normalize("387 65 123 456")
        assert_equal "", Decidim::Bih::SmsAuthorization.normalize(nil)
      end
    end
  end
end
