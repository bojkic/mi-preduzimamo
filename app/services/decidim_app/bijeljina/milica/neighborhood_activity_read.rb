# frozen_string_literal: true

require_relative "platform_catalog_read"
require_relative "public_neighborhood_activity"
require_relative "activity_question_context"

module DecidimApp
  module Bijeljina
    module Milica
      # Reuses the owning catalog's public hierarchy/storage guards, routes and
      # sanitization. This adapter reads explicit area/calendar evidence only;
      # organization headquarters or an MZ overlap is not an activity location.
      class NeighborhoodActivityRead < PlatformCatalogRead
        FAMILY_LIMIT = 3
        Family = Data.define(:status, :facts, :truncated, :warnings)
        Result = Data.define(:status, :facts, :coverage, :warnings)
        VOLUNTEER_COLUMNS = [:id, :title, :komsiluk_id, :starts_at, :ends_at, :opportunity_kind, :updated_at].freeze
        MEETING_COLUMNS = [:id, :title, :start_time, :end_time, :decidim_component_id, :updated_at].freeze
        PROJECT_COLUMNS = [:id, :decidim_budgets_project_id, :starts_on, :ends_on, :reviewed_at].freeze

        # Preserve the existing public aggregation interface and family guards.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
        def call(areas:, context:, starts_at:, ends_at:, explicit_time:, locale:, family_keys: %w(volunteers meetings projects))
          return Result.new("not_authorized", [], {}, ["public_reads_not_allowed"]) unless authorized?(context)

          area = selected_area(areas)
          # No single trusted area is not a broken source: ask for the place.
          return Result.new("ambiguous", [], {}, ["activity_area_required"]) unless area

          from, through = explicit_time ? [starts_at, ends_at] : [context.now, context.now + 7.days]
          coverage = { "area_slug" => area.slug, "area_kind" => area.kind, "area_label" => area.translated_name,
                       "starts_at" => from.iso8601, "ends_at" => through.iso8601, "limit_per_family" => FAMILY_LIMIT, "complete_inventory" => false }
          geometry = PublicNeighborhoodActivity.new(organization: @organization).geometry_predicate(area.boundary)
          readers = {
            "volunteers" => -> { volunteer_activity(area, from, through, context.now, locale) },
            "meetings" => -> { meeting_activity(area, geometry, from, through, context.now, locale) },
            "projects" => -> { project_activity(area, geometry, from, through, context.now, locale) }
          }
          families = readers.slice(*family_keys).transform_values { |reader| safely(&reader) }
          coverage["families"] = families.transform_values { |family| { "status" => family.status, "truncated" => family.truncated } }
          facts = interleave(families.values.map(&:facts))
          status = activity_status(facts, families.values)
          coverage["status"] = status
          warnings = families.values.flat_map(&:warnings) + ["neighborhood_activity_scope_limited"]
          warnings << "no_matching_public_activity" if status == "empty"
          warnings << "neighborhood_activity_list_bounded" if families.values.any?(&:truncated)
          warnings << "neighborhood_activity_participation_on_page" if facts.any?
          Result.new(status, facts, coverage, warnings.uniq)
        end

        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists

        # Reuse supported day/weekend interpretation for direct scoped catalog
        # questions. This does not alter transport or utility time parsing.
        def requested_window(entities:, context:, topic:)
          return [context.now, context.now + 7.days] if ActivityQuestionContext.soon?(entities)

          date = requested_date(entities, context.now, topic:)
          date ? requested_clock_bounds(date, context.now) : [context.now, context.now + 7.days]
        end

        private

        def selected_area(areas)
          return unless areas.any? && areas.all? { |area| area.decidim_organization_id == @organization.id && %w(mz komsiluk).include?(area.kind) }

          preferred = areas.select { |area| area.kind == "komsiluk" }
          preferred = areas if preferred.empty?
          preferred.first if preferred.one?
        end

        def activity_status(facts, families)
          return "ok" if facts.any?
          return "unavailable" if families.any? { |family| family.status == "unavailable" }

          "empty"
        end

        def interleave(groups)
          (0...FAMILY_LIMIT).flat_map { |index| groups.filter_map { |group| group[index] } }
        end

        def safely
          yield
        rescue StandardError => e
          raise if e.is_a?(CityServiceNoticeCollector::DeadlineExceeded)

          Family.new("unavailable", [], false, ["neighborhood_activity_unavailable"])
        end

        def volunteer_activity(area, from, through, now, locale)
          return Family.new("unsupported_geography", [], false, ["neighborhood_activity_mz_volunteer_unmapped"]) unless area.kind == "komsiluk"

          model = Decidim::Bih::VolunteerOpportunity
          table = model.table_name
          partner_ids = Decidim::Bih::PartnerProfile.publicly_visible.where(organization: @organization).select(:id)
          # A row without a komšiluk covers the whole city (owner decision of
          # 2026-09-13), so it answers this komšiluk question too. It is
          # ordered after every genuinely local row and labelled as city-wide.
          scope = model.publicly_visible.where(organization: @organization, komsiluk_id: [area.id, nil], cancelled_at: nil)
          scope = scope.where(partner_profile_id: nil).or(scope.where(partner_profile_id: partner_ids))
                       .where("#{table}.signup_deadline_at IS NULL OR #{table}.signup_deadline_at > ?", now)
                       .where("#{table}.starts_at < ?", through)
                       .where("(#{table}.ends_at > ? AND #{table}.ends_at > #{table}.starts_at) OR (#{table}.ends_at IS NULL AND #{table}.starts_at >= ?)", from, from)
          # PostgreSQL sorts NULL last in an ascending order, so the city-wide
          # rows follow every local one and can never bury a local opportunity.
          rows = scope.select(*VOLUNTEER_COLUMNS).order(komsiluk_id: :asc, starts_at: :asc, id: :asc)
                      .limit(FAMILY_LIMIT + 1).to_a
          project_family(rows) do |row|
            activity_fact(row, "volunteer_opportunity", row.opportunity_kind, row.komsiluk_id ? area : nil, locale,
                          path: public_path("volontiranje"), starts_at: row.starts_at, ends_at: row.ends_at)
          end
        end

        def meeting_activity(area, geometry, from, through, now, locale) # rubocop:disable Metrics/ParameterLists
          return Family.new("unavailable", [], false, ["neighborhood_activity_unavailable"]) unless geometry

          model = Decidim::Meetings::Meeting
          table = model.table_name
          scope = model.visible_for(nil).not_hidden.not_withdrawn
                       .where(component: public_components(now, nil, respect_space_dates: false), deleted_at: nil, private_meeting: false)
                       .where(type_of_meeting: %w(in_person hybrid))
                       .where("#{table}.published_at <= ?", now)
                       .where("#{table}.start_time < ? AND #{table}.end_time > ? AND #{table}.end_time > #{table}.start_time", through, from)
          rows = located_scope(scope, geometry, table).select(*MEETING_COLUMNS).includes(:component)
                                                      .order(start_time: :asc, id: :asc).limit(FAMILY_LIMIT + 1).to_a
          project_family(rows) do |row|
            path = Decidim::EngineRouter.main_proxy(row.component).meeting_path(row)
            activity_fact(row, "public_meeting", "meeting", area, locale, path:, starts_at: row.start_time, ends_at: row.end_time)
          end
        end

        def project_activity(area, geometry, from, through, now, locale) # rubocop:disable Metrics/ParameterLists
          return Family.new("unavailable", [], false, ["neighborhood_activity_unavailable"]) unless geometry

          budget_id = Decidim::Bih::Setting.namespace_for(@organization, "community_projects").fetch("budget_id", nil).to_i
          budget = Decidim::Budgets::Budget.find_by(id: budget_id) if budget_id.positive?
          return Family.new("empty", [], false, []) unless community_storage_available?(budget)
          return Family.new("empty", [], false, []) unless budget.component.published_at && budget.component.published_at <= now

          model = Decidim::Bih::PartnerProjectSubmission
          table = model.table_name
          first = from.in_time_zone("Europe/Sarajevo").to_date
          last = (through - 1).in_time_zone("Europe/Sarajevo").to_date
          scope = model.approved.where(organization: @organization).joins(:partner_profile, :project_donation_link, :project)
                       .merge(Decidim::Bih::PartnerProfile.publicly_visible.where(organization: @organization))
                       .merge(Decidim::Bih::ProjectDonationLink.active.where(organization: @organization))
                       .where(decidim_budgets_projects: { decidim_budgets_budget_id: budget.id, deleted_at: nil })
                       .where("#{table}.reviewed_at <= ?", now)
                       .where("#{table}.starts_on <= ? AND #{table}.ends_on >= ? AND #{table}.ends_on >= #{table}.starts_on", last, first)
          columns = PROJECT_COLUMNS.map { |column| "#{table}.#{column}" }
          rows = located_scope(scope, geometry, "decidim_budgets_projects").select(*columns).includes(:project)
                                                                           .order(starts_on: :asc, id: :asc).limit(FAMILY_LIMIT + 1).to_a
          project_family(rows) do |row|
            activity_fact(row.project, "community_project", "community_project", area, locale,
                          path: public_path("projekti/#{row.project.id}"), starts_at: row.starts_on, ends_at: row.ends_on, date_precision: true)
          end
        end

        def located_scope(scope, geometry, table)
          sql, *values = geometry
          # The only identifiers supplied here are fixed model table names.
          sql = sql.gsub("point(longitude, latitude)", "point(#{table}.longitude, #{table}.latitude)")
          scope.where(table => { latitude: -90..90, longitude: -180..180 }).where(sql, *values)
        end

        def project_family(rows)
          Family.new(rows.empty? ? "empty" : "ok", rows.first(FAMILY_LIMIT).map { |row| yield row }, rows.length > FAMILY_LIMIT, [])
        end

        # A nil area is a city-wide row, never an unknown location: it says so
        # in its coverage and in its own text, so it is never read as local.
        def activity_fact(row, kind, activity_type, area, locale, path:, starts_at:, ends_at:, date_precision: false) # rubocop:disable Metrics/ParameterLists
          public_fact = fact(row, kind:, title: row.title, description: nil, path:, locale:, area:, starts_at:, ends_at:, date_precision:)
          public_fact = citywide_fact(public_fact, locale) unless area
          public_fact.merge("kind" => "neighborhood_activity",
                            "coverage" => public_fact.fetch("coverage").merge("activity_type" => activity_type))
        end
      end
    end
  end
end
