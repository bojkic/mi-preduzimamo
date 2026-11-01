# frozen_string_literal: true

require "test_helper"
require "capybara"

class KomsilukBoardWorkspaceTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers

  setup do
    @organization = create_organization
    host! @organization.host
    @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "workspace-area", name: { "sr" => "Naš komšiluk" })
    @other_area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "workspace-other", name: { "sr" => "Drugi komšiluk" })
    @user = FactoryBot.create(:user, :confirmed, organization: @organization)
    @neighbor = FactoryBot.create(:user, :confirmed, organization: @organization)
    [@user, @neighbor].each do |user|
      Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
      Decidim::Authorization.create!(user:, name: "sms", granted_at: Time.current, unique_id: SecureRandom.uuid)
    end
    sign_in @user
  end

  test "safe composer and separate personal navigation preserve the real feed after invalid input" do
    notice = make_post(author: @neighbor)
    get decidim_bih.komsiluk_board_index_path(view: "mine")
    assert_select "a[href=?]", decidim_bih.komsiluk_board_index_path, text: I18n.t("decidim.bih.komsiluk_board.index.all_categories")
    assert_select "select[name='komsiluk_post[category]'] option[selected][value=general]"
    post decidim_bih.komsiluk_board_index_path, params: { komsiluk_post: { title: "", body: "Preserve this draft", category: "general" } }
    assert_response :unprocessable_entity
    assert_includes response.body, notice.title
    assert_select "textarea[name='komsiluk_post[body]']", text: "Preserve this draft"
    assert_select "details#komsiluk-compose[open]"
  end

  test "pagination exposes record 51 while detail and searches keep membership boundaries" do
    51.times { |index| make_post(author: @neighbor, title: "Notice #{index}", created_at: index.minutes.ago) }
    secret = make_post(author: @neighbor, komsiluk: @other_area, title: "Different area secret")
    get decidim_bih.komsiluk_board_index_path(page: 3)
    assert_response :success
    assert_select ".mi-board-card", count: 11
    get decidim_bih.komsiluk_board_index_path(q: "Different area")
    assert_not_includes response.body, secret.title
    get decidim_bih.komsiluk_board_path(secret)
    assert_response :not_found
    assert_not_includes response.body, secret.title
  end

  test "closed member link explains outcome without revealing retained body but author still has access" do
    notice = make_post(author: @neighbor, status: "closed", body: "Private historical details")
    get decidim_bih.komsiluk_board_path(notice)
    assert_response :success
    assert_not_includes response.body, notice.body
    sign_in @neighbor
    get decidim_bih.komsiluk_board_path(notice)
    assert_includes response.body, notice.body
  end

  test "publication key chooses the current board projection and never another area's content" do
    key = SecureRandom.uuid
    own = make_post(author: nil, origin: "staff", publication_key: key)
    foreign = make_post(author: nil, origin: "staff", publication_key: key, komsiluk: @other_area)
    get decidim_bih.komsiluk_publication_path(key)
    assert_response :success
    assert_includes response.body, own.title
    assert_not_includes response.body, foreign.title
  end

  test "official origin and sources survive long bodies without treating all missing authors as officials" do
    official = make_post(author: nil, origin: "city_service", body: "x" * 1000,
                         details: { "source" => { "provider" => "Water service", "urls" => ["https://example.com/official", "javascript:alert(1)"],
                                                  "scope_label" => "Dio komšiluka" } })
    get decidim_bih.komsiluk_board_path(official)
    assert_select "a[href='https://example.com/official']"
    assert_includes response.body, "Water service"
    assert_not_includes response.body, I18n.t("decidim.bih.komsiluk_board.index.author_deleted")
    assert_no_match(/href="javascript:/, response.body)
    legacy = make_post(author: nil)
    get decidim_bih.komsiluk_board_path(legacy)
    assert_includes response.body, I18n.t("decidim.bih.boards.origins.legacy")
    assert_not_includes response.body, I18n.t("decidim.bih.boards.origins.city_service")
  end

  test "repeated signed publication is one notice and cannot adopt another user's token" do
    get decidim_bih.komsiluk_board_index_path
    token = Nokogiri::HTML(response.body).at_css("input[name='komsiluk_post[publication_token]']")["value"]
    attrs = { komsiluk_post: { title: "One publication", body: "Content", category: "general", publication_token: token } }
    assert_difference("Decidim::Bih::KomsilukPost.count", 1) do
      2.times do
        post decidim_bih.komsiluk_board_index_path, params: attrs
        assert_response :see_other
      end
    end
    sign_in @neighbor
    assert_no_difference("Decidim::Bih::KomsilukPost.count") do
      post decidim_bih.komsiluk_board_index_path, params: attrs
    end
    assert_response :unprocessable_entity
  end

  test "photo draft survives invalid submission and its bytes require the draft owner" do
    upload = fixture_file_upload("chat_photo.jpg", "image/jpeg")
    post decidim_bih.komsiluk_board_index_path, params: { komsiluk_post: { title: "", body: "Photo draft", category: "general", photo: upload } }
    assert_response :unprocessable_entity
    draft = Decidim::Bih::KomsilukPhotoDraft.last
    assert draft.photo.attached?
    token = Nokogiri::HTML(response.body).at_css("input[name='komsiluk_post[photo_draft_token]']")["value"]
    get decidim_bih.komsiluk_draft_photo_path(draft_id: draft.id)
    assert_response :success
    cache_directives = response.headers.fetch("Cache-Control").split(/,\s*/)
    assert_includes cache_directives, "no-store"
    assert_not_includes cache_directives, "public"
    sign_in @neighbor
    get decidim_bih.komsiluk_draft_photo_path(draft_id: draft.id)
    assert_response :not_found
    sign_in @user
    post decidim_bih.komsiluk_board_index_path, params: { komsiluk_post: { title: "With photo", body: "Photo draft", category: "general", photo_draft_token: token } }
    notice = Decidim::Bih::KomsilukPost.order(:id).last
    assert notice.photo.attached?
    assert_not Decidim::Bih::KomsilukPhotoDraft.exists?(draft.id)
    get decidim_bih.komsiluk_board_path(notice)
    assert_select "img[src=?]", decidim_bih.photo_komsiluk_board_path(notice)
    assert_no_match(%r{/rails/active_storage}, response.body.scan(/<img[^>]*class="mi-board-photo"[^>]*>/).join)
  end

  test "help is one reversible explicit offer and a move does not prevent withdrawal" do
    notice = make_post(author: @neighbor, details: { "help_enabled" => true })
    assert_difference("Decidim::Bih::KomsilukHelpResponse.count", 1) do
      2.times { post decidim_bih.help_komsiluk_board_path(notice) }
    end
    Decidim::Bih::CitizenProfile.find_by(user: @user).assign_komsiluk!(@other_area, source: "dropdown")
    post decidim_bih.help_komsiluk_board_path(notice), params: { withdraw: "1" }
    assert notice.help_responses.find_by(user: @user).withdrawn_at.present?
    sign_in @neighbor
    get decidim_bih.komsiluk_board_path(notice)
    assert_not_includes response.body, "@#{@user.nickname}"
  end

  test "expired stored-open notices are archived in personal filters immediately" do
    notice = make_post(author: @user, expires_at: 1.minute.ago)
    get decidim_bih.komsiluk_board_index_path(view: "mine", status: "open")
    assert_not_includes response.body, notice.title
    get decidim_bih.komsiluk_board_index_path(view: "mine", status: "expired")
    assert_includes response.body, notice.title
  end

  test "assignment returns to the requested board while foreign return URLs are refused" do
    user = FactoryBot.create(:user, :confirmed, organization: @organization)
    sign_in user
    get decidim_bih.komsiluk_board_index_path(compose: 1)
    follow_redirect!
    patch decidim_bih.komsiluk_path, params: { komsiluk_id: @area.id, source: "dropdown" }
    assert_redirected_to decidim_bih.komsiluk_board_index_path(compose: 1)
    get decidim_bih.edit_komsiluk_path(return_to: "https://example.com/untrusted")
    patch decidim_bih.komsiluk_path, params: { komsiluk_id: @area.id, source: "dropdown" }
    assert_redirected_to decidim_bih.edit_komsiluk_path
  end

  test "unverified reader receives guidance before being shown an active composer" do
    Decidim::Authorization.where(user: @user, name: "sms").delete_all
    get decidim_bih.komsiluk_board_index_path(compose: 1)
    assert_response :success
    assert_select "#komsiluk-post-form", count: 0
    assert_select "a", text: I18n.t("decidim.bih.boards.verification.action")
  end

  private

  def make_post(**attributes)
    Decidim::Bih::KomsilukPost.create!({ organization: @organization, author: @user, komsiluk: @area, title: "Notice #{SecureRandom.hex(6)}", body: "Member content",
                                         category: "general" }.merge(attributes))
  end
end
