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
      assert_select "article[lang='sr-Latn'] h1", text: "Pokrenite MI preduzimamo u svojoj zajednici"
      assert_select "h2", text: "Priprema javnog izdanja"
      assert_select "article a[href^='https://github.com/']", count: 0
      assert_select "a[href^='mailto:office@fondacijabijeljina.com']"
      assert_select "footer a", text: "Otvoreni kod" do |links|
        assert_equal "/otvoreni-kod", URI.parse(links.first["href"]).path
      end
    end
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
    assert_select "h2", text: "Priprema javnog izdanja", count: 0
  end
end
