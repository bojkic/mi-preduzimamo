# frozen_string_literal: true

require "test_helper"
require "capybara"

class KomsilukBoardControllerTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers

  setup do
    @organization = create_organization
    host! @organization.host

    @mz = Decidim::Bih::LocalArea.create!(
      organization: @organization, kind: "mz", slug: "mz-board",
      name: { "sr" => "Test MZ", "en" => "Test MZ" }
    )
    @komsiluk = Decidim::Bih::LocalArea.create!(
      organization: @organization, kind: "komsiluk", slug: "komsiluk-board",
      name: { "sr" => "Test Komšiluk", "en" => "Test Neighbourhood" },
      parent: @mz
    )
    @other_mz = Decidim::Bih::LocalArea.create!(
      organization: @organization, kind: "mz", slug: "mz-other-board",
      name: { "sr" => "Other MZ" }
    )
    @other_komsiluk = Decidim::Bih::LocalArea.create!(
      organization: @organization, kind: "komsiluk", slug: "komsiluk-other-board",
      name: { "sr" => "Other Komšiluk" },
      parent: @other_mz
    )

    @user = FactoryBot.create(:user, :confirmed, organization: @organization)
    @other_user = FactoryBot.create(:user, :confirmed, organization: @organization)

    # Assign @user to @komsiluk
    @profile = Decidim::Bih::CitizenProfile.for_user(@user, organization: @organization)
    @profile.assign_komsiluk!(@komsiluk, source: "dropdown")

    # Assign @other_user to @other_komsiluk
    @other_profile = Decidim::Bih::CitizenProfile.for_user(@other_user, organization: @organization)
    @other_profile.assign_komsiluk!(@other_komsiluk, source: "dropdown")

    # Grant sms authorization to @user
    grant_sms_auth(@user)
    grant_sms_auth(@other_user)
  end

  # ── PRIVACY: nickname not name ────────────────────────────────────────────

  test "board page renders @nickname, not author full name" do
    # Create author with a distinct name vs nickname so we can tell them apart.
    author = FactoryBot.create(:user, :confirmed,
                               organization: @organization,
                               name: "Full Real Name",
                               nickname: "board_author_nick")
    author_profile = Decidim::Bih::CitizenProfile.for_user(author, organization: @organization)
    author_profile.assign_komsiluk!(@komsiluk, source: "dropdown")
    grant_sms_auth(author)

    create_post(author: author, komsiluk: @komsiluk)

    sign_in @user
    get "/biceriseno/komsiluk-board"
    assert_response :success
    assert_includes response.body, "@board_author_nick"
    assert_not_includes response.body, "Full Real Name"
  end

  # ── READ GATE ─────────────────────────────────────────────────────────────

  test "GET /biceriseno/komsiluk-board redirects to login when not signed in" do
    get "/biceriseno/komsiluk-board"
    assert_response :redirect
    assert_redirected_to %r{/users/sign_in}
  end

  test "GET /biceriseno/komsiluk-board redirects to picker when user has no komsiluk" do
    unassigned = FactoryBot.create(:user, :confirmed, organization: @organization)
    sign_in unassigned
    get "/biceriseno/komsiluk-board"
    assert_redirected_to %r{/biceriseno/komsiluk}
  end

  test "GET /biceriseno/komsiluk-board renders board for assigned user" do
    sign_in @user
    get "/biceriseno/komsiluk-board"
    assert_response :success
  end

  test "index author queries stay constant as the visible feed grows" do
    add_board_authors(5)
    sign_in @user
    get "/biceriseno/komsiluk-board" # Complete sign-in bookkeeping before measuring.
    small_feed_queries = board_user_query_count
    assert_select ".mi-board-card", count: 5

    add_board_authors(10)
    large_feed_queries = board_user_query_count
    assert_select ".mi-board-card", count: 15

    assert_operator large_feed_queries, :<=, small_feed_queries,
                    "user queries grew from #{small_feed_queries} for 5 posts to #{large_feed_queries} for 15 distinct authors"
  end

  # ── CROSS-KOMŠILUK ISOLATION ──────────────────────────────────────────────

  test "user only sees posts from their own komsiluk" do
    my_post = create_post(author: @user, komsiluk: @komsiluk)
    other_post = create_post(author: @other_user, komsiluk: @other_komsiluk)

    sign_in @user
    get "/biceriseno/komsiluk-board"
    assert_response :success
    assert_includes response.body, my_post.title
    assert_not_includes response.body, other_post.title
  end

  test "my posts keeps prior-neighbourhood posts manageable after reassignment" do
    prior_post = create_post(author: @user, komsiluk: @komsiluk)
    @profile.assign_komsiluk!(@other_komsiluk, source: "dropdown")
    sign_in @user

    get "/biceriseno/komsiluk-board"
    assert_response :success
    assert_not_includes response.body, prior_post.title

    get "/biceriseno/komsiluk-board", params: { view: "mine" }
    assert_response :success
    assert_includes response.body, prior_post.title
    assert_includes response.body, @komsiluk.translated_name

    patch "/biceriseno/komsiluk-board/#{prior_post.id}/zatvori", params: { view: "mine" }
    assert_redirected_to "/biceriseno/komsiluk-board?view=mine"
    assert_equal "closed", prior_post.reload.status
  end

  test "my posts never exposes another citizen or tenant" do
    own = create_post(author: @user, komsiluk: @komsiluk)
    other = create_post(author: @other_user, komsiluk: @other_komsiluk)
    foreign = create_foreign_post
    sign_in @user

    get "/biceriseno/komsiluk-board", params: { view: "mine" }

    assert_response :success
    assert_includes response.body, own.title
    assert_not_includes response.body, other.title
    assert_not_includes response.body, foreign.title
  end

  test "user in different org cannot access another org's board" do
    other_org = create_organization
    other_user = FactoryBot.create(:user, :confirmed, organization: other_org)
    sign_in other_user
    host! other_org.host
    get "/biceriseno/komsiluk-board"
    # Redirected to picker because no komsiluk assigned
    assert_response :redirect
  end

  # ── WRITE GATE ───────────────────────────────────────────────────────────

  test "POST requires sms authorization" do
    unverified = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.for_user(unverified, organization: @organization)
    profile.assign_komsiluk!(@komsiluk, source: "dropdown")

    sign_in unverified
    post "/biceriseno/komsiluk-board", params: {
      komsiluk_post: { category: "general", title: "Hi", body: "Hello" }
    }
    assert_response :redirect
    # Redirected toward phone login, not the board
    assert_not_equal decidim_bih.komsiluk_board_index_path, response.location
  end

  test "POST by logged-in-but-unverified user redirects to verification, not phone login" do
    unverified = FactoryBot.create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.for_user(unverified, organization: @organization)
    profile.assign_komsiluk!(@komsiluk, source: "dropdown")

    sign_in unverified
    post "/biceriseno/komsiluk-board", params: {
      komsiluk_post: { category: "general", title: "Hi", body: "Hello" }
    }
    # A logged-in user must be sent to the SMS verification flow, NOT the
    # passwordless login form (a dead-end since they're already signed in).
    assert_redirected_to decidim_verifications.authorizations_path(redirect_url: decidim_bih.komsiluk_board_index_path(compose: 1))
    assert_no_match %r{/phone}, response.location
  end

  test "POST creates a post when gated properly" do
    sign_in @user
    assert_difference("Decidim::Bih::KomsilukPost.count", 1) do
      post "/biceriseno/komsiluk-board", params: {
        komsiluk_post: { category: "general", title: "New post", body: "Body text" }
      }
    end
    assert_response :redirect
  end

  test "invalid POST preserves entered values and shows actionable errors" do
    sign_in @user

    assert_no_difference("Decidim::Bih::KomsilukPost.count") do
      post "/biceriseno/komsiluk-board", params: {
        komsiluk_post: { category: "safety", title: "", body: "Tekst koji građanin ne treba ponovo pisati" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Objava nije sačuvana/
    assert_select "select[name='komsiluk_post[category]'] option[selected][value=safety]"
    assert_select "textarea[name='komsiluk_post[body]']", text: "Tekst koji građanin ne treba ponovo pisati"
    assert_select "#komsiluk-post-limits"
  end

  test "POST by signed-in user from another organization is treated as anonymous and creates nothing" do
    outsider = create_other_org_assigned_user
    sign_in outsider

    assert_no_difference("Decidim::Bih::Goodwill::Transaction.count") do
      assert_no_difference("Decidim::Bih::KomsilukPost.count") do
        post "/biceriseno/komsiluk-board", params: {
          komsiluk_post: { category: "general", title: "Cross-org", body: "Should not persist" }
        }
      end
    end

    assert_redirected_to %r{/users/sign_in}
  end

  # ── POINTS ────────────────────────────────────────────────────────────────

  test "creating a post awards komsiluk_post points once" do
    sign_in @user
    assert_difference("Decidim::Bih::Goodwill::Transaction.count", 1) do
      post "/biceriseno/komsiluk-board", params: {
        komsiluk_post: { category: "general", title: "Points test", body: "Body" }
      }
    end
    # Idempotency: same post id won't award again
    new_post_id = Decidim::Bih::KomsilukPost.last.id
    rules = Decidim::Bih::Goodwill::EarningRules.new
    result = rules.award(@user, :komsiluk_post, idempotency_key: "komsiluk_post:#{new_post_id}")
    assert_nil result # already awarded
  end

  test "daily cap limits komsiluk_post awards to 3 per day" do
    sign_in @user
    cap = Decidim::Bih::Goodwill::EarningRules::DEFAULT_DAILY_CAPS[:komsiluk_post]
    assert_equal 3, cap

    rules = Decidim::Bih::Goodwill::EarningRules.new
    cap.times do |i|
      result = rules.award(@user, :komsiluk_post, idempotency_key: "komsiluk_post:cap_test_#{i}")
      assert_not_nil result, "expected award #{i + 1} to succeed"
    end
    # 4th award should be capped
    result = rules.award(@user, :komsiluk_post, idempotency_key: "komsiluk_post:cap_test_overflow")
    assert_nil result
  end

  # ── DAILY LIMIT (shared create path) ──────────────────────────────────────

  # T9: the web path now routes through Decidim::Bih::Komsiluk::PostCreator, so
  # it inherits the per-citizen daily cap (previously only Rack::Attack bounded
  # the web). A post beyond the cap is refused with a friendly flash and no new
  # row, instead of silently creating posts 4–5 that earn nothing.
  test "POST beyond the daily limit is refused with a friendly flash" do
    sign_in @user
    limit = Decidim::Bih::Komsiluk::PostCreator::DAILY_LIMIT

    limit.times do |i|
      post "/biceriseno/komsiluk-board", params: {
        komsiluk_post: { category: "general", title: "Objava #{i}", body: "Tekst #{i}" }
      }
    end
    assert_equal limit, Decidim::Bih::KomsilukPost.where(decidim_user_id: @user.id).count

    assert_no_difference("Decidim::Bih::KomsilukPost.count") do
      post "/biceriseno/komsiluk-board", params: {
        komsiluk_post: { category: "general", title: "Preko limita", body: "jos jedna" }
      }
    end
    # Refused in-place with a validation response and preserved input.
    assert_response :unprocessable_entity
    assert flash.now[:alert].present?, "expected a friendly refusal flash"
    # The flash must be the dedicated daily-cap message ("try again tomorrow"),
    # not the generic validation failure ("check your input").
    rate_limited_msg = I18n.t("decidim.bih.komsiluk_board.create.rate_limited")
    failed_msg = I18n.t("decidim.bih.komsiluk_board.create.failed")
    assert_equal rate_limited_msg, flash.now[:alert]
    assert_includes response.body, rate_limited_msg
    assert_not_includes response.body, failed_msg
  end

  # ── PII-SAFE EXCEPTION LOGGING (shared create path) ───────────────────────

  # T9 hardening: the create path no longer does raw `logger.error(e)`. When the
  # points award raises, PostCreator logs the message through LogRedactor, so a
  # phone number / token in the exception is masked rather than leaked.
  test "a points-award failure is logged redacted, never as a raw exception" do
    sign_in @user

    rules = Decidim::Bih::Goodwill::EarningRules.new
    boom = RuntimeError.new("ledger blew up for token=topsecret phone 38765111000")
    Decidim::Bih::Goodwill::EarningRules.stub(:new, rules) do
      rules.stub(:award, ->(*) { raise boom }) do
        logs = capture_logs do
          post "/biceriseno/komsiluk-board", params: {
            komsiluk_post: { category: "general", title: "Naslov", body: "Tijelo objave" }
          }
        end

        # The award failure is non-fatal: the post is still created + redirect.
        assert_response :redirect
        assert_equal 1, Decidim::Bih::KomsilukPost.where(decidim_user_id: @user.id).count

        # Raw secret / full phone must NOT appear; redacted forms must.
        assert_not_includes logs, "token=topsecret"
        assert_not_includes logs, "38765111000"
        assert_includes logs, "token=[REDACTED]"
        assert_includes logs, "[phone:***1000]"
      end
    end
  end

  # ── FLAG ─────────────────────────────────────────────────────────────────

  test "author cannot flag their own post" do
    post_obj = create_post(author: @user, komsiluk: @komsiluk)
    sign_in @user
    post "/biceriseno/komsiluk-board/#{post_obj.id}/prijavi"
    assert_equal 0, post_obj.reload.flagged_count
    assert_redirected_to decidim_bih.komsiluk_board_index_path
  end

  test "POST prijavi flags a post once per user" do
    post_obj = create_post(author: @user, komsiluk: @komsiluk)
    sign_in @other_user
    # @other_user is in @other_komsiluk — not in @komsiluk. Give them the right profile.
    @other_profile.assign_komsiluk!(@komsiluk, source: "dropdown")

    post "/biceriseno/komsiluk-board/#{post_obj.id}/prijavi"
    assert_equal 1, post_obj.reload.flagged_count

    # Flagging again should be idempotent
    post "/biceriseno/komsiluk-board/#{post_obj.id}/prijavi"
    assert_equal 1, post_obj.reload.flagged_count
  end

  test "POST prijavi by signed-in user from another organization is treated as anonymous" do
    post_obj = create_post(author: @user, komsiluk: @komsiluk)
    outsider = create_other_org_assigned_user
    sign_in outsider

    assert_no_difference("Decidim::Bih::KomsilukPostFlag.count") do
      assert_no_difference -> { post_obj.reload.flagged_count } do
        post "/biceriseno/komsiluk-board/#{post_obj.id}/prijavi"
      end
    end

    assert_redirected_to %r{/users/sign_in}
  end

  test "auto-hide at FLAG_HIDE_THRESHOLD" do
    post_obj = create_post(author: @user, komsiluk: @komsiluk)
    threshold = Decidim::Bih::KomsilukPost::FLAG_HIDE_THRESHOLD

    # Flag from threshold distinct users
    flagger_users = (1..threshold).map do
      u = FactoryBot.create(:user, :confirmed, organization: @organization)
      p = Decidim::Bih::CitizenProfile.for_user(u, organization: @organization)
      p.assign_komsiluk!(@komsiluk, source: "dropdown")
      grant_sms_auth(u)
      u
    end

    flagger_users.each do |u|
      sign_in u
      post "/biceriseno/komsiluk-board/#{post_obj.id}/prijavi"
    end

    assert_equal "hidden", post_obj.reload.status
  end

  # ── EXPIRES_AT LOCKDOWN ───────────────────────────────────────────────────

  test "out-of-range expiry is rejected without publishing or losing the draft" do
    sign_in @user
    far_future = 999.days.from_now.iso8601
    assert_no_difference("Decidim::Bih::KomsilukPost.count") do
      post "/biceriseno/komsiluk-board", params: {
        komsiluk_post: { category: "lost_pet", title: "Lost cat", body: "Seen near park", expires_at: far_future }
      }
    end
    assert_response :unprocessable_entity
    assert_select "textarea[name='komsiluk_post[body]']", text: "Seen near park"
    assert_includes response.body, I18n.t("decidim.bih.boards.errors.expiry")
  end

  # ── CLOSE (zatvori) ───────────────────────────────────────────────────────

  test "PATCH zatvori closes author's own post" do
    post_obj = create_post(author: @user, komsiluk: @komsiluk)
    sign_in @user
    patch "/biceriseno/komsiluk-board/#{post_obj.id}/zatvori"
    assert_equal "closed", post_obj.reload.status
  end

  test "PATCH zatvori rejects non-author" do
    post_obj = create_post(author: @user, komsiluk: @komsiluk)
    # Use a user in the same komsiluk
    same_k_user = FactoryBot.create(:user, :confirmed, organization: @organization)
    p = Decidim::Bih::CitizenProfile.for_user(same_k_user, organization: @organization)
    p.assign_komsiluk!(@komsiluk, source: "dropdown")
    grant_sms_auth(same_k_user)

    sign_in same_k_user
    patch "/biceriseno/komsiluk-board/#{post_obj.id}/zatvori"
    assert_equal "open", post_obj.reload.status
  end

  test "PATCH zatvori by signed-in user from another organization is treated as anonymous" do
    post_obj = create_post(author: @user, komsiluk: @komsiluk)
    outsider = create_other_org_assigned_user
    sign_in outsider

    patch "/biceriseno/komsiluk-board/#{post_obj.id}/zatvori"

    assert_equal "open", post_obj.reload.status
    assert_redirected_to %r{/users/sign_in}
  end

  private

  def add_board_authors(count)
    count.times do
      author = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "nbplus#{SecureRandom.hex(6)}")
      create_post(author:, komsiluk: @komsiluk)
    end
  end

  def board_user_query_count
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 if payload[:sql].to_s.match?(/FROM\s+"?decidim_users"?/i) && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/biceriseno/komsiluk-board" }
    assert_response :success
    count
  end

  def create_other_org_assigned_user
    other_org = create_organization
    other_mz = Decidim::Bih::LocalArea.create!(
      organization: other_org, kind: "mz", slug: "mz-board-other-#{SecureRandom.hex(4)}",
      name: { "sr" => "Druga MZ" }
    )
    other_komsiluk = Decidim::Bih::LocalArea.create!(
      organization: other_org, kind: "komsiluk", slug: "komsiluk-board-other-#{SecureRandom.hex(4)}",
      name: { "sr" => "Drugi Komšiluk" },
      parent: other_mz
    )
    outsider = FactoryBot.create(:user, :confirmed, organization: other_org)
    Decidim::Bih::CitizenProfile
      .for_user(outsider, organization: other_org)
      .assign_komsiluk!(other_komsiluk, source: "dropdown")
    grant_sms_auth(outsider)
    outsider
  end

  def create_foreign_post
    other_org = create_organization
    author = FactoryBot.create(:user, :confirmed, organization: other_org)
    mz = Decidim::Bih::LocalArea.create!(
      organization: other_org, kind: "mz", slug: "foreign-mz-#{SecureRandom.hex(4)}", name: { "sr" => "Strana MZ" }
    )
    area = Decidim::Bih::LocalArea.create!(
      organization: other_org, kind: "komsiluk", slug: "foreign-area-#{SecureRandom.hex(4)}",
      name: { "sr" => "Strani komšiluk" }, parent: mz
    )
    Decidim::Bih::KomsilukPost.create!(
      organization: other_org, author:, komsiluk: area, category: "general",
      title: "Foreign #{SecureRandom.hex(4)}", body: "Not visible"
    )
  end

  def create_post(author:, komsiluk:, **attrs)
    Decidim::Bih::KomsilukPost.create!({
      organization: @organization,
      author: author,
      komsiluk: komsiluk,
      category: "general",
      title: "Test post #{SecureRandom.hex(4)}",
      body: "Test body"
    }.merge(attrs))
  end

  def capture_logs
    io = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original_logger
  end

  def grant_sms_auth(user)
    Decidim::Authorization.find_or_initialize_by(user: user, name: "sms").tap do |auth|
      auth.granted_at = Time.current
      auth.save!
    end
  end

  def decidim_bih
    Decidim::Bih::Engine.routes.url_helpers
  end

  def decidim_verifications
    Decidim::Verifications::Engine.routes.url_helpers
  end
end
