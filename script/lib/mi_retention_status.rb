# frozen_string_literal: true

# Invoked through Rails runner by the scheduled wrapper. This path only counts:
# no audit row, governance attempt, notification, or retained data is written.
organization = Decidim::Organization.find_by(host: ENV.fetch("HOST"))
abort "retention_status failed=organization_missing" unless organization

cutoffs = Decidim::Bih::PrivacyAuditContracts.sweep_env_cutoffs.filter_map do |key, attribute|
  value = ENV.fetch(key, nil)
  [attribute, value] if value.present?
end.to_h
attributes = cutoffs.merge(organization:, report_coordinate_precision: ENV.fetch("REPORT_COORDINATE_PRECISION", nil))
sweep = Decidim::Bih::Privacy::RetentionSweep
result = sweep.call(**attributes, dry_run: true, record_run: false)
status = if result.total.zero?
           "no_work_due"
         else
           approval = Decidim::Bih::GovernanceApproval.current_for(organization, "privacy_retention")
           total = approval&.metadata.to_h["dry_run_total"]
           if approval && total.present? && total.to_i == result.total && approval.scope_key == sweep.scope_key(**attributes)
             "ready_for_approved_apply"
           else
             "awaiting_approval"
           end
         end
# RetentionSummary consumes this established result line for dashboard health.
puts "dry_run=true apply=false total=#{result.total}"
puts "retention_status status=#{status} total=#{result.total} mode=report_only"
result.counts.each { |key, count| puts "#{key}=#{count}" }
