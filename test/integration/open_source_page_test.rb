# frozen_string_literal: true

require "test_helper"
require "capybara"

class OpenSourcePageTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_organization
    host! @organization.host
    @keys = %w(MI_OPEN_SOURCE_PUBLISHED MI_OPEN_SOURCE_APP_URL MI_OPEN_SOURCE_ENGINE_URL)
    @saved = @keys.index_with { |key| ENV.fetch(key, nil) }
    @keys.each { |key| ENV.delete(key) }
  end

  teardown do
    @saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  test "draft page explains services and does not claim published repositories in every locale" do
    %w(sr sr-Cyrl bs hr).each do |locale|
      get "/otvoreni-kod", params: { locale: locale }
      assert_response :success
      assert_select "article[lang='#{locale == "sr" ? "sr-Latn" : locale}'] h1", text: I18n.t("mi_open_source.title", locale: locale)
      assert_select "h2", text: I18n.t("mi_open_source.draft_title", locale: locale)
      assert_select "article a[href^='https://github.com/']", count: 0
      assert_select "a[href^='mailto:office@fondacijabijeljina.com']"
      assert_select "footer a", text: I18n.t("mi_open_source.footer_link", locale: locale) do |links|
        assert_equal "/otvoreni-kod", URI.parse(links.first["href"]).path
      end
    end
  end

  test "content and footer are translated explicitly in all four platform locales" do
    %w(sr sr-Cyrl bs hr).each do |locale|
      %w(title intro freedoms_title freedoms self_title self_intro app_link engine_link installation_link installation_status versions draft_title draft steps_title steps requirements services_title services contact contact_subject contribute_title contribute_intro contribute_after footer_link).each do |key|
        assert I18n.exists?("mi_open_source.#{key}", locale, fallback: false), "Missing #{locale}: #{key}"
      end
      get "/otvoreni-kod", params: { locale: locale }
      assert_select "#mi-footer-language-form[action='/locale'][method='post']", count: 1
      assert_select "#mi-footer-language option", count: 4
      assert_select "#mi-footer-language option[selected][value='#{locale}']", count: 1
      assert_select "#mi-footer-language-form [type='submit']", count: 1 do |buttons|
        assert_equal I18n.t("mi_footer.apply_language", locale: locale), buttons.first["value"].presence || buttons.first.text.strip
      end
      assert_select "#mi-footer-language-form svg", count: 0
      assert_select ".translation_missing", count: 0
    end
    get "/otvoreni-kod", params: { locale: "sr-Cyrl" }
    assert_select "h1", text: "Покрените MI preduzimamo у својој заједници"
    assert_select "footer a", text: "Отворени код"
    get "/otvoreni-kod", params: { locale: "hr" }
    assert_includes response.body, "platforma za sudjelovanje građana"
  end

  test "footer locale submissions retain the current adoption page" do
    %w(sr sr-Cyrl bs hr).each do |locale|
      get "/otvoreni-kod", params: { locale: "sr" }
      post "/locale", params: { locale: locale }, headers: { "HTTP_REFERER" => "http://#{@organization.host}/otvoreni-kod?locale=sr" }
      assert_response :redirect
      target = URI.parse(response.location)
      assert_equal "/otvoreni-kod", target.path
      assert_equal locale, Rack::Utils.parse_nested_query(target.query)["locale"]
      follow_redirect!
      assert_response :success
      assert_select "h1", text: I18n.t("mi_open_source.title", locale: locale)
    end
  end

  test "language selection preserves BIH routes and delegates core routes" do
    post "/locale", params: { locale: "hr" }, headers: { "HTTP_REFERER" => "http://#{@organization.host}/biceriseno/prijave/new?locale=sr" }
    assert_response :redirect
    assert_equal "/biceriseno/prijave/new", URI.parse(response.location).path
    assert_equal "hr", Rack::Utils.parse_nested_query(URI.parse(response.location).query)["locale"]
    follow_redirect!
    assert_response :success

    post "/locale", params: { locale: "bs" }, headers: { "HTTP_REFERER" => "http://#{@organization.host}/sr/" }
    assert_response :redirect
    assert_equal "/bs", URI.parse(response.location).path.delete_suffix("/")
  end

  test "language selection never redirects to an external referer" do
    post "/locale", params: { locale: "hr" }, headers: { "HTTP_REFERER" => "https://outside.example.invalid/otvoreni-kod" }
    assert_response :redirect
    target = URI.parse(response.location)
    assert_equal @organization.host, target.host
    assert_equal "/hr", target.path.delete_suffix("/")
  end

  test "published configuration offers both repositories and self installation" do
    ENV["MI_OPEN_SOURCE_PUBLISHED"] = "true"
    ENV["MI_OPEN_SOURCE_APP_URL"] = "https://github.com/bojkic/community-app"
    ENV["MI_OPEN_SOURCE_ENGINE_URL"] = "https://github.com/bojkic/community-engine"
    get "/otvoreni-kod"
    assert_response :success
    assert_select "h2", text: "Pokrenite sami"
    assert_select "article a[href='https://github.com/bojkic/community-app']"
    assert_select "article a[href='https://github.com/bojkic/community-engine']"
    assert_select "article a[href='https://github.com/bojkic/community-app/blob/main/docs/INSTALACIJA.md']"
    assert_includes response.body, I18n.t("mi_open_source.installation_status")
    assert_select "h2", text: "Priprema javnog izdanja", count: 0
  end
end
