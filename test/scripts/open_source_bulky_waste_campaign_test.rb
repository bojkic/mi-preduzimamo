# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../../app/services/decidim_app/bijeljina/milica/bulky_waste_campaign_read"

class OpenSourceBulkyWasteCampaignTest < Minitest::Test
  Reader = DecidimApp::Bijeljina::Milica::BulkyWasteCampaignRead
  DAY = Date.new(2040, 9, 16)

  def row(**changes)
    { "id" => "authored-campaign", "text" => "IZMIŠLJENA NAJAVA KABASTOG OTPADA.",
      "coverage_text" => "Samo izmišljeno područje Testni vrt; prijava kod službe prema objavi.",
      "source_url" => "https://community.example.invalid/notices/authored-campaign", "source_on" => "2040-09-10",
      "reviewed_on" => "2040-09-14", "review_valid_until" => "2040-10-01", "starts_on" => "2040-09-14",
      "ends_on" => "2040-09-15", "review_state" => "reviewed", "publishable" => true }.merge(changes.transform_keys(&:to_s))
  end

  def config(rows = [row])
    { "format" => 1, "organization_host" => "community.example.invalid", "campaigns" => rows }
  end

  def read(data = config, raw: false, host: "community.example.invalid", hosts: ["community.example.invalid"], day: DAY)
    Tempfile.create(["authored-campaign", ".json"]) do |file|
      file.write(raw ? data : JSON.generate(data))
      file.flush
      Reader.new(path: file.path, organization_host: host, reviewed_hosts: hosts).call(day:)
    end
  end

  def assert_unavailable(result)
    assert_equal "unavailable", result.fetch(:status)
    assert_empty result.fetch(:facts, [])
  end

  def test_unconfigured_and_missing_files_supply_no_campaign
    assert_unavailable Reader.new(path: "", organization_host: "community.example.invalid", reviewed_hosts: []).call(day: DAY)
    Tempfile.create("removed-authored-config") do |file|
      path = file.path
      File.unlink(path)
      assert_unavailable Reader.new(path:, organization_host: "community.example.invalid", reviewed_hosts: []).call(day: DAY)
    end
  end

  def test_historical_announcement_retains_own_source_period_and_review
    result = read
    assert_equal "ok", result.fetch(:status)
    fact = result.fetch(:facts).fetch(0)
    assert_equal "expired", fact.fetch("phase")
    %w(text coverage_text source_url source_on reviewed_on review_valid_until starts_on ends_on).each do |field|
      assert_equal row.fetch(field), fact.fetch(field)
    end
    assert_equal false, result.fetch(:validity).fetch("live_status")
    assert_includes result.fetch(:warnings), "newer_announcement_not_excluded"
  end

  def test_current_and_future_periods_are_classified_without_live_status
    { "in_published_window" => ["2040-09-16", "2040-09-16"], "upcoming" => ["2040-09-17", "2040-09-20"] }.each do |phase, (start, finish)|
      result = read(config([row(starts_on: start, ends_on: finish)]))
      assert_equal phase, result.fetch(:facts).fetch(0).fetch("phase")
      assert_equal false, result.fetch(:validity).fetch("live_status")
      assert_includes result.fetch(:warnings), "address_eligibility_not_confirmed"
    end
  end

  def test_future_reviews_expired_reviews_pending_rejected_and_hidden_rows_never_publish
    [row(reviewed_on: "2040-09-17"), row(review_valid_until: "2040-09-15"),
     row(review_state: "pending"), row(review_state: "rejected"), row(publishable: false)].each do |record|
      result = read(config([record]))
      assert_equal "empty", result.fetch(:status)
      assert_empty result.fetch(:facts)
    end
  end

  def test_review_validity_last_day_is_inclusive
    assert_equal "ok", read(config([row(review_valid_until: DAY.iso8601)])).fetch(:status)
  end

  def test_other_communities_are_not_used
    assert_unavailable read(host: "other.example.invalid")
    assert_unavailable read(config.merge("organization_host" => "https://community.example.invalid/path"))
  end

  def test_only_explicitly_reviewed_https_sources_are_accepted
    ["http://community.example.invalid/notice", "https://community.example.invalid:444/notice",
     "https://user:password@community.example.invalid/notice", "https://unreviewed.example.invalid/notice"].each do |url|
      assert_unavailable read(config([row(source_url: url)]))
    end
    assert_unavailable read(hosts: [])
  end

  def test_invalid_dates_and_reversed_periods_fail_closed
    [row(starts_on: "2040-02-30"), row(starts_on: "2040-09-20"), row(source_on: "2040-09-15"),
     row(review_valid_until: "2040-09-13"), row(ends_on: "2040-9-16")].each do |record|
      assert_unavailable read(config([record]))
    end
  end

  def test_multiple_announcements_keep_their_own_coverage_and_dates
    result = read(config([row, row(id: "other-campaign", text: "DRUGA IZMIŠLJENA NAJAVA.", coverage_text: "Drugo izmišljeno područje.",
                                    starts_on: "2040-09-18", ends_on: "2040-09-19")]))
    assert_equal %w(expired upcoming), result.fetch(:facts).map { |fact| fact.fetch("phase") }
    assert_equal "Drugo izmišljeno područje.", result.fetch(:facts).last.fetch("coverage_text")
  end

  def test_duplicate_id_or_oversized_group_is_not_silently_truncated
    assert_unavailable read(config([row, row]))
    assert_unavailable read(config(9.times.map { |i| row(id: "campaign-#{i}") }))
  end

  def test_malformed_empty_nonmapping_and_oversized_documents_fail_without_echoing_payload
    ["", "{private-value", "[]", "null", "x" * (Reader::MAX_BYTES + 1)].each do |raw|
      result = read(raw, raw: true)
      assert_unavailable result
      refute_includes result.to_s, "private-value"
    end
  end

  def test_incomplete_unknown_or_wrongly_typed_configuration_is_rejected
    [config.merge("credentials" => "private-value"), config.merge("format" => 2), config.merge("campaigns" => {}),
     config([row.merge("extra" => "private-value")]), config([row.reject { |key, _| key == "coverage_text" }]),
     config([row(text: " ")]), config([row(text: "x" * 1_001)]), config([row(text: "bad\u0000text")]),
     config([row(source_url: "https://community.example.invalid/" + "x" * 2_000)]), config([row(publishable: "true")]),
     config([row(id: "not a stable id")]), config([nil])].each do |data|
      result = read(data)
      assert_unavailable result
      refute_includes result.to_s, "private-value"
    end
  end
end
