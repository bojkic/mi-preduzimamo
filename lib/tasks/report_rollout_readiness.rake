# frozen_string_literal: true

namespace :decidim_app do
  namespace :report_rollout do
    desc "Notify the authenticated release owner of verified report rollout readiness (platform bell only)"
    task notify: :environment do
      Decidim::Organization.find_each do |organization|
        DecidimApp::Bijeljina::ReportRolloutReadiness.new(organization:).call
      end
    end
  end
end
