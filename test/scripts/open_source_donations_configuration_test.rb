# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../../app/services/decidim_app/bijeljina/donations_configuration"

class OpenSourceDonationsConfigurationTest < Minitest::Test
  Configuration = DecidimApp::Bijeljina::DonationsConfiguration

  def valid(**changes)
    { "product_ids" => [901, 902], "donate_url" => "https://donations.example.invalid/start?preserved=1",
      "organization_host" => "community.example.invalid" }.merge(changes.transform_keys(&:to_s))
  end

  def test_empty_configuration_has_no_products_checkout_or_tenant
    config = Configuration.new({})
    refute config.configured?
    assert_empty config.product_ids
    assert_empty config.donate_url
    assert_empty config.organization_host
  end

  def test_own_ids_url_states_date_and_presets_are_preserved
    config = Configuration.new(valid(product_ids: [901, 901, 902], confirmed_states: ["sale", "done"], date_from: "2040-01-01", donation_presets: [5, 12.5]))
    assert config.configured?
    assert_equal [901, 902], config.product_ids
    assert_equal "https://donations.example.invalid/start?preserved=1", config.donate_url
    assert_equal ["sale", "done"], config.confirmed_states
    assert_equal "2040-01-01", config.date_from
    assert_equal [5, 12.5], config.donation_presets
    assert config.frozen?
    assert config.product_ids.frozen?
  end

  def test_partial_setup_is_rejected_instead_of_borrowing_another_community
    [valid(product_ids: []), valid(donate_url: ""), valid(organization_host: "")].each do |data|
      assert_raises(ArgumentError) { Configuration.new(data) }
    end
  end

  def test_product_identifiers_cannot_be_invalid_or_implicit_strings
    [nil, "901,902", [0], [-1], ["901"], [901.0]].each do |ids|
      assert_raises(ArgumentError) { Configuration.new(valid(product_ids: ids)) }
    end
  end

  def test_checkout_requires_https_and_never_accepts_userinfo
    ["http://donations.example.invalid", "https://user:secret@donations.example.invalid", "javascript:alert(1)", "//donations.example.invalid", "https://bad host/"].each do |url|
      assert_raises(ArgumentError) { Configuration.new(valid(donate_url: url)) }
    end
  end

  def test_host_and_namespace_cannot_be_urls_or_empty_identifiers
    ["https://community.example.invalid", "community.example.invalid/path", "user@community.example.invalid"].each do |host|
      assert_raises(ArgumentError) { Configuration.new(valid(organization_host: host)) }
    end
    assert_raises(ArgumentError) { Configuration.new(valid(cache_namespace: "")) }
  end

  def test_bad_dates_states_amounts_and_unknown_fields_fail_closed
    [valid(date_from: "2040-02-31"), valid(confirmed_states: []), valid(confirmed_states: [""]),
     valid(donation_presets: [-1]), valid(donation_presets: [Float::INFINITY]), valid(api_key: "do-not-put-credentials-in-this-file")].each do |data|
      assert_raises(ArgumentError) { Configuration.new(data) }
    end
  end

  def test_cache_namespace_always_includes_the_community_host
    first = Configuration.new(valid(cache_namespace: "shared"))
    second = Configuration.new(valid(cache_namespace: "shared", organization_host: "other.example.invalid"))
    refute_equal first.cache_namespace, second.cache_namespace
    assert_includes first.cache_namespace, "community.example.invalid"
    assert_includes second.cache_namespace, "other.example.invalid"
  end

  def test_file_loading_requires_explicit_path_and_keeps_parse_errors_payload_free
    refute Configuration.load("").configured?
    Tempfile.create(["synthetic-donations-", ".json"]) do |file|
      file.write(JSON.generate(valid)); file.flush
      assert Configuration.load(file.path).configured?
      file.rewind; file.truncate(0); file.write('{"private_marker":THIS_IS_NOT_JSON}'); file.flush
      error = assert_raises(ArgumentError) { Configuration.load(file.path) }
      refute_includes error.message, "private_marker"
      refute_includes error.message, "THIS_IS_NOT_JSON"
    end
  end
end
