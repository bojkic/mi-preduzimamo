# frozen_string_literal: true

require "test_helper"
require "capybara"
require "decidim/participatory_processes/test/factories"

class SearchVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    @organization = create_organization(name: localized_text("MI preduzimamo — Izmišljena zajednica"))
    host! @organization.host
  end

  test "public reports retain indexability while intake and token pages do not" do
    helper = Object.new.extend(MiSearchHelper)
    request = Struct.new(:path, :query_parameters).new("/biceriseno/prijave/BR-2026-0088", {})
    helper.define_singleton_method(:request) { request }
    assert_not helper.mi_search_noindex?
    request.path = "/biceriseno/prijave/new"
    assert helper.mi_search_noindex?
    request.path = "/biceriseno/prijave/BR-2026-0088/status/private-example"
    assert helper.mi_search_noindex?
    request.path = "/biceriseno/potvrdi-email/private-example"
    assert helper.mi_search_noindex?
    request.path = "/biceriseno/service-evidence/private-example"
    assert helper.mi_search_noindex?
    request.path = "/v/example"
    assert helper.mi_search_noindex?
    request.path = "/ko-smo"
    request.query_parameters = { "token" => "private-example" }
    assert helper.mi_search_noindex?
  end

  test "localized private paths remain excluded from search" do
    helper = Object.new.extend(MiSearchHelper)
    request = Struct.new(:path, :query_parameters).new("/", {})
    helper.define_singleton_method(:request) { request }
    %w[sr sr-Cyrl bs hr].each do |locale|
      %w[/users/sign_in /account /admin /notifications /profiles/example].each do |path|
        request.path = "/#{locale}#{path}"
        assert helper.mi_search_noindex?, request.path
      end
    end
  end

  test "sitemap serves curated public URLs as XML" do
    get "/sitemap.xml"
    assert_response :success
    assert_equal "application/xml", response.media_type
    document = Nokogiri::XML(response.body)
    assert_empty document.errors
    urls = document.xpath("//*[local-name()='loc']").map(&:text)
    assert_includes urls, "https://#{@organization.host}/"
    assert_includes urls, "https://#{@organization.host}/biceriseno/mi-bot"
    assert_not(urls.any? { |url| url.match?(/prijave|registracija|komsiluk-board/) })
  end

  test "homepage presents search identity and escaped structured data" do
    get "/sr"
    assert_response :success
    assert_select "title", text: "MI preduzimamo — Izmišljena zajednica — prijavi problem, predloži i odlučuj"
    assert_select 'script[type="application/ld+json"]' do |nodes|
      schema = nodes.map { |node| JSON.parse(node.text) }.find { |entry| entry["@graph"] }
      assert_equal "MI preduzimamo — Izmišljena zajednica", schema.fetch("@graph").first.fetch("name")
      assert_equal "https://#{@organization.host}/", schema.fetch("@graph").first.fetch("url")
    end
  end

  test "public metadata preserves locale but removes tracking parameters" do
    get "/ko-smo", params: { locale: "sr-Cyrl", utm_source: "example" }
    assert_response :success
    assert_select 'meta[name="description"]' do |nodes|
      assert nodes.first["content"].present?
    end
    assert_select 'link[rel="canonical"][href=?]', "https://#{@organization.host}/ko-smo?locale=sr-Cyrl"
    assert_select 'link[rel="alternate"]', count: 4
    assert_select 'meta[name="robots"]', count: 0
    assert_select 'meta[property="og:url"]' do |nodes|
      assert_not_includes nodes.first["content"], "utm_source"
    end
  end

  test "search identity and publisher follow each tenant rather than a Foundation URL" do
    other = create_organization(name: localized_text("MI preduzimamo — Druga izmišljena zajednica"))
    [@organization, other].each do |organization|
      host! organization.host
      get "/sr"
      assert_response :success
      expected = organization.name.fetch("sr")
      assert_select 'meta[property="og:site_name"][content=?]', expected
      schemas = Nokogiri::HTML(response.body).css('script[type="application/ld+json"]').map { |node| JSON.parse(node.text) }
      graph = schemas.find { |row| row["@graph"] }.fetch("@graph")
      assert_equal expected, graph.find { |row| row["@type"] == "WebSite" }.fetch("name")
      publisher = graph.find { |row| row["@type"] == "Organization" }
      assert_equal expected, publisher.fetch("name")
      assert_equal "https://#{organization.host}/", publisher.fetch("url")
      assert_not_includes JSON.generate(graph), "fondacijabijeljina.com"
    end
  end

  test "organization text cannot break out of structured-data or metadata markup" do
    label = 'Izmišljena zajednica "</script><script>AUTHORED_CANARY</script>'
    @organization.update!(name: localized_text(label))
    get "/sr"
    assert_response :success
    assert_not_includes response.body, "<script>AUTHORED_CANARY</script>"
    assert_select 'meta[property="og:site_name"][content=?]', label
    schemas = Nokogiri::HTML(response.body).css('script[type="application/ld+json"]').map { |node| JSON.parse(node.text) }
    graph = schemas.find { |row| row["@graph"] }.fetch("@graph")
    assert_equal label, graph.find { |row| row["@type"] == "WebSite" }.fetch("name")
  end

  test "locale-prefixed canonical alternatives replace the prefix" do
    create(:participatory_process, :published, organization: @organization)
    get "/sr/processes"
    assert_response :success
    assert_select 'link[rel="canonical"][href=?]', "https://#{@organization.host}/sr/processes"
    assert_select 'link[rel="alternate"][hreflang="hr"][href=?]', "https://#{@organization.host}/hr/processes"
  end

  test "sign in does not publish redirect parameters to search metadata" do
    get "/sr/users/sign_in", params: { redirect_url: "/account?token=private-example" }
    assert_response :success
    assert_select 'meta[name="robots"][content="noindex, follow"]'
    assert_select 'link[rel="canonical"]', count: 0
    assert_select 'link[rel="alternate"]', count: 0
    assert_select 'meta[property="og:url"][content=?]', "https://#{@organization.host}/"
  end
end
