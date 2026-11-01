# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Semantic annotations deliberately live outside SOURCES: descriptive edits
    # must not invalidate durable acquisition snapshots or enable new readers.
    module CityServiceSourceProfiles
      PROFILES = {
        "electricity_outages" => { topic: "electricity", family: "interruption", facets: %w(status schedule location), claims: %w(planned_outage_window affected_place),
                                   unknowns: %w(household_connection restoration_without_notice), authority: "provider" },
        "water_service" => { topic: "water", family: "interruption", facets: %w(status schedule location), claims: %w(interruption_window affected_place),
                             unknowns: %w(bill drinking_water_safety household_connection), authority: "provider" },
        "waste_schedule" => { topic: "waste", family: "schedule", facets: %w(schedule location), claims: %w(reviewed_route_collection_day),
                              unknowns: %w(live_vehicle_position actual_collection), authority: "provider" },
        "bulky_waste" => { topic: "bulky_waste", family: "notice", facets: %w(schedule location), claims: %w(collection_campaign_window),
                           unknowns: %w(regular_waste_schedule household_pickup_confirmation), authority: "provider" },
        "city_official_notices" => { topic: "neighborhood", family: "notice", facets: %w(status deadline location), claims: %w(official_notice public_call),
                                     unknowns: %w(complete_opportunity_coverage personal_result), authority: "public_authority" },
        "sistem48_public_archive" => { topic: "sistem48", family: "aggregate", facets: %w(status), claims: %w(public_archive_aggregate),
                                       unknowns: %w(personal_report_status service_resolution), authority: "public_authority" },
        "heating_service" => { topic: "heating", family: "interruption", facets: %w(status schedule location), claims: %w(provider_interruption_notice),
                               unknowns: %w(network_membership building_connection), authority: "provider" },
        "public_transport" => { topic: "transport", family: "schedule", facets: %w(schedule location), claims: %w(reviewed_timetable route_stop),
                                unknowns: %w(live_vehicle_position undocumented_stop_departure accessibility), authority: "public_authority" },
        "road_conditions" => { topic: "roads", family: "notice", facets: %w(status location), claims: %w(road_segment_condition),
                               unknowns: %w(unreported_road_safety border_queue), authority: "provider" },
        "civil_protection" => { topic: "civil_protection", family: "warning", facets: %w(status location), claims: %w(official_warning affected_area),
                                unknowns: %w(unreported_hazard_absence household_risk), authority: "public_authority" },
        "weather_warnings" => { topic: "weather", family: "warning", facets: %w(status schedule location), claims: %w(issued_regional_warning validity_window),
                                unknowns: %w(street_forecast current_hazard_before_onset), authority: "public_authority" },
        "water_levels" => { topic: "water_levels", family: "observation", facets: %w(status location), claims: %w(station_gauge_observation),
                            unknowns: %w(flood_forecast household_risk cross_station_comparison), authority: "secondary_aggregator" },
        "air_quality" => { topic: "air_quality", family: "reference", facets: %w(status), claims: %w(published_air_quality_document),
                           unknowns: %w(current_local_measurement neighborhood_exposure), authority: "public_authority" },
        "air_quality_realtime" => { topic: "air_quality", family: "observation", facets: %w(status location), claims: %w(community_sensor_observation),
                                    unknowns: %w(regulatory_compliance personal_exposure complete_city_coverage), authority: "community_sensor" },
        "police_service_information" => { topic: "police", family: "directory", facets: %w(contact location), claims: %w(public_institutional_contact service_link),
                                          unknowns: %w(personal_case_status duty_pharmacy_rota), authority: "public_authority" }
      }.freeze
      PROVIDER_IDS = {
        "electricity_outages" => "provider:elektro_bijeljina",
        "water_service" => "provider:vodovod_bijeljina",
        "waste_schedule" => "provider:komunalac_bijeljina",
        "bulky_waste" => "provider:komunalac_bijeljina",
        "city_official_notices" => "provider:grad_bijeljina",
        "sistem48_public_archive" => "provider:grad_bijeljina_sistem48",
        "heating_service" => "provider:gradska_toplana_bijeljina",
        "public_transport" => "provider:grad_bijeljina",
        "road_conditions" => "provider:ams_rs",
        "civil_protection" => "provider:rucz_rs",
        "weather_warnings" => "provider:meteoalarm_rhmz",
        "water_levels" => "provider:bijeljina_org",
        "air_quality" => "provider:grad_bijeljina",
        "air_quality_realtime" => "provider:klimerko",
        "police_service_information" => "provider:mup_rs_pu_bijeljina"
      }.freeze
      QUIET_FAMILIES = %w(interruption notice warning).freeze

      module_function

      def fetch(key)
        profile = PROFILES.fetch(key.to_s).deep_dup
        profile.merge(source_key: key.to_s, provider_id: PROVIDER_IDS.fetch(key.to_s), provider_id_scope: "reviewed_internal_identity",
                      quiet_allowed: QUIET_FAMILIES.include?(profile.fetch(:family)),
                      capability_scope: "reader_contract_not_record_readiness", candidate: false)
      end

      def all
        CityServiceSources.all.map { |source| fetch(source.fetch(:key)) }
      end
    end
  end
end
