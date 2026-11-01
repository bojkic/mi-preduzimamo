# frozen_string_literal: true

require_relative "decidim_bih_apply_setting"

# The release ships with the old application/award policy until the existing
# signups and proposal awards are reconciled. Set the one documented runtime
# switch during the coordinated cutover; Puma and Sidekiq must restart together.
volunteering_policy_active = ENV.fetch("MI_VOLUNTEER_APPLICATION_REVIEW_REQUIRED", "0") == "1"

DecidimBihSettings.apply("decidim_bih_volunteering", :volunteer_application_review_required, volunteering_policy_active)
DecidimBihSettings.apply("decidim_bih_volunteering", :volunteer_work_award_unit, volunteering_policy_active ? :day : :hour)
DecidimBihSettings.apply("decidim_bih_volunteering", :volunteer_proposal_award_unit, volunteering_policy_active ? :proposal : :term)
