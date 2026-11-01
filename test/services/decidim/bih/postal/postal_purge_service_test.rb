# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Postal
      class PostalPurgeServiceTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @other_organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @other_user = FactoryBot.create(:user, :confirmed, organization: @other_organization)
        end

        # ─── Boundary: just-under vs just-over 6 months ─────────────────────

        test "keeps a pending authorization that is just under 6 months old" do
          cutoff = 6.months.ago
          # just-under: created 5 months and 29 days ago (newer than cutoff)
          _recent_pending = pending_postal_auth(@user, created_at: cutoff + 1.day)

          result = PostalPurgeService.call(
            organization: @organization,
            cutoff: cutoff,
            dry_run: false
          )

          assert_equal 0, result.purged_count
          assert_equal 1, Decidim::Authorization.where(name: "postal_letter").count
        end

        test "purges a pending authorization that is just over 6 months old" do
          cutoff = 6.months.ago
          # just-over: created 1 second before the cutoff
          _old_pending = pending_postal_auth(@user, created_at: cutoff - 1.second)

          result = PostalPurgeService.call(
            organization: @organization,
            cutoff: cutoff,
            dry_run: false
          )

          assert_equal 1, result.purged_count
          assert_equal 0, Decidim::Authorization.where(name: "postal_letter").count
        end

        # ─── Granted authorizations are never purged ─────────────────────────

        test "does not purge a granted (confirmed) postal authorization" do
          # Granted = granted_at is set; even if old
          cutoff = 6.months.ago
          _granted = granted_postal_auth(@user, created_at: cutoff - 30.days)

          result = PostalPurgeService.call(
            organization: @organization,
            cutoff: cutoff,
            dry_run: false
          )

          assert_equal 0, result.purged_count
          assert_equal 1, Decidim::Authorization.where(name: "postal_letter", user: @user).count
        end

        # ─── User account is never touched ───────────────────────────────────

        test "purging a pending authorization does not delete the user account" do
          cutoff = 6.months.ago
          pending_postal_auth(@user, created_at: cutoff - 1.day)

          assert_no_difference("Decidim::User.count") do
            PostalPurgeService.call(
              organization: @organization,
              cutoff: cutoff,
              dry_run: false
            )
          end

          assert Decidim::User.exists?(@user.id)
        end

        # ─── Dry-run returns count without mutating ───────────────────────────

        test "dry_run returns the count without deleting anything" do
          cutoff = 6.months.ago
          pending_postal_auth(@user, created_at: cutoff - 1.day)

          result = PostalPurgeService.call(
            organization: @organization,
            cutoff: cutoff,
            dry_run: true
          )

          assert result.dry_run
          assert_equal 1, result.purged_count
          assert_equal 1, Decidim::Authorization.where(name: "postal_letter", user: @user).count,
                       "dry_run must not delete records"
        end

        # ─── Tenant scoping ──────────────────────────────────────────────────

        test "only purges authorizations belonging to the given organization" do
          cutoff = 6.months.ago
          # Both orgs have old pending postal auths
          pending_postal_auth(@user, created_at: cutoff - 1.day)
          pending_postal_auth(@other_user, created_at: cutoff - 1.day)

          PostalPurgeService.call(
            organization: @organization,
            cutoff: cutoff,
            dry_run: false
          )

          # Our org's pending auth is gone
          assert_equal 0, pending_scope(@organization).count
          # Other org's auth is untouched
          assert_equal 1, pending_scope(@other_organization).count
        end

        # ─── Purging removes the address (verification_metadata) ─────────────

        test "purging removes the authorization row that contains the mailing address" do
          cutoff = 6.months.ago
          auth = pending_postal_auth(@user, created_at: cutoff - 1.day)
          auth_id = auth.id

          PostalPurgeService.call(
            organization: @organization,
            cutoff: cutoff,
            dry_run: false
          )

          assert_nil Decidim::Authorization.find_by(id: auth_id),
                     "the authorization row (which holds the address) must be destroyed"
        end

        private

        def pending_postal_auth(user, created_at: 7.months.ago)
          Decidim::Authorization.create!(
            user: user,
            name: "postal_letter",
            granted_at: nil,
            verification_metadata: {
              "address" => "Ulica Cara Lazara 12, Bijeljina",
              "pending_verification_code" => "123456"
            },
            created_at: created_at,
            updated_at: created_at
          )
        end

        def granted_postal_auth(user, created_at: 8.months.ago)
          # Decidim::Authorization validates verification_metadata must be blank
          # when granted_at is set — so we create it granted (empty metadata)
          Decidim::Authorization.create!(
            user: user,
            name: "postal_letter",
            granted_at: Time.current,
            verification_metadata: {},
            created_at: created_at,
            updated_at: created_at
          )
        end

        def pending_scope(organization)
          Decidim::Authorization
            .where(name: "postal_letter", granted_at: nil)
            .joins(:user)
            .where(decidim_users: { decidim_organization_id: organization.id })
        end
      end
    end
  end
end
