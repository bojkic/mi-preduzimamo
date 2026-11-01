# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"

# Reads the real production mailer configuration with an invented environment.
# The probe never initializes Rails, opens a database/Redis or sends mail.
# Private notifier and server environment-sync checks remain in private tests.
class SmtpStarttlsConfigurationTest < ActiveSupport::TestCase
  APP_ROOT = Rails.root.to_s
  RAILS_PROBE = File.join(APP_ROOT, "test/support/smtp_probes/production_mailer_settings_probe.rb")

  test "the deprecated key does not configure the Rails mailer STARTTLS setting" do
    assert_equal true, rails_starttls("SMTP_STARTTLS=false")
  end

  test "removing the deprecated key leaves the Rails mailer STARTTLS setting unchanged" do
    assert_equal rails_starttls("SMTP_STARTTLS=true"), rails_starttls(nil)
    assert_equal true, rails_starttls(nil)
  end

  test "the Rails mailer STARTTLS setting follows the canonical key" do
    assert_equal false, rails_starttls("SMTP_STARTTLS_AUTO=false")
    assert_equal true, rails_starttls("SMTP_STARTTLS_AUTO=true")
  end

  test "the Rails mailer recognizes non-canonical false spellings" do
    %w(0 no FALSE).each { |value| assert_equal false, rails_starttls("SMTP_STARTTLS_AUTO=#{value}") }
  end

  test "the environment template offers the canonical key and never the deprecated one" do
    content = File.read(File.join(APP_ROOT, ".env.example"))
    assert_match(/^#?\s*SMTP_STARTTLS_AUTO=/, content)
    assert_no_match(/^#?\s*SMTP_STARTTLS=/, content)
  end

  private

  def rails_starttls(extra_line)
    Dir.mktmpdir("synthetic-smtp-probe") do |dir|
      fixture = File.join(dir, "fixture.env")
      File.write(fixture, ["RAILS_ENV=production", "SMTP_ADDRESS=smtp.example.invalid", "SMTP_PORT=587",
                           "SMTP_DOMAIN=example.invalid", "SMTP_AUTHENTICATION=none", extra_line].compact.join("\n") + "\n")
      output = File.join(dir, "settings.json")
      env = { "PATH" => ENV.fetch("PATH"), "HOME" => Dir.home, "LANG" => "C.UTF-8", "SMTP_PROBE_OUTPUT" => output }
      %w(BUNDLE_GEMFILE BUNDLE_APP_CONFIG BUNDLE_LOCAL__DECIDIM___BIH BUNDLE_DISABLE_LOCAL_BRANCH_CHECK BUNDLE_DISABLE_LOCAL_REVISION_CHECK).each do |key|
        env[key] = ENV.fetch(key) if ENV.key?(key)
      end
      stdout, stderr, status = Open3.capture3(env, "bash", "-c", 'set -a; . "$1"; set +a; exec ruby "$2"',
                                            "--", fixture, RAILS_PROBE, chdir: APP_ROOT, unsetenv_others: true)
      assert status.success?, "Synthetic mailer probe failed: #{stdout} #{stderr}"
      assert File.file?(output), "Synthetic mailer probe produced no settings"
      JSON.parse(File.read(output)).fetch("enable_starttls_auto")
    end
  end
end
