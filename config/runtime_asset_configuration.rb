# frozen_string_literal: true

# Decidim writes this generated YAML on boot. Keep it out of the deploy-owned
# checkout when running as the restricted service account. Build/test operators
# without MI_RUNTIME_STATE_DIR retain Decidim's original paths.
require "decidim/shakapacker/configuration"

module RuntimeAssetConfiguration
  private

  def configuration_file_path
    directory = ENV["MI_RUNTIME_STATE_DIR"].to_s
    return super if directory.empty?

    raise ArgumentError, "MI_RUNTIME_STATE_DIR must be absolute" unless directory.start_with?("/")

    File.join(directory, "shakapacker_runtime#{ENV.fetch("TEST_ENV_NUMBER", "")}.yml")
  end
end

Decidim::Shakapacker::Configuration.prepend(RuntimeAssetConfiguration)
