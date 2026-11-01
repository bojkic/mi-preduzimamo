# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../app/services/decidim_app/bijeljina/gazette_source_identity"

class OpenSourceGazetteSourceIdentityTest < Minitest::Test
  Identity = DecidimApp::Bijeljina::GazetteSourceIdentity
  URL = "https://community.example.invalid/archive/2026.html?edition=all"

  def test_host_case_default_port_and_fragment_do_not_invent_another_publisher
    assert_equal Identity.for_url(URL), Identity.for_url("https://COMMUNITY.example.invalid:443/archive/2026.html?edition=all#top")
    assert_equal Identity.for_url("https://community.example.invalid"), Identity.for_url("https://community.example.invalid/")
    assert_match(/\A[a-f0-9]{64}\z/, Identity.for_url(URL))
  end

  def test_publisher_path_and_query_changes_are_different_sources
    ["https://other.example.invalid/archive/2026.html?edition=all", "https://community.example.invalid/other.html?edition=all",
     "https://community.example.invalid/archive/2026.html?edition=selected"].each do |url|
      refute_equal Identity.for_url(URL), Identity.for_url(url)
    end
  end

  def test_nonpublic_or_invalid_source_urls_have_no_identity
    [nil, "", "not a URI", "http://community.example.invalid/", "https://user:synthetic-password@community.example.invalid/",
     "https://community.example.invalid:444/", "https:///missing-host", "https://community.example.invalid/" + "x" * 2_000].each do |url|
      assert_nil Identity.for_url(url)
      refute Identity.matches_payload?({ "source_url" => url, "source_identity" => "invented" }, source_url: url)
    end
  end

  def test_snapshot_requires_matching_url_and_identity_not_only_one_header
    valid = { "source_url" => URL, "source_identity" => Identity.for_url(URL) }
    assert Identity.matches_payload?(valid, source_url: URL)
    refute Identity.matches_payload?(valid.reject { |key, _| key == "source_identity" }, source_url: URL)
    refute Identity.matches_payload?(valid.merge("source_url" => "https://other.example.invalid/"), source_url: URL)
    refute Identity.matches_payload?(valid.merge("source_identity" => "old-source"), source_url: URL)
    refute Identity.matches_payload?(valid, source_url: "https://other.example.invalid/")
    refute Identity.matches_payload?(nil, source_url: URL)
  end
end
