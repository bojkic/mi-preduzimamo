# frozen_string_literal: true

require "test_helper"
require "capybara"

class KomsilukBoardFollowupEdgesTest < ActionDispatch::IntegrationTest
  include ::Devise::Test::IntegrationHelpers

  setup do
    @organization = create_organization
    host! @organization.host
    @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "followup-area", name: { sr: "Naš komšiluk" })
    @other_area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "followup-other", name: { sr: "Drugi komšiluk" })
    @author = FactoryBot.create(:user, :confirmed, organization: @organization)
    @reader = FactoryBot.create(:user, :confirmed, organization: @organization)
    [@author, @reader].each do |user|
      Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
      Decidim::Authorization.create!(user:, name: "sms", granted_at: Time.current, unique_id: SecureRandom.uuid)
    end
    @post = Decidim::Bih::KomsilukPost.create!(organization: @organization, author: @author, komsiluk: @area,
                                               category: "general", origin: "citizen", title: "Private title in the old area",
                                               body: "Private retained content", details: { "help_enabled" => true })
    sign_in @reader
  end

  test "help notification links include the actual public engine mount" do
    notification = nil
    Decidim::EventsManager.stub(:publish, ->(**attributes) { notification = attributes }) do
      post decidim_bih.help_komsiluk_board_path(@post)
    end
    assert_response :redirect
    assert_equal "https://#{@organization.host}/biceriseno/komsiluk-board/#{@post.id}", notification.fetch(:extra).fetch("board_url")
    assert_not_includes notification.fetch(:extra).to_json, @reader.nickname
  end

  test "a moved helper can reach withdrawal without regaining old board content" do
    @post.help_responses.create!(user: @reader)
    Decidim::Bih::CitizenProfile.find_by(user: @reader, organization: @organization).assign_komsiluk!(@other_area, source: "dropdown")
    get decidim_bih.komsiluk_board_path(@post)
    assert_includes [200, 404], response.status
    assert_not_includes response.body, @post.title
    assert_not_includes response.body, @post.body
    assert_select "form[action=?]", decidim_bih.help_komsiluk_board_path(@post) do
      assert_select "input[name=withdraw][value='1']", count: 1
    end
    post decidim_bih.help_komsiluk_board_path(@post), params: { withdraw: "1" }
    assert @post.help_responses.find_by!(user: @reader).withdrawn_at.present?
  end

  test "linked staff source updating blocks direct photo and new help but permits withdrawal" do
    linked = Decidim::Bih::KomsilukPost.create!(
      organization: @organization, komsiluk: @area, origin: "staff", category: "general",
      title: "Approved notice", body: "Reviewed wording", publication_key: SecureRandom.uuid,
      published_at: Time.current, expires_at: 7.days.from_now,
      details: { "help_enabled" => true, "source_record" => { "kind" => "report", "id" => 123 } }
    )
    File.open(file_fixture("chat_photo.jpg")) do |file|
      linked.photo.attach(io: file, filename: "chat_photo.jpg", content_type: "image/jpeg")
    end
    provider = ->(**) { { updating: true, url: nil } }

    Decidim::Bih.stub(:komsiluk_notice_public_source_provider, provider) do
      get decidim_bih.photo_komsiluk_board_path(linked)
      assert_response :not_found
      assert_no_difference("Decidim::Bih::KomsilukHelpResponse.count") do
        post decidim_bih.help_komsiluk_board_path(linked)
      end
      assert_response :not_found

      linked.help_responses.create!(user: @reader)
      post decidim_bih.help_komsiluk_board_path(linked), params: { withdraw: "1" }
      assert_response :see_other
      assert linked.help_responses.find_by!(user: @reader).withdrawn_at.present?
    end
  end

  test "a closed link shares its safe completion outcome without its body" do
    Decidim::Bih::Komsiluk::NoticePublishing.publish!(post: @post)
    receipt = Decidim::Bih::PlatformDelivery.find_by!(komsiluk_post_id: @post.id, decidim_user_id: @reader.id)
    @post.resolve!(by: @author, outcome: "resolved")
    assert receipt.reload.cancelled_at.present?
    get decidim_bih.komsiluk_board_path(@post)
    assert_response :success
    assert_includes response.body, I18n.t("decidim.bih.boards.outcomes.resolved")
    assert_not_includes response.body, @post.body
  end

  test "malformed photo input is a recoverable form error" do
    assert_no_difference("Decidim::Bih::KomsilukPost.count") do
      post decidim_bih.komsiluk_board_index_path,
           params: { komsiluk_post: { title: "Valid draft", body: "Keep my text", category: "general", photo: "not-an-upload" } }
    end
    assert_response :unprocessable_entity
    assert_select "textarea[name='komsiluk_post[body]']", text: "Keep my text"
  end

  test "correction errors preserve every board filter and the deliberate notification choice" do
    sign_in @author
    filters = { view: "mine", cat: "general", origin: "citizen", status: "open", q: "Private", page: "2" }
    patch decidim_bih.komsiluk_board_path(@post), params: filters.merge(
      komsiluk_post: { title: @post.title, body: "", category: "general", content_revision: @post.content_revision, notify: "1" }
    )
    assert_response :unprocessable_entity
    filters.each do |name, value|
      assert_select "#komsiluk-post-form input[name=?][value=?]", name.to_s, value
    end
    assert_select "input[name='komsiluk_post[notify]'][checked]", count: 1
    assert_select "input[name='komsiluk_post[content_revision]'][value='1']", count: 1
    patch decidim_bih.komsiluk_board_path(@post), params: filters.merge(
      komsiluk_post: { title: @post.title, body: "A valid corrected body", category: "general", content_revision: 1, notify: "1" }
    )
    assert_response :see_other
    assert_equal "A valid corrected body", @post.reload.body
    assert_equal 2, @post.content_revision
  end

  test "changing area from the board carries a safe return destination" do
    get decidim_bih.komsiluk_board_index_path
    assert_select "a[href=?]", decidim_bih.edit_komsiluk_path(return_to: decidim_bih.komsiluk_board_index_path)
  end

  test "private notice context is absent for unavailable author history" do
    sign_in @author
    contexts = []
    provider = Object.new
    provider.define_singleton_method(:call) do |**attributes|
      contexts << attributes.fetch(:post)
      []
    end
    Decidim::Bih.stub(:komsiluk_board_context_provider, -> { provider }) do
      get decidim_bih.komsiluk_board_path(@post)
      assert_equal @post.id, contexts.last.id
      @post.update!(status: "hidden")
      get decidim_bih.komsiluk_board_path(@post)
      assert_nil contexts.last
      @post.update!(status: "open")
      Decidim::Bih::CitizenProfile.find_by(user: @author, organization: @organization).assign_komsiluk!(@other_area, source: "dropdown")
      get decidim_bih.komsiluk_board_path(@post)
      assert_nil contexts.last
    end
    assert_equal 3, contexts.size
  end

  test "automatic hiding cancels captured work even if moderation restores before delivery executes" do
    Decidim::Bih::Komsiluk::NoticePublishing.publish!(post: @post)
    receipt = Decidim::Bih::PlatformDelivery.find_by!(komsiluk_post_id: @post.id, decidim_user_id: @reader.id)
    3.times do
      reporter = FactoryBot.create(:user, :confirmed, organization: @organization)
      @post.flag!(reporter)
    end
    assert_equal "hidden", @post.reload.status
    assert receipt.reload.cancelled_at.present?
    admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    Decidim::Bih::Komsiluk::PostModeration.new(post: @post, actor: admin, organization: @organization)
                                          .call(action: "restore", reason: "valid", expected_version: @post.lock_version)
    assert_equal "open", @post.reload.status
    assert_no_difference("Decidim::Notification.count") do
      Decidim::Bih::KomsilukNoticeDeliveryJob.perform_now(receipt.id)
    end
    assert receipt.reload.cancelled_at.present?
    assert_nil receipt.inbox_created_at
  end
end
