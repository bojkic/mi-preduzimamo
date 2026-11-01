# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"

# Authored community event only. Never enables a provider or sends a message.
module SyntheticLaunchEvent
  def install_synthetic_launch_event(organization:, opens_at:, closes_at:, sms_fallback: false)
    @synthetic_launch_prior_path = ENV["MI_LAUNCH_EVENT_CONFIG_PATH"]
    @synthetic_launch_root = Dir.mktmpdir("authored-community-launch-")
    @synthetic_launch_path = File.join(@synthetic_launch_root, "event.json")
    @synthetic_launch_data = { "version" => 1, "organization_host" => organization.host,
      "event_key" => "authored-launch-day", "title" => "AUTORSKI DAN ZAJEDNICE",
      "source_url" => "https://#{organization.host}/events/authored-launch", "opens_at" => opens_at,
      "closes_at" => closes_at, "enabled" => true, "sms_fallback" => sms_fallback }
    write_synthetic_launch_event
  end

  def write_synthetic_launch_event(**changes)
    @synthetic_launch_data.merge!(changes.transform_keys(&:to_s))
    File.write(@synthetic_launch_path, JSON.generate(@synthetic_launch_data))
    ENV["MI_LAUNCH_EVENT_CONFIG_PATH"] = @synthetic_launch_path
  end

  def restore_synthetic_launch_event
    return unless @synthetic_launch_root

    prior = @synthetic_launch_prior_path
    prior.nil? ? ENV.delete("MI_LAUNCH_EVENT_CONFIG_PATH") : ENV["MI_LAUNCH_EVENT_CONFIG_PATH"] = prior
    FileUtils.remove_entry_secure(@synthetic_launch_root) if File.directory?(@synthetic_launch_root)
  end
end
