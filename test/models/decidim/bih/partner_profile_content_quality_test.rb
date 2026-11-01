# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class PartnerProfileContentQualityTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :confirmed, organization: @organization, admin: true)
      end

      test "verification accepts a distinct production-ready public profile" do
        profile = build_profile(
          display_name: "Udruženje građana Semberija",
          public_description: "Udruženje vodi programe podrške građanima Semberije."
        )

        assert_empty profile.verification_content_issues
        assert profile.verify!(by: @admin)
        assert profile.verified?
      end

      test "verification rejects public sample markers" do
        profile = build_profile(
          display_name: "Udruženje mladih (uzorak)",
          public_description: "Primjer profila koji ne smije postati javno verifikovan."
        )

        assert_includes profile.verification_content_issues, :sample_marker
        assert_raises(ActiveRecord::RecordInvalid) { profile.verify!(by: @admin) }
        assert_equal "submitted", profile.reload.verification_status
      end

      test "verification rejects placeholder-length public descriptions" do
        profile = build_profile(display_name: "Udruženje mladih", public_description: "asdfgbhnj")

        assert_includes profile.verification_content_issues, :description_too_short
        assert_raises(ActiveRecord::RecordInvalid) { profile.verify!(by: @admin) }
      end

      test "verification rejects a duplicate verified public name in the same tenant" do
        existing = build_profile(
          display_name: "Lokalna fondacija Bijeljina",
          public_description: "Fondacija podržava lokalne inicijative i građansko učešće."
        )
        existing.verify!(by: @admin)
        duplicate = build_profile(
          display_name: " lokalna fondacija bijeljina ",
          public_description: "Drugi profil sa istim javnim nazivom zahtijeva pregled.",
          slug: "lokalna-fondacija-bijeljina-duplicate"
        )

        assert_includes duplicate.verification_content_issues, :duplicate_name
        assert_raises(ActiveRecord::RecordInvalid) { duplicate.verify!(by: @admin) }
      end

      private

      def build_profile(display_name:, public_description:, slug: nil)
        Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name:,
          slug:,
          public_description:,
          kind: "association",
          verification_status: "submitted"
        )
      end
    end
  end
end
