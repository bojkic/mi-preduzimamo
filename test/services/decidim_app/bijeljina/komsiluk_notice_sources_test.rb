# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/komsiluk_notice_source_fixtures"

module DecidimApp
  module Bijeljina
    class KomsilukNoticeSourcesTest < ActiveSupport::TestCase
      include KomsilukNoticeSourceFixtures

      setup do
        setup_notice_sources
        @cancelled = []
        @cancellation = ->(post:, reason:) { @cancelled << [post.id, reason] }
      end

      test "source prefills require publication permission and organization ownership" do
        report = reviewed_report
        member = create(:user, :confirmed, organization: @organization)
        foreign = create_organization
        foreign_admin = create(:user, :confirmed, :admin, organization: foreign)
        assert_nil source("report", report, actor: member)
        assert_nil source("report", report, actor: foreign_admin)
        assert_nil source("report", report, actor: foreign_admin, organization: foreign)
        assert_nil KomsilukNoticeSources.call(organization: @organization, actor: @admin, kind: "unknown", id: report.id)
        assert_nil KomsilukNoticeSources.call(organization: @organization, actor: @admin, kind: "report", id: "#{report.id} OR 1=1")
        assert source("report", report)
      end

      test "blocked publisher loses source publication authorization" do
        report = reviewed_report
        @admin.update!(blocked: true)
        assert_nil source("report", report)
        assert_not Decidim::Bih::OperatorAuthorization.allowed?(@admin, :broadcast_send_viber, organization: @organization)
      end

      test "report prefill copies reference category and public status but never private evidence or tokens" do
        report = reviewed_report
        data = source("report", report)
        assert_includes data[:title], report.reference
        assert_includes data[:body], Decidim::Bih::ReportStatusPresenter.label(report, locale: :sr)
        assert_includes data[:body], "/biceriseno/prijave/#{report.reference}"
        [report.description, report.ai_summary, report.internal_note, report.reporter_email, report.reporter_phone, report.status_token].each do |private_value|
          assert_not_includes data.to_json, private_value
        end
        assert_equal %w(id kind material_fingerprint revision url), data.dig(:details, "source_record").keys.sort
        previous = data.dig(:details, "source_record", "revision")
        report.update!(internal_note: "Changed private staff note", description: "Changed private report description")
        assert_equal previous, source("report", report).dig(:details, "source_record", "revision")
        report.update!(status: "u_obradi")
        assert_not_equal previous, source("report", report).dig(:details, "source_record", "revision")
      end

      test "public source resolver distinguishes review-only edits from material changes" do
        report = reviewed_report
        post = linked_post("report", report)
        original = KomsilukNoticePublicSource.call(organization: @organization, post:)
        assert_equal false, original[:updating]
        assert_match %r{\A/biceriseno/prijave/}, original[:url]

        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          report.update!(reviewed_at: 1.minute.from_now)
        end
        assert_equal false, KomsilukNoticePublicSource.call(organization: @organization, post: post.reload)[:updating]
        assert_equal false, post.details.dig("source_record", "material_changed")

        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          report.update!(status: "u_obradi")
        end
        result = KomsilukNoticePublicSource.call(organization: @organization, post: post.reload)
        assert_equal({ updating: true, url: nil }, result)
        assert_equal true, post.details.dig("source_record", "material_changed")
      end

      test "board context drops source and notice help links after material source change" do
        report = reviewed_report
        post = linked_post("report", report)
        member = create(:user, :confirmed, organization: @organization)
        Decidim::Bih::CitizenProfile.for_user(member, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
        source_url = source("report", report).dig(:details, "source_record", "url")
        help_url = Rails.application.routes.url_helpers.komsiluk_notice_help_path(post)
        generic_url = Decidim::Bih::Engine.routes.url_helpers.mi_bot_path(script_name: Decidim::Bih.normalized_public_mount_path)
        links = KomsilukBoardContext.call(organization: @organization, user: member, komsiluk: @area, post:)
        assert links.any? { |item| item[:url] == source_url }
        assert links.any? { |item| item[:url] == help_url }

        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          report.update!(status: "u_obradi")
        end
        links = KomsilukBoardContext.call(organization: @organization, user: member, komsiluk: @area, post: post.reload)
        assert links.none? { |item| item[:url] == source_url || item[:url] == help_url }
        assert links.any? { |item| item[:url] == generic_url }
      end

      test "public source resolver protects legacy links and withdrawn or foreign sources" do
        activity = public_activity
        post = linked_post("activity", activity)
        reference = post.details.deep_dup
        reference.fetch("source_record").delete("material_fingerprint")
        post.update!(details: reference)
        assert_equal false, KomsilukNoticePublicSource.call(organization: @organization, post:)[:updating]

        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          activity.update!(title: "Changed public title")
        end
        assert_equal({ updating: true, url: nil }, KomsilukNoticePublicSource.call(organization: @organization, post: post.reload))
        foreign = create_organization
        assert_equal({ updating: true, url: nil }, KomsilukNoticePublicSource.call(organization: foreign, post:))
      end

      test "unreviewed duplicate and withdrawn reports cannot supply a publication" do
        report = reviewed_report
        report.update!(review_state: "pending")
        assert_nil source("report", report)
        report.update!(review_state: "validated", reviewed_at: nil)
        assert_nil source("report", report)
        original = reviewed_report
        report.update!(reviewed_at: Time.current, duplicate_of_report_id: original.id)
        assert_nil source("report", report)
      end

      test "only an operator reviewed point proposes a report board" do
        report = reviewed_report(location_kind: "point", latitude: 44.5, longitude: 19.5)
        assert_empty source("report", report)[:area_ids]
        report.update!(location_reviewed_at: Time.current, location_reviewed_by: @admin)
        assert_equal [@area.id], source("report", report)[:area_ids]
        assert_not_includes source("report", report).to_json, "44.5"
        report.update!(location_kind: "segment", location_end_latitude: 44.6, location_end_longitude: 19.6)
        assert_empty source("report", report)[:area_ids]
      end

      test "activities must remain approved publicly visible and open for signup" do
        activity = public_activity
        assert_equal [@area.id], source("activity", activity)[:area_ids]
        activity.update!(reviewed_at: nil, reviewer: nil)
        assert_empty source("activity", activity)[:area_ids]
        activity.update!(applications_paused_at: Time.current)
        assert_nil source("activity", activity)
        activity.update!(applications_paused_at: nil, signup_deadline_at: 1.minute.ago)
        assert_nil source("activity", activity)
        activity.update!(signup_deadline_at: nil, active: false)
        assert_nil source("activity", activity)
        activity.update!(active: true, review_status: "pending")
        assert_nil source("activity", activity)
      end

      test "approved project uses only native public wording and no inferred board" do
        project = public_project
        data = source("project", project)
        assert_equal "Javni projekat", data[:title]
        assert_includes data[:body], "Isključivo javni opis projekta."
        assert_empty data[:area_ids]
        assert_equal project.id, data.dig(:details, "source_record", "id")
        %w(PRIVATE_PROPOSAL_TITLE PRIVATE_PROPOSAL_DESCRIPTION PRIVATE_PROPOSAL_ADDRESS private-partner@example.invalid).each do |private_value|
          assert_not_includes data.to_json, private_value
        end
        revision = data.dig(:details, "source_record", "revision")
        @submission.update!(title: "Changed private proposal", description: "Changed private proposal body")
        assert_equal revision, source("project", project).dig(:details, "source_record", "revision")
      end

      test "project public scope requires active donation mapping approval partner and exact storage configuration" do
        project = public_project
        assert source("project", project)
        @project_link.update!(active: false)
        assert_nil source("project", project)
        @project_link.update!(active: true)
        @profile.update!(verification_status: "suspended")
        assert_nil source("project", project)
        @profile.update!(verification_status: "verified")
        @budget.component.update!(published_at: nil)
        assert_nil source("project", project)
        @budget.component.update!(published_at: Time.current)
        @budget.participatory_space.update!(published_at: Time.current)
        assert_nil source("project", project)
        @budget.participatory_space.update!(published_at: nil)
        Decidim::Bih::Setting.put(@organization, "community_projects", "budget_id", @budget.id + 1000)
        assert_nil source("project", project)
      end

      test "final source guard holds approval parent and post locks while yielding" do
        project = public_project
        post = linked_post("project", project)
        locked_tables = []
        listener = lambda do |*args|
          sql = args.last[:sql]
          locked_tables << Regexp.last_match(1) if sql.match(/FROM "([^"]+)".*FOR UPDATE/m)
        end
        result = ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
          KomsilukNoticeSources.with_source_lock(post:) { :dispatched_under_locks }
        end
        assert_equal :dispatched_under_locks, result
        expected = %w(decidim_budgets_budgets decidim_bih_partner_project_submissions decidim_bih_partner_profiles
                      decidim_budgets_projects decidim_bih_project_donation_links decidim_bih_settings
                      decidim_components decidim_participatory_processes decidim_bih_komsiluk_posts)
        assert_equal expected, locked_tables
      end

      test "final guard refuses changed missing and no longer public sources without entering delivery" do
        activity = public_activity
        post = linked_post("activity", activity)
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          activity.update!(title: "A materially changed activity")
        end
        entered = false
        assert_equal false, KomsilukNoticeSources.with_source_lock(post:) { entered = true }
        assert_not entered
        activity.destroy!
        assert_equal false, KomsilukNoticeSources.with_source_lock(post:) { entered = true }
        assert_not entered
      end

      test "material changes flag the linked placement without replacing wording or republishing" do
        activity = public_activity
        post = linked_post("activity", activity)
        original_revision = post.details.dig("source_record", "revision")
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          assert_no_difference "Decidim::Bih::KomsilukPost.count" do
            activity.update!(title: "A corrected public title")
          end
        end
        post.reload
        assert_equal "Operator-approved wording", post.title
        assert_equal "Preserve this operator-approved body.", post.body
        assert_equal "open", post.status
        assert_equal "pending", post.review_state
        assert post.details.dig("source_record", "changed_at")
        assert_equal original_revision, post.details.dig("source_record", "revision")
        assert_not_equal original_revision, post.details.dig("source_record", "current_revision")
        assert_equal [[post.id, "source_changed"]], @cancelled
      end

      test "private updates do not flag notices and material changes survive a later private save" do
        report = reviewed_report
        post = linked_post("report", report)
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          report.update!(internal_note: "Only a private note changed")
          assert_nil post.reload.details.dig("source_record", "changed_at")
          report.class.transaction do
            report.update!(status: "u_obradi")
            report.update!(internal_note: "A later private note in the same transaction")
          end
        end
        assert post.reload.details.dig("source_record", "changed_at")
        assert_equal [[post.id, "source_changed"]], @cancelled
      end

      test "withdrawn activities expire placements cancel pending work and preserve a local hide" do
        activity = public_activity
        open_post = linked_post("activity", activity)
        hidden_post = linked_post("activity", activity, status: "hidden")
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          activity.update!(active: false)
          activity.update!(active: true)
        end
        assert_equal "expired", open_post.reload.status
        assert_equal "hidden", hidden_post.reload.status
        assert_operator open_post.expires_at, :<=, Time.current
        assert_operator hidden_post.expires_at, :<=, Time.current
        assert_equal "Preserve this operator-approved body.", open_post.body
        assert_equal [[open_post.id, "source_unavailable"], [hidden_post.id, "source_unavailable"]], @cancelled
      end

      test "parent withdrawal refreshes linked project placements and rollback leaves them alone" do
        project = public_project
        post = linked_post("project", project)
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          @profile.class.transaction do
            @profile.update!(verification_status: "suspended")
            raise ActiveRecord::Rollback
          end
          assert_equal "open", post.reload.status
          assert_empty @cancelled
          @budget.component.update!(published_at: nil)
        end
        assert_equal "expired", post.reload.status
        assert_equal [[post.id, "source_unavailable"]], @cancelled
      end

      test "blocked STI legacy owner withdraws linked activity placements" do
        owner = create(:user, :confirmed, organization: @organization)
        profile = public_partner
        profile.update!(legacy_user_group: owner)
        activity = public_activity(partner_profile: profile)
        post = linked_post("activity", activity)
        assert_includes KomsilukSourceProjectionRefresh.tracked_fields_for(owner), "blocked"
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          owner.update!(blocked: true)
        end
        assert_equal "expired", post.reload.status
        assert_equal [[post.id, "source_unavailable"]], @cancelled
      end

      test "long public activity prefill fits board body limit and retains navigation" do
        activity = public_activity(description: "Javni opis " * 400, location: "Lokacija " * 45)
        data = source("activity", activity)
        assert_operator data[:body].length, :<=, Decidim::Bih::KomsilukPost::BODY_MAX
        assert_includes data[:body], "/biceriseno/volontiranje"
      end

      test "periodic source expiry is scoped to one organization" do
        activity = public_activity(signup_deadline_at: 1.minute.from_now)
        post = linked_post("activity", activity)
        foreign = create_organization
        Decidim::Bih::Komsiluk::NoticePublishing.stub(:cancel_pending_for!, @cancellation) do
          travel 2.minutes do
            KomsilukNoticeSources.refresh_due!(organization: foreign)
            assert_equal "open", post.reload.status
            KomsilukNoticeSources.refresh_due!(organization: @organization)
            assert_equal "expired", post.reload.status
          end
        end
        assert_equal [[post.id, "source_unavailable"]], @cancelled
      end
    end
  end
end
