# frozen_string_literal: true

require "test_helper"
require "support/route_smoke_helpers"
require "decidim/proposals/test/factories"

class HomepagePublicActivityTest < ActionDispatch::IntegrationTest
  include RouteSmokeHelpers

  setup do
    setup_smoke_organization!
    create(:content_block, organization: @organization, scope_name: :homepage, manifest_name: :mi_hero)
  end

  test "homepage includes reports opportunities verified organizations and public notices" do
    report = Decidim::Bih::Report.create!(organization: @organization, status: "u_obradi",
                                          description: "PRIVATE REPORT DESCRIPTION", reporter_email: "private@example.org",
                                          reporter_phone: "+38765123456", internal_note: "PRIVATE INTERNAL NOTE")
    profile = partner
    opportunity = opportunity(title: "Pomoć zajednici")
    notice = profile.notices.create!(organization: @organization, title: "Javno obavještenje", body: "Public notice body")

    get "/"

    assert_response :success
    assert_select ".mi-ticker:not(.mi-hide-sm)" do
      assert_select ".mi-ticker__label", text: I18n.t("decidim.bih.homepage_activity.title", locale: :sr)
      assert_select "a[href=?]", "/biceriseno/prijave/#{report.reference}", text: /#{report.reference}/
      assert_select "a[href=?]", "/biceriseno/volontiranje#volunteer-opportunity-#{opportunity.id}", text: opportunity.title
      assert_select "a[href=?]", "/biceriseno/organizacija/#{profile.slug}", text: profile.display_name
      assert_select "a[href=?]", "/biceriseno/organizacija/#{profile.slug}#obavjestenja-organizacije", text: notice.title
    end
    [report.description, report.reporter_email, report.reporter_phone, report.internal_note, report.status_token].each do |secret|
      assert_not_includes response.body, secret
    end

    targets = css_select(".mi-ticker a").map { |link| link["href"] }
    targets.each do |target|
      path, anchor = target.split("#", 2)
      get path
      assert_response :success, "Homepage activity destination failed: #{target}"
      assert_select "[id=?]", anchor if anchor
    end
  end

  test "draft rejected suspended expired cancelled and other tenant content never appears" do
    other = create_organization
    Decidim::Bih::Report.create!(organization: other, description: "Other report")
    other_profile = partner(organization: other, display_name: "Other tenant", slug: "other")
    other_profile.notices.create!(organization: other, title: "Other notice", body: "Not ours")
    %w(draft submitted rejected suspended).each do |status|
      partner(verification_status: status, slug: status, display_name: "Hidden #{status}")
    end
    profile = partner
    profile.notices.create!(organization: @organization, title: "Expired notice", body: "Expired", expires_at: 1.day.ago)
    profile.notices.create!(organization: @organization, title: "Future notice", body: "Future", published_at: 1.day.from_now)
    opportunity(title: "Other opportunity", organization: other)
    opportunity(title: "Pending opportunity", active: false, review_status: "pending")
    opportunity(title: "Rejected opportunity", active: false, review_status: "rejected")
    opportunity(title: "Cancelled opportunity", cancelled_at: Time.current)
    opportunity(title: "Ended opportunity", starts_at: 2.days.ago, ends_at: 1.day.ago)
    opportunity(title: "Closed opportunity", starts_at: 1.day.from_now, signup_deadline_at: 1.hour.ago)
    hidden_profile = partner(slug: "suspended-later")
    hidden_profile.notices.create!(organization: @organization, title: "Suspended notice", body: "Hidden")
    opportunity(title: "Suspended opportunity", partner_profile: hidden_profile)
    hidden_profile.suspend!

    entries = Decidim::Bih::HomepageActivity.new(@organization).call
    assert_equal [:organization], entries.map(&:kind)
    assert_equal [profile.display_name], entries.map(&:title)
  end

  test "a batch of opportunities leaves room for reports and notices and ordering is deterministic" do
    report = Decidim::Bih::Report.create!(organization: @organization, description: "Private", created_at: 2.days.ago)
    profile = partner(verified_at: 3.days.ago)
    profile.notices.create!(organization: @organization, title: "Važna objava", body: "Public", published_at: 1.day.ago)
    8.times { |n| opportunity(title: "Prilika #{n}") }

    get "/"
    assert_select ".mi-ticker__item", count: 6
    assert_select ".mi-ticker a[href=?]", "/biceriseno/prijave/#{report.reference}"
    assert_select ".mi-ticker a", text: "Važna objava"
    first = css_select(".mi-ticker").first.to_html
    get "/"
    assert_equal first, css_select(".mi-ticker").first.to_html
  end

  test "Komšiluk content is absent for guests and members and never queried" do
    user = create(:user, :confirmed, organization: @organization)
    area = Decidim::Bih::LocalArea.create!(organization: @organization, name: { sr: "Naselje" },
                                           slug: "naselje", kind: "komsiluk")
    Decidim::Bih::CitizenProfile.create!(organization: @organization, user:, komsiluk: area)
    Decidim::Bih::KomsilukPost.create!(organization: @organization, author: user, komsiluk: area,
                                       title: "PRIVATE NEIGHBORHOOD TITLE", body: "PRIVATE NEIGHBORHOOD BODY", category: "general")
    opportunity(title: "Javna prilika")
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      Decidim::Bih::HomepageActivity.new(@organization).call
    end
    assert(queries.none? { |sql| sql.include?("decidim_bih_komsiluk_posts") })
    get "/"
    guest = css_select(".mi-ticker").first.to_html
    sign_in user
    get "/"
    assert_equal guest, css_select(".mi-ticker").first.to_html
    assert_not_includes response.body, "PRIVATE NEIGHBORHOOD"
  end

  test "withdrawing public eligibility removes entries on the next request" do
    profile = partner
    opportunity = opportunity(title: "Only public while approved", partner_profile: profile)
    notice = profile.notices.create!(organization: @organization, title: "Public while verified", body: "Body")
    get "/"
    assert_select ".mi-ticker a", text: opportunity.title
    assert_select ".mi-ticker a", text: notice.title
    profile.suspend!
    get "/"
    assert_select ".mi-ticker", count: 0
  end

  test "public titles are escaped and supported locales render without missing keys" do
    opportunity(title: "<script>alert(1)</script>")
    [:sr, :bs, :hr, :en, :"sr-Cyrl"].each do |locale|
      I18n.with_locale(locale) do
        entries = Decidim::Bih::HomepageActivity.new(@organization).call
        assert_equal 1, entries.size
        %w(title kinds.report kinds.volunteering kinds.organization kinds.notice report_title).each do |key|
          assert I18n.exists?("decidim.bih.homepage_activity.#{key}", locale)
        end
      end
    end
    get "/"
    assert_select ".mi-ticker script", count: 0
    assert_select ".mi-ticker a", text: "<script>alert(1)</script>"
  end

  test "private participation activity stays off the homepage even for an authorized member" do
    actor = create(:user, :confirmed, organization: @organization)
    process = create(:participatory_process, :published, organization: @organization, private_space: true)
    create(:participatory_space_private_user, user: actor, privatable_to: process)
    component = create(:proposal_component, participatory_space: process)
    proposal = create(:proposal, component:, published_at: Time.current)
    create(:action_log, user: actor, organization: @organization, action: "publish", visibility: "public-only",
                        resource: proposal, component:, participatory_space: process)
    sign_in actor
    get "/"
    assert_response :success
    assert_select ".mi-ticker", count: 0
  end

  test "a source failure preserves other public activity" do
    opportunity(title: "Still available")
    Decidim::Bih::Report.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "PRIVATE ERROR DETAIL" }) do
      entries = Decidim::Bih::HomepageActivity.new(@organization).call
      assert_equal ["Still available"], entries.map(&:title)
    end
  end

  private

  def partner(**attributes)
    Decidim::Bih::PartnerProfile.create!({ organization: @organization, display_name: "Udruženje građana",
                                           slug: "udruzenje", kind: "association", verification_status: "verified",
                                           verified_at: Time.current }.merge(attributes))
  end

  def opportunity(**attributes)
    Decidim::Bih::VolunteerOpportunity.create!({ organization: @organization, title: "Javna prilika",
                                                 active: true, review_status: "approved" }.merge(attributes))
  end
end
