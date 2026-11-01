# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      class KomsilukPostsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @author = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Private Author Name", nickname: "board_author")
          @mz = LocalArea.create!(organization: @organization, kind: "mz", slug: "mz-board-test", name: { sr: "Naziv mjesne zajednice" })
          @area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-board-test", name: { sr: "Prvi komšiluk" },
                                    primary_mz_slug: @mz.slug, overlapping_mz_slugs: [@mz.slug])
          @other_area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-board-other", name: { sr: "Drugi komšiluk" })
          @post = create_post
          sign_in @admin
        end

        test "delivery tab is scoped read-only operational review without recipient data or retry forms" do
          moderator = FactoryBot.create(:user, :confirmed, organization: @organization)
          OperatorRole.create!(organization: @organization, user: moderator, created_by: @admin, role: "komsiluk_moderator",
                               area_scope: "selected", komsiluk_ids: [@area.id], expires_at: 30.days.from_now)
          outside = create_post(komsiluk: @other_area, title: "Outside delivery scope")
          [@post, outside].each do |post|
            receipt = PlatformDelivery.for!(user: @author, identity: "ops:#{post.id}", expires_at: 1.day.from_now)
            receipt.update!(komsiluk_post: post, created_at: 20.minutes.ago)
          end
          sign_in moderator
          assert_no_difference ["KomsilukPost.count", "KomsilukSendIntent.count", "KomsilukPhoneDelivery.count"] do
            get "/admin/bih/komsiluk-posts", params: { tab: "delivery" }
          end
          assert_response :success
          assert_select "#komsiluk-delivery-operations"
          assert_select ".mi-board-admin-tabs a[href*='tab=delivery']", count: 0
          assert_select "[data-board-delivery-post-id='#{@post.id}']"
          assert_select "[data-board-delivery-post-id='#{outside.id}']", count: 0
          assert_select "#komsiluk-delivery-operations form", count: 0
          assert_select "[data-board-source-issue]", count: 0
          assert_not_includes response.body, @author.email
          assert_not_includes response.body, @author.name
          assert_not_includes response.body, "Outside delivery scope"
        end

        test "queue defaults to unresolved review and settings do not bury tasks" do
          get "/admin/bih/komsiluk-posts"
          assert_response :success
          assert_select "[data-board-post-id='#{@post.id}']", count: 1
          assert_select "#komsiluk-notification-policy", count: 0
          assert_select "a[aria-current='page']", text: /#{Regexp.escape(I18n.t("decidim.bih.admin.board_review.tabs.review"))}/
        end

        test "applied filters stay visible in a compact summary while the form stays collapsed" do
          get "/admin/bih/komsiluk-posts", params: { tab: "all", q: "Objava", category: "general", komsiluk_id: @area.id }
          assert_response :success
          assert_select ".mi-board-admin-filters[open]", count: 0
          assert_select ".mi-board-admin-active-filters", text: /Objava/
          assert_select ".mi-board-admin-active-filters", text: /Prvi komšiluk/
          assert_select ".mi-board-admin-active-filters a[href='/admin/bih/komsiluk-posts?tab=all']"
          assert_select ".mi-board-admin-filters input[name=q][value=Objava]"
        end

        test "effective published and archive tabs account for expiry before cron" do
          overdue = create_post(title: "Overdue pending cron", expires_at: 1.minute.ago, review_state: "reviewed")
          closed = create_post(title: "Already closed", status: "closed", closed_at: 1.hour.ago, review_state: "reviewed")
          get "/admin/bih/komsiluk-posts", params: { tab: "published" }
          assert_select "[data-board-post-id='#{@post.id}']"
          assert_select "[data-board-post-id='#{overdue.id}']", count: 0
          assert_select "[data-board-post-id='#{closed.id}']", count: 0
          get "/admin/bih/komsiluk-posts", params: { tab: "archive" }
          assert_select "[data-board-post-id='#{overdue.id}']"
          assert_select "[data-board-post-id='#{closed.id}']"
          assert_select "[data-board-post-id='#{@post.id}']", count: 0
        end

        test "expired flagged city notices remain archived instead of appearing as review tasks" do
          archived = create_post(title: "Historical city outage", author: nil, origin: "city_service",
                                 status: "expired", expires_at: 1.day.ago, flagged_count: 1)
          overdue = create_post(title: "Overdue city outage", author: nil, origin: "city_service",
                                status: "open", expires_at: 1.minute.ago, flagged_count: 1)
          active = create_post(title: "Current city outage", author: nil, origin: "city_service",
                               status: "open", expires_at: 1.day.from_now, flagged_count: 1)

          get "/admin/bih/komsiluk-posts"
          assert_response :success
          assert_select "[data-board-post-id='#{@post.id}']"
          assert_select "[data-board-post-id='#{active.id}']"
          assert_select "[data-board-post-id='#{archived.id}']", count: 0
          assert_select "[data-board-post-id='#{overdue.id}']", count: 0
          assert_equal "pending", archived.reload.review_state

          get "/admin/bih/komsiluk-posts", params: { tab: "archive" }
          assert_select "[data-board-post-id='#{archived.id}']"
          assert_select "[data-board-post-id='#{overdue.id}']"
        end

        test "filtered pagination reaches records beyond fifty with correct totals" do
          54.times { |index| create_post(title: "Paged #{index}") }
          create_post(title: "Not matching", komsiluk: @other_area)
          seen = []
          1.upto(3) do |page|
            get "/admin/bih/komsiluk-posts", params: { tab: "all", q: "Paged", komsiluk_id: @area.id, page: }
            assert_response :success
            seen.concat(css_select("[data-board-post-id]").map { |node| node["data-board-post-id"] })
            assert_includes response.body, I18n.t("decidim.bih.admin.board_review.showing", shown: page == 3 ? 4 : 25, total: 54)
          end
          assert_equal 54, seen.uniq.size
        end

        test "detail includes full sanitized text and public area names without member or author private fields" do
          @post.update!(body: "#{"Duga objava. " * 60}<b>Završetak</b>")
          get "/admin/bih/komsiluk-posts/#{@post.id}"
          assert_response :success
          assert_includes response.body, "Završetak"
          assert_not_includes response.body, "<b>Završetak</b>"
          assert_includes response.body, "Naziv mjesne zajednice"
          assert_includes response.body, "@board_author"
          assert_not_includes response.body, @author.email
          assert_not_includes response.body, @author.name
        end

        test "source-linked authorless notice shows institution instead of deleted author" do
          @post.update!(author: nil, origin: "city_service", details: { "source" => { "provider" => "Gradska služba", "urls" => ["https://example.org/notice"] } })
          get "/admin/bih/komsiluk-posts/#{@post.id}"
          assert_response :success
          assert_includes response.body, "Gradska služba"
          assert_not_includes response.body, I18n.t("decidim.bih.admin.komsiluk_posts.index.author_deleted")
          assert_select "a[href='https://example.org/notice']"
        end

        test "keep resolves review without deleting flags or hiding content and preserves queue filters" do
          flagger = FactoryBot.create(:user, :confirmed, organization: @organization)
          @post.flag!(flagger)
          assert_difference("Decidim::Bih::KomsilukPostReview.count", 1) do
            decide("keep", tab: "review", q: "Objava", category: "general", komsiluk_id: @area.id, page: 2)
          end
          assert_response :redirect
          @post.reload
          assert_equal "open", @post.status
          assert_equal "reviewed", @post.review_state
          assert_equal 1, @post.flags.count
          assert_equal 1, @post.details.dig("moderation", "reviewed_flag_count")
          query = Rack::Utils.parse_nested_query(URI.parse(response.location).query)
          assert_equal "2", query["page"]
          assert_equal "Objava", query["q"]
          get "/admin/bih/komsiluk-posts"
          assert_select "[data-board-post-id='#{@post.id}']", count: 0
          another = FactoryBot.create(:user, :confirmed, organization: @organization)
          @post.flag!(another)
          assert_equal "pending", @post.reload.review_state
          assert_equal "open", @post.status
        end

        test "hiding and restoring closed scrubbed content preserves lifecycle and audit facts" do
          @post.update!(status: "closed", closed_at: 1.hour.ago)
          @post.update_columns(body: nil) # rubocop:disable Rails/SkipsModelValidations
          decide("hide", reason: "personal_data")
          assert_equal "hidden", @post.reload.status
          assert_equal "closed", @post.reviews.order(:id).last.previous_status
          decide("restore")
          assert_response :redirect
          assert_equal "closed", @post.reload.status
          assert_nil @post.body
          assert_includes flash[:notice], I18n.t("decidim.bih.komsiluk_board.statuses.closed")
          assert_equal "closed", OperatorAuditEvent.order(:id).last.metadata["restored_status"]
        end

        test "restore of overdue hidden notice remains expired" do
          @post.update!(status: "hidden", hidden_at: Time.current, expires_at: 1.minute.ago)
          decide("restore")
          assert_response :redirect
          assert_equal "expired", @post.reload.status
        end

        test "scrubbed unexpired notice cannot be reopened" do
          @post.update!(status: "hidden", hidden_at: Time.current)
          @post.update_columns(body: nil) # rubocop:disable Rails/SkipsModelValidations
          assert_no_difference("Decidim::Bih::KomsilukPostReview.count") { decide("restore") }
          assert_response :unprocessable_entity
          assert_equal "hidden", @post.reload.status
        end

        test "stale and replayed decisions create no extra effects" do
          version = @post.lock_version
          decide("keep")
          assert_no_difference("Decidim::Bih::KomsilukPostReview.count") do
            decide("hide", lock_version: version)
          end
          assert_response :unprocessable_entity
          assert_equal "open", @post.reload.status
        end

        test "decision requires a bounded reason and version" do
          assert_no_difference("Decidim::Bih::KomsilukPostReview.count") { decide("hide", reason: "private free text") }
          assert_response :unprocessable_entity
          assert_no_difference("Decidim::Bih::KomsilukPostReview.count") { decide("hide", lock_version: nil) }
          assert_response :unprocessable_entity
          assert_equal "open", @post.reload.status
        end

        test "missing decision target returns safely without exposing a record" do
          post "/admin/bih/komsiluk-posts/999999999/decision", params: { decision: "hide", reason: "spam", lock_version: 0 }
          assert_response :redirect
          assert_equal "open", @post.reload.status
        end

        test "settings point to current delivery policy and legacy controls cannot change it" do
          get "/admin/bih/komsiluk-posts", params: { tab: "settings" }
          assert_redirected_to "/admin/bih/board-notices/settings"
          get "/admin/bih/komsiluk-posts"
          assert_select "a[href='/admin/bih/board-notices/settings']"
          assert_select ".mi-board-admin-tabs a[href*='tab=settings']", count: 0
          assert_no_difference "Setting.count" do
            patch "/admin/bih/komsiluk-posts/notification-policy", params: {
              notification_policy: { categories: ["safety"], muted_komsiluk_ids: [@area.id] }
            }
          end
          assert_redirected_to "/admin/bih/board-notices/settings"
        end

        test "CSRF-free decision and policy changes are refused" do
          original = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          decide("hide")
          assert_response :unprocessable_entity
          assert_equal "open", @post.reload.status
          patch "/admin/bih/komsiluk-posts/notification-policy", params: { notification_policy: { categories: [] } }
          assert_response :unprocessable_entity
        ensure
          ActionController::Base.allow_forgery_protection = original
        end

        test "scoped moderator can read and decide only assigned boards without phone or source authority" do
          moderator = FactoryBot.create(:user, :confirmed, organization: @organization)
          OperatorRole.create!(organization: @organization, user: moderator, created_by: @admin, role: "komsiluk_moderator",
                               area_scope: "selected", komsiluk_ids: [@area.id], expires_at: 30.days.from_now)
          outside = create_post(komsiluk: @other_area, title: "Outside assigned board")
          sign_in moderator
          get "/admin/bih/komsiluk-posts", params: { tab: "all" }
          assert_response :success
          assert_select "[data-board-post-id='#{@post.id}']"
          assert_select "[data-board-post-id='#{outside.id}']", count: 0
          assert_select "option[value='#{@other_area.id}']", count: 0
          get "/admin/bih/komsiluk-posts/#{outside.id}"
          assert_response :redirect
          assert_not_includes response.body, outside.title
          post "/admin/bih/komsiluk-posts/#{outside.id}/decision", params: { decision: "hide", reason: "spam", lock_version: outside.lock_version }
          assert_response :redirect
          assert_equal "open", outside.reload.status
          decide("keep")
          assert_equal "reviewed", @post.reload.review_state
          assert_not OperatorAuthorization.allowed?(moderator, :broadcast_send_viber, organization: @organization)
          assert_not OperatorAuthorization.allowed?(moderator, :city_alerts_manage, organization: @organization)
          get "/admin/bih/komsiluk-posts", params: { tab: "settings" }
          assert_response :redirect
        end

        test "scoped moderator grants reject empty or foreign scopes and expired roles lose access" do
          moderator = FactoryBot.create(:user, :confirmed, organization: @organization)
          invalid = OperatorRole.new(organization: @organization, user: moderator, role: "komsiluk_moderator",
                                     area_scope: "selected", komsiluk_ids: [], expires_at: 1.day.from_now)
          assert_not invalid.valid?
          invalid.komsiluk_ids = [999_999_999]
          assert_not invalid.valid?
          grant = OperatorRole.create!(organization: @organization, user: moderator, role: "komsiluk_moderator",
                                       area_scope: "selected", komsiluk_ids: [@area.id], expires_at: 1.day.from_now)
          grant.update!(expires_at: 1.minute.ago)
          assert_not OperatorAuthorization.allowed?(moderator, :komsiluk_posts_moderate, organization: @organization, resource: @post)
          assert_empty Komsiluk::ModerationAccess.new(user: moderator, organization: @organization).posts
        end

        test "organization admins cannot inspect or change another organization's board" do
          other_org = create_organization
          other_author = FactoryBot.create(:user, :confirmed, organization: other_org)
          other_area = LocalArea.create!(organization: other_org, kind: "komsiluk", slug: "foreign-board", name: { sr: "Foreign board" })
          foreign = create_post(organization: other_org, author: other_author, komsiluk: other_area, title: "Foreign private board post")
          get "/admin/bih/komsiluk-posts/#{foreign.id}"
          assert_response :redirect
          assert_not_includes response.body, foreign.title
          post "/admin/bih/komsiluk-posts/#{foreign.id}/decision", params: { decision: "hide", reason: "spam", lock_version: foreign.lock_version }
          assert_response :redirect
          assert_equal "open", foreign.reload.status
          assert_empty foreign.reviews
          invalid = OperatorRole.new(organization: @organization, user: @author, role: "komsiluk_moderator",
                                     area_scope: "selected", komsiluk_ids: [other_area.id], expires_at: 1.day.from_now)
          assert_not invalid.valid?
        end

        test "a failed source hook rolls back both decision and moderation state" do
          previous = Komsiluk::PostModeration.integration
          integration = Object.new
          integration.define_singleton_method(:around_decision) { |**_args, &block| block.call }
          integration.define_singleton_method(:after_decision) { |**_args| raise "source transaction failed" }
          Komsiluk::PostModeration.integration = integration
          assert_no_difference("Decidim::Bih::KomsilukPostReview.count") do
            assert_raises(RuntimeError) do
              Komsiluk::PostModeration.new(post: @post, actor: @admin, organization: @organization).call(
                action: :keep, reason: "valid", expected_version: @post.lock_version
              )
            end
          end
          assert_equal "pending", @post.reload.review_state
        ensure
          Komsiluk::PostModeration.integration = previous
        end

        private

        def create_post(**attributes)
          KomsilukPost.create!({
            organization: @organization, author: @author, komsiluk: @area, title: "Objava za pregled",
            body: "Tekst za pregled.", category: "general", origin: "citizen", review_state: "pending"
          }.merge(attributes))
        end

        def decide(action, **options)
          values = { decision: action, reason: "valid", lock_version: @post.reload.lock_version }.merge(options)
          post "/admin/bih/komsiluk-posts/#{@post.id}/decision", params: values
        end
      end
    end
  end
end
