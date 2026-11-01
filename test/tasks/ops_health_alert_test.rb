# frozen_string_literal: true

require "test_helper"
require "rake"
require "tempfile"

class OpsHealthAlertTest < ActiveSupport::TestCase
  TASK = "decidim_bih:operations:health_alert"

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    @task = Rake::Task[TASK]
    @organization = create_organization
    @input = Tempfile.new(["ops-health", ".tsv"])
    @cache = ActiveSupport::Cache::MemoryStore.new
    @original_env = ENV.to_h.slice(
      "HOST",
      "OPS_HEALTH_ALERT_FILE",
      "BIH_OPS_ALERT_ENABLED",
      "BIH_OPS_ALERT_EMAIL"
    )
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    @input.close!
    %w(HOST OPS_HEALTH_ALERT_FILE BIH_OPS_ALERT_ENABLED BIH_OPS_ALERT_EMAIL).each { |key| ENV.delete(key) }
    @original_env.each { |key, value| ENV[key] = value }
    ActionMailer::Base.deliveries.clear
    @task.reenable
  end

  test "sends only structured warning rows to an opted-in organization recipient and deduplicates repeats" do
    Decidim::Bih::Setting.put(@organization, "operations", "operator_email", "ops@example.test")
    @input.write(<<~TSV)
      section\thealthy\tok\tok\tignored healthy detail
      providers\tviber\tstale\twarn\tprivate detail must not leave the server
      cron\tviber_inbound_recovery\tmissing\tfail\tanother private detail
    TSV
    @input.flush
    ENV["HOST"] = @organization.host
    ENV["OPS_HEALTH_ALERT_FILE"] = @input.path

    first_output = Rails.stub(:cache, @cache) do
      @task.reenable
      capture_io { @task.invoke }.first
    end

    assert_includes first_output, "operations_health_alert sent warnings=2"
    assert_equal 1, ActionMailer::Base.deliveries.size
    message = ActionMailer::Base.deliveries.last
    assert_equal ["ops@example.test"], message.to
    assert_includes message.body.encoded, "providers\tviber\tstale\twarn"
    assert_includes message.body.encoded, "cron\tviber_inbound_recovery\tmissing\tfail"
    assert_not_includes message.body.encoded, "healthy"
    assert_not_includes message.body.encoded, "private detail"

    second_output = Rails.stub(:cache, @cache) do
      @task.reenable
      capture_io { @task.invoke }.first
    end

    assert_includes second_output, "operations_health_alert skipped=duplicate warnings=2"
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test "does not send without an explicit recipient opt-in" do
    @input.write("providers\tviber\tstale\twarn\tdetail\n")
    @input.flush
    ENV["HOST"] = @organization.host
    ENV["OPS_HEALTH_ALERT_FILE"] = @input.path

    output = Rails.stub(:cache, @cache) do
      @task.reenable
      capture_io { @task.invoke }.first
    end

    assert_includes output, "operations_health_alert skipped=no_opt_in_recipient warnings=1"
    assert_empty ActionMailer::Base.deliveries
  end
end
