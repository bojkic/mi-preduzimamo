# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "time"
require "rbconfig"

class PublicMaintenanceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @root = Dir.mktmpdir("authored-public-maintenance-")
    @bundle = File.join(@root, "bundle")
    File.write(@bundle, "#!#{RbConfig.ruby}\nrequire 'json'\nputs JSON.generate(argv: ARGV, env: ENV.to_h)\n")
    File.chmod(0o755, @bundle)
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_messaging_wrapper_requires_a_host_and_rejects_rake_argument_injection
    [[], ["host],other-task["]].each do |args|
      output, result = wrapper("script/mi_messaging_shadow_compare", *args)
      assert_equal 64, result.exitstatus
      assert_includes output, "usage"
    end
  end

  def test_messaging_wrapper_selects_only_read_only_comparison_for_the_named_host
    output, result = wrapper("script/mi_messaging_shadow_compare", "community.example.invalid")
    assert result.success?, output
    data = JSON.parse(output)
    assert_equal ["exec", "rake", "decidim_bih:messaging:shadow_compare[community.example.invalid]"], data.fetch("argv")
    assert_equal "development", data.fetch("env").fetch("RAILS_ENV")
  end

  def test_retention_wrapper_refuses_missing_reviewed_configuration
    output, result = wrapper("bin/privacy-retention-sweep.sh")
    assert_equal 64, result.exitstatus
    assert_includes output, "usage"
  end

  def test_retention_wrapper_passes_reviewed_cutoffs_only_to_report_runner
    configuration = { "HOST" => "community.example.invalid", "RAILS_ENV" => "test",
      "MI_RETENTION_CUTOFF" => "2040-01-02", "MI_RETENTION_LOGIN_TOKEN_CUTOFF" => "2040-03-04",
      "REPORT_PHOTO_BEFORE" => "2039-11-12", "APPLY" => "1" }
    output, result = wrapper("bin/privacy-retention-sweep.sh", env: configuration)
    assert result.success?, output
    data = JSON.parse(output)
    assert_equal ["exec", "rails", "runner", "script/lib/mi_retention_status.rb"], data.fetch("argv")
    assert_equal "2040-01-02", data.fetch("env").fetch("REPORT_CONTACT_BEFORE")
    assert_equal "2039-11-12", data.fetch("env").fetch("REPORT_PHOTO_BEFORE")
    assert_equal "2040-03-04", data.fetch("env").fetch("LOGIN_TOKEN_BEFORE")
  end

  def test_latest_skip_cannot_borrow_old_delivery_success
    value, result = health(digest_run_fixture("sent digest for OLD_PRIVATE_HOST"), digest_run_fixture("skipped=no_opt_in_recipient PRIVATE_HOST"))
    assert_equal 1, result.exitstatus
    assert_equal "no_opt_in_recipient", value.fetch("reason")
    assert_equal 0, value.fetch("delivery_log_count")
    assert_equal 1, value.fetch("skipped_organizations")
  end

  def test_latest_completed_delivery_does_not_inherit_old_skip
    value, result = health(digest_run_fixture("skipped=no_opt_in_recipient PRIVATE_HOST"), digest_run_fixture("sent digest for NEW_PRIVATE_HOST"))
    assert result.success?
    assert_equal "ok", value.fetch("status")
    assert_equal 0, value.fetch("skipped_organizations")
    assert_equal 1, value.fetch("delivery_log_count")
    assert_equal "local_log_only_not_provider_or_recipient_receipt", value.fetch("evidence")
  end

  def test_incomplete_latest_run_does_not_borrow_an_older_end_marker
    value, result = health(digest_run_fixture("sent digest for PRIVATE_HOST"), "[#{Time.now.utc.iso8601}] analytics-digest START\n")
    assert_equal 1, result.exitstatus
    assert_equal "incomplete_latest_run", value.fetch("reason")
  end

  def test_failure_and_empty_delivery_are_not_healthy_completions
    { "analytics-digest FAILED exit=1\nsent digest for PRIVATE_HOST" => "job_failed",
      "completed without a recipient marker" => "no_delivery_marker" }.each do |body, reason|
      value, result = health(digest_run_fixture(body))
      assert_equal 1, result.exitstatus
      assert_equal reason, value.fetch("reason")
    end
  end

  def test_stale_future_and_invalid_completion_timestamps_are_not_healthy
    { (Time.now.utc - 9 * 86_400).iso8601 => "stale_completion",
      (Time.now.utc + 3600).iso8601 => "future_completion_time", "invalid-time" => "invalid_completion_time" }.each do |stamp, reason|
      value, result = health(digest_run_fixture("sent digest for PRIVATE_HOST", stamp:))
      assert_equal 1, result.exitstatus
      assert_equal reason, value.fetch("reason")
    end
  end

  def test_health_output_never_exposes_log_identities_or_body
    body = "sent digest for PRIVATE_HOST -> secret@example.invalid\nPRIVATE_CITIZEN_BODY"
    value, result = health(digest_run_fixture(body))
    assert result.success?
    refute_match(/PRIVATE_HOST|secret@example|PRIVATE_CITIZEN/, JSON.generate(value))
  end

  def test_missing_log_and_missing_start_marker_are_explicit_failures
    value, result = health(nil)
    assert_equal 1, result.exitstatus
    assert_equal "log_unreadable", value.fetch("reason")
    value, result = health("[#{Time.now.utc.iso8601}] analytics-digest END\n")
    assert_equal 1, result.exitstatus
    assert_equal "start_marker_missing", value.fetch("reason")
  end

  def test_bounded_tail_cannot_reuse_a_start_marker_outside_the_read_window
    value, result = health("[#{Time.now.utc.iso8601}] analytics-digest START\n" + ("x" * 2_100_000) + "\n[#{Time.now.utc.iso8601}] analytics-digest END\n")
    assert_equal 1, result.exitstatus
    assert_equal "start_marker_missing", value.fetch("reason")
  end

  private

  def wrapper(path, *args, env: {})
    output, error, result = Open3.capture3({ "PATH" => "#{@root}:/usr/bin:/bin" }.merge(env), "bash", File.join(ROOT, path), *args, unsetenv_others: true)
    [output + error, result]
  end

  def digest_run_fixture(body, stamp: Time.now.utc.iso8601)
    "[#{stamp}] analytics-digest START\n#{body}\n[#{stamp}] analytics-digest END\n"
  end

  def health(*parts)
    path = File.join(@root, "authored-digest.log")
    File.write(path, parts.join) unless parts == [nil]
    output, error, result = Open3.capture3(RbConfig.ruby, File.join(ROOT, "script/mi_analytics_digest_health"), "--log", path)
    assert_empty error
    [JSON.parse(output), result]
  end
end
