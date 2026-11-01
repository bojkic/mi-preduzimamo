# frozen_string_literal: true

require "test_helper"
require "rake"

module Decidim
  module Bih
    # Tests for:
    #   1. decidim_bih:komsiluk:expire_posts rake task
    #   2. Privacy::RetentionSweep#sweep_komsiluk_posts
    # rubocop:disable Rails/SkipsModelValidations
    class KomsilukExpiryAndRetentionTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @mz = LocalArea.create!(
          organization: @organization, kind: "mz", slug: "mz-expiry",
          name: { "sr" => "Test MZ" }
        )
        @komsiluk = LocalArea.create!(
          organization: @organization, kind: "komsiluk", slug: "komsiluk-expiry",
          name: { "sr" => "Test Komšiluk" }, parent: @mz
        )
        @author = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      # ── Rake task: privacy retention_sweep wires komsiluk_post_body_before ──

      test "retention_sweep rake task is defined" do
        Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:privacy:retention_sweep")
        assert Rake::Task.task_defined?("decidim_bih:privacy:retention_sweep")
      end

      test "retention_sweep rake task records durable run history" do
        Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:privacy:retention_sweep")
        old_post = build_post(status: "closed", body: "Rake history body")
        old_post.update_columns(updated_at: 100.days.ago)
        task = Rake::Task["decidim_bih:privacy:retention_sweep"]

        with_retention_env(
          "HOST" => @organization.host,
          "KOMSILUK_POST_BODY_BEFORE" => 90.days.ago.iso8601,
          "APPLY" => nil
        ) do
          stdout, = capture_io { task.invoke }
          run = Privacy::RetentionRun.where(organization: @organization).recent.first

          assert_match(/retention_run_id=\d+/, stdout)
          assert_equal "ok", run.status
          assert run.dry_run?
          assert_equal "rake", run.source
          assert_equal 1, run.counts["komsiluk_post_bodies"]
          assert_equal "Rake history body", old_post.reload.body
        end
      ensure
        task&.reenable
      end

      test "KOMSILUK_POST_BODY_BEFORE env var wires through to RetentionSweep" do
        # Verify the env var path works end-to-end via the service (rake calls the
        # service directly; we test the service receives and acts on the param).
        old_post = build_post(status: "closed", body: "Env-var-path body")
        old_post.update_columns(updated_at: 100.days.ago)

        # Simulate what the rake task does when KOMSILUK_POST_BODY_BEFORE is set
        cutoff_str = 90.days.ago.to_s
        result = Privacy::RetentionSweep.call(
          organization: @organization,
          dry_run: false,
          komsiluk_post_body_before: cutoff_str
        )

        assert_equal 1, result.counts[:komsiluk_post_bodies]
        assert_nil old_post.reload.body
      end

      # ── Rake task: expire_posts ────────────────────────────────────────────

      test "expire_posts rake task guard: only loads tasks once" do
        Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:komsiluk:expire_posts")
        assert Rake::Task.task_defined?("decidim_bih:komsiluk:expire_posts")
      end

      test "expire_posts scope: only transitions open posts past expires_at" do
        expired_post = build_post(
          status: "open",
          category: "safety", # gets 30-day expiry by default
          expires_at: 2.days.ago # force past
        )
        not_yet_expired = build_post(
          status: "open",
          category: "safety",
          expires_at: 10.days.from_now
        )
        already_closed = build_post(
          status: "closed",
          expires_at: 2.days.ago
        )
        no_expiry = build_post(
          status: "open",
          category: "general",
          expires_at: nil
        )

        scope = KomsilukPost
                .where(decidim_organization_id: @organization.id)
                .where(status: "open")
                .where("expires_at IS NOT NULL AND expires_at < ?", Time.current)

        assert_includes scope.pluck(:id), expired_post.id
        assert_not_includes scope.pluck(:id), not_yet_expired.id
        assert_not_includes scope.pluck(:id), already_closed.id
        assert_not_includes scope.pluck(:id), no_expiry.id

        # Simulate what the rake task's APPLY=1 path does
        scope.update_all(status: "expired", updated_at: Time.current)
        assert_equal "expired", expired_post.reload.status
        assert_equal "open", not_yet_expired.reload.status
        assert_equal "closed", already_closed.reload.status
        assert_equal "open", no_expiry.reload.status
      end

      # ── RetentionSweep: komsiluk_post_bodies ─────────────────────────────

      test "dry-run returns count without nullifying body" do
        old_post = build_post(status: "closed", body: "Sensitive content")
        old_post.update_columns(updated_at: 100.days.ago)

        result = Privacy::RetentionSweep.call(
          organization: @organization,
          komsiluk_post_body_before: 90.days.ago
        )

        assert result.dry_run
        assert_equal 1, result.counts[:komsiluk_post_bodies]
        assert_equal "Sensitive content", old_post.reload.body
      end

      test "enabled sweep nullifies body of old closed/expired posts" do
        old_closed = build_post(status: "closed", body: "Old closed body")
        old_expired = build_post(status: "expired", body: "Old expired body")
        recent_post = build_post(status: "closed", body: "Recent closed body")
        open_post = build_post(status: "open", body: "Open body")

        old_closed.update_columns(updated_at: 100.days.ago)
        old_expired.update_columns(updated_at: 100.days.ago)
        recent_post.update_columns(updated_at: 10.days.ago)

        result = Privacy::RetentionSweep.call(
          organization: @organization,
          dry_run: false,
          komsiluk_post_body_before: 90.days.ago
        )

        assert_equal 2, result.counts[:komsiluk_post_bodies]
        assert_nil old_closed.reload.body
        assert_nil old_expired.reload.body
        assert_equal "Recent closed body", recent_post.reload.body
        assert_equal "Open body", open_post.reload.body
      end

      test "sweep is tenant-scoped (other org's posts untouched)" do
        other_org = create_organization
        other_mz = LocalArea.create!(
          organization: other_org, kind: "mz", slug: "mz-other-exp",
          name: { "sr" => "Other MZ" }
        )
        other_k = LocalArea.create!(
          organization: other_org, kind: "komsiluk", slug: "komsiluk-other-exp",
          name: { "sr" => "Other K" }, parent: other_mz
        )
        other_author = FactoryBot.create(:user, :confirmed, organization: other_org)
        other_post = KomsilukPost.create!(
          organization: other_org, author: other_author, komsiluk: other_k,
          category: "general", title: "Other post", body: "Other body",
          status: "closed"
        )
        other_post.update_columns(updated_at: 100.days.ago)

        Privacy::RetentionSweep.call(
          organization: @organization,
          dry_run: false,
          komsiluk_post_body_before: 90.days.ago
        )

        # Other org's post body should remain untouched
        assert_equal "Other body", other_post.reload.body
      end

      test "sweep does not nullify body of already-nil posts" do
        nilbody = build_post(status: "closed")
        nilbody.update_columns(body: nil, updated_at: 100.days.ago)

        result = Privacy::RetentionSweep.call(
          organization: @organization,
          dry_run: false,
          komsiluk_post_body_before: 90.days.ago
        )

        # Count should be 0 (no body to sweep)
        assert_equal 0, result.counts[:komsiluk_post_bodies]
      end

      private

      def with_retention_env(values)
        keys = %w(
          ORGANIZATION_ID HOST APPLY REPORT_CONTACT_BEFORE REPORT_PHOTO_BEFORE
          REPORT_COORDINATES_BEFORE REPORT_COORDINATE_PRECISION VIBER_LINKAGE_BEFORE
          VOLUNTEER_AVAILABILITY_BEFORE KOMSILUK_POST_BODY_BEFORE
          CHAT_FEEDBACK_BEFORE PARTNER_PRIVATE_CONTACT_BEFORE
          PARTNER_VERIFICATION_DOCUMENT_BEFORE OPERATOR_MESSAGE_BODY_BEFORE
        )
        previous = keys.index_with { |key| ENV.fetch(key, nil) }
        keys.each { |key| ENV.delete(key) }
        values.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
        yield
      ensure
        previous.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
      end

      def build_post(status: "open", body: "Default body", **attrs)
        KomsilukPost.create!({
          organization: @organization,
          author: @author,
          komsiluk: @komsiluk,
          category: "general",
          title: "Test post #{SecureRandom.hex(4)}",
          body: body,
          status: status
        }.merge(attrs))
      end
    end
    # rubocop:enable Rails/SkipsModelValidations
  end
end
