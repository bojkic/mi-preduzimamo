# frozen_string_literal: true

namespace :decidim_bih do
  namespace :concierge do
    desc "Roll the 48-hour Redis chat metrics into decidim_bih_concierge_metric_rollups for yesterday and today. " \
         "Usage: rake \"decidim_bih:concierge:rollup_metrics[org.host.com]\""
    task :rollup_metrics, [:org_host] => :environment do |_task, args|
      organization = Decidim::Organization.find_by(host: args[:org_host])
      abort "Organization not found for host: #{args[:org_host]}" unless organization

      result = DecidimApp::Bijeljina::Milica::MetricRollup.new(organization:).call
      puts "concierge rollup host=#{organization.host} days=#{result.days.map(&:iso8601).join(",")} " \
           "rows=#{result.written} release_sha=#{result.release_sha || "unknown"} prompt_version=#{result.prompt_version}"
    end
  end
end
