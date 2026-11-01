# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../../../app/services/decidim_app/launch_event_configuration"

module DecidimApp
  class LaunchEventConfigurationTest < Minitest::Test
    def authored_event
      { "version" => 1, "organization_host" => "community.example.invalid", "event_key" => "authored-launch-day",
        "title" => "Autorski dan zajednice", "source_url" => "https://community.example.invalid/events/authored-launch",
        "opens_at" => "2040-09-17T18:00:00+02:00", "closes_at" => "2040-09-17T20:00:00+02:00",
        "enabled" => true, "sms_fallback" => false }
    end

    def configuration(data = authored_event) = LaunchEventConfiguration.new(data)

    def with_event_file(raw = JSON.generate(authored_event))
      prior = ENV["MI_LAUNCH_EVENT_CONFIG_PATH"]
      Tempfile.create("authored-community-launch") do |file|
        file.binmode
        file.write(raw); file.flush
        ENV["MI_LAUNCH_EVENT_CONFIG_PATH"] = file.path
        yield file
      end
    ensure
      prior.nil? ? ENV.delete("MI_LAUNCH_EVENT_CONFIG_PATH") : ENV["MI_LAUNCH_EVENT_CONFIG_PATH"] = prior
    end

    def test_absent_file_means_no_inherited_event
      assert_nil LaunchEventConfiguration.load(organization_host: "community.example.invalid", path: "")
    end

    def test_authored_values_and_identity_are_immutable
      event = configuration
      assert_predicate event, :frozen?
      assert_predicate event.title, :frozen?
      assert_predicate event.opens_at, :frozen?
      assert_equal "Autorski dan zajednice", event.title
      assert_equal "community-launch-v1:#{event.identity}", event.storage_key
      assert_equal "2040-09-17T18:00:00+02:00", event.opens_at.iso8601
      assert event.enabled?
      refute event.sms_fallback?
    end

    def test_window_has_scheduled_open_and_closed_boundaries_without_claiming_attendance
      event = configuration
      assert_equal "scheduled", event.phase(now: Time.iso8601("2040-09-17T15:59:59Z"))
      assert_equal "open", event.phase(now: Time.iso8601("2040-09-17T16:00:00Z"))
      assert event.open?(now: Time.iso8601("2040-09-17T17:59:59Z"))
      assert_equal "closed", event.phase(now: Time.iso8601("2040-09-17T18:00:00Z"))
      refute event.open?(now: Time.iso8601("2040-09-17T18:00:00Z"))
    end

    def test_disabled_configuration_never_opens
      event = configuration(authored_event.merge("enabled" => false))
      assert_equal "disabled", event.phase(now: event.opens_at)
      refute event.open?(now: event.opens_at)
    end

    def test_all_fields_are_required_and_private_or_template_extras_are_rejected
      authored_event.each_key do |key|
        assert_raises(LaunchEventConfiguration::InvalidConfiguration) { configuration(authored_event.reject { |field, _| field == key }) }
      end
      %w(private_payload recipient_phone invitation_token message_text).each do |key|
        assert_raises(LaunchEventConfiguration::InvalidConfiguration) { configuration(authored_event.merge(key => "AUTHORED_PRIVATE_MARKER")) }
      end
    end

    def test_versions_and_activation_or_sms_flags_are_explicit_types
      [{ "version" => "1" }, { "version" => 2 }, { "enabled" => "true" }, { "sms_fallback" => 1 }].each do |change|
        assert_raises(LaunchEventConfiguration::InvalidConfiguration) { configuration(authored_event.merge(change)) }
      end
    end

    def test_event_window_rejects_missing_offsets_impossible_dates_and_nonpositive_order
      [{ "opens_at" => "2040-09-17T18:00:00" }, { "opens_at" => "2040-02-30T18:00:00Z" },
       { "closes_at" => authored_event.fetch("opens_at") }, { "closes_at" => "2040-09-16T18:00:00Z" }].each do |change|
        assert_raises(LaunchEventConfiguration::InvalidConfiguration) { configuration(authored_event.merge(change)) }
      end
    end

    def test_source_is_an_explicit_own_host_https_page_without_credentials_or_control_bytes
      ["http://community.example.invalid/event", "https://other.example.invalid/event", "https://user:pass@community.example.invalid/event",
       "https://community.example.invalid:8443/event", "https://community.example.invalid/event%0Aprivate"].each do |url|
        assert_raises(LaunchEventConfiguration::InvalidConfiguration) { configuration(authored_event.merge("source_url" => url)) }
      end
      refute configuration.bound_to?("other.example.invalid")
      assert configuration.bound_to?("COMMUNITY.EXAMPLE.INVALID")
    end

    def test_invalid_identity_or_unbounded_copy_is_rejected
      [{ "event_key" => "../private" }, { "event_key" => "a" * 65 }, { "title" => "x" * 201 },
       { "title" => "Title\nAUTHORED_PRIVATE_MARKER" }, { "organization_host" => "community.example.invalid/path" }].each do |change|
        assert_raises(LaunchEventConfiguration::InvalidConfiguration) { configuration(authored_event.merge(change)) }
      end
    end

    def test_metadata_changes_create_a_distinct_storage_identity
      original = configuration
      [{ "event_key" => "another-authored-event" }, { "title" => "Drugi autorski događaj" },
       { "source_url" => "https://community.example.invalid/events/other" }, { "opens_at" => "2040-09-17T17:00:00+02:00" },
       { "closes_at" => "2040-09-17T21:00:00+02:00" }, { "enabled" => false }, { "sms_fallback" => true }].each do |change|
        refute_equal original.storage_key, configuration(authored_event.merge(change)).storage_key
      end
    end

    def test_file_errors_are_generic_and_never_expose_path_or_payload
      ["{AUTHORED_PRIVATE_MARKER", "AUTHORED_PRIVATE_MARKER" + "x" * LaunchEventConfiguration::MAX_BYTES, "\xff".b].each do |raw|
        with_event_file(raw) do |file|
          error = assert_raises(LaunchEventConfiguration::InvalidConfiguration) { LaunchEventConfiguration.load(organization_host: "community.example.invalid") }
          assert_equal LaunchEventConfiguration::ERROR, error.message
          refute_includes error.message, file.path
          refute_includes error.message, "AUTHORED_PRIVATE_MARKER"
          assert_nil error.cause
        end
      end
    end

    def test_captured_configuration_rechecks_exact_host_file_identity_and_disable_state
      with_event_file do |file|
        event = LaunchEventConfiguration.load(organization_host: "community.example.invalid")
        assert LaunchEventConfiguration.current?(event, organization_host: event.organization_host)
        refute LaunchEventConfiguration.current?(event, organization_host: "other.example.invalid")
        File.write(file.path, JSON.generate(authored_event.merge("enabled" => false)))
        refute LaunchEventConfiguration.current?(event, organization_host: event.organization_host)
        ENV.delete("MI_LAUNCH_EVENT_CONFIG_PATH")
        refute LaunchEventConfiguration.current?(event, organization_host: event.organization_host)
      end
    end
  end
end
