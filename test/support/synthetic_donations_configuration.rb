# frozen_string_literal: true

require_relative "../../app/services/decidim_app/bijeljina/donations"

# Authored installation config only; no provider credentials or donor records.
module SyntheticDonationsConfiguration
  def install_synthetic_donations_configuration(data: nil)
    owner = DecidimApp::Bijeljina::Donations
    config = DecidimApp::Bijeljina::DonationsConfiguration.new(data || {
      "product_ids" => [901, 902], "donate_url" => "https://donations.example.invalid",
      "organization_host" => "donations-community.example.invalid", "cache_namespace" => "synthetic"
    })
    values = { CONFIGURATION: config, PRODUCT_IDS: config.product_ids, DONATE_URL: config.donate_url,
               ORGANIZATION_HOST: config.organization_host, CACHE_NAMESPACE: config.cache_namespace,
               DONATION_PRESETS: config.donation_presets }
    @synthetic_donation_constants = []
    values.each do |name, value|
      prior = owner.const_get(name, false)
      owner.send(:remove_const, name)
      owner.const_set(name, value)
      @synthetic_donation_constants << [owner, name, prior]
    end
  end

  def restore_synthetic_donations_configuration
    @synthetic_donation_constants&.reverse_each do |owner, name, prior|
      owner.send(:remove_const, name)
      owner.const_set(name, prior)
    end
    @synthetic_donation_constants = nil
  end
end
