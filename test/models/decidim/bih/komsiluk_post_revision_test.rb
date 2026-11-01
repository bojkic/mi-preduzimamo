# frozen_string_literal: true

require "test_helper"

class KomsilukPostRevisionTest < ActiveSupport::TestCase
  setup do
    @organization = create_organization
    @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "revision-area", name: { "sr" => "Test" })
    @user = FactoryBot.create(:user, :confirmed, organization: @organization)
    @post = Decidim::Bih::KomsilukPost.create!(organization: @organization, author: @user, komsiluk: @area, category: "general", title: "Before", body: "Private before",
                                               origin: "citizen", published_at: 1.hour.ago)
  end

  test "minor correction records a private revision without a delivery and rejects a stale form" do
    published_at = @post.published_at
    Decidim::Bih::Komsiluk::NoticePublishing.stub(:publish!, ->(**) { flunk "minor edit must not notify" }) do
      @post.correct!(by: @user, attributes: { body: "Private after" }, expected_revision: 1)
    end
    assert_equal 2, @post.content_revision
    assert_equal "Private before", @post.revisions.sole.snapshot["body"]
    assert_equal published_at, @post.published_at
    assert_raises(Decidim::Bih::KomsilukPost::StaleRevision) do
      @post.correct!(by: @user, attributes: { body: "Stale overwrite" }, expected_revision: 1)
    end
    assert_equal "Private after", @post.reload.body
  end

  test "hidden author correction requests review and cannot republish" do
    @post.update!(status: "hidden", review_state: "reviewed")
    Decidim::Bih::Komsiluk::NoticePublishing.stub(:publish!, ->(**) { flunk "hidden notice cannot notify" }) do
      @post.correct!(by: @user, attributes: { body: "Corrected" }, expected_revision: 1, notify: true)
    end
    assert_equal "hidden", @post.reload.status
    assert_equal "pending", @post.review_state
  end

  test "trusted source correction preserves hidden placement and optional system actor" do
    @post.update!(author: nil, origin: "city_service", status: "hidden", details: { "moderation" => { "source_hold" => true } })
    @post.correct!(by: nil, attributes: { body: "Source correction", status: "open", details: { "source" => { "provider" => "City" } } }, expected_revision: 1)
    assert_equal "hidden", @post.reload.status
    assert @post.details.dig("moderation", "source_hold")
    assert_nil @post.revisions.sole.actor
  end

  test "reviewed historic flags do not immediately auto-hide when one new person flags" do
    @post.update!(flagged_count: 3, review_state: "reviewed", details: { "moderation" => { "reviewed_flag_count" => 3 } })
    other = FactoryBot.create(:user, :confirmed, organization: @organization)
    assert_equal :flagged, @post.flag!(other)
    assert_equal "open", @post.reload.status
    assert_equal "pending", @post.review_state
    assert_equal 4, @post.flagged_count
  end

  test "retention removes revisions responses and structured private content" do
    @post.correct!(by: @user, attributes: { body: "After" }, expected_revision: 1)
    @post.update!(status: "closed", body: nil)
    @post.purge_private_history!
    assert_empty @post.revisions
    assert_empty @post.details
    assert @post.valid?
  end
end
